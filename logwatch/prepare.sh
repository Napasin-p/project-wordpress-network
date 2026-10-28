#!/usr/bin/env bash
# ===========================================================
#  prepare.sh — รันบน host (root) ก่อน analyzer container ทุกรอบ
#  ดึงเฉพาะ log ช่วงที่ต้องใช้ ไปไว้ใน /var/lib/logwatch/in
#  → container เห็นแค่โฟลเดอร์นี้ (read-only) ไม่เห็น /var/log ของเครื่อง
# ===========================================================
set -euo pipefail

BASE=/var/lib/logwatch
IN=$BASE/in
GEO=$BASE/geo
OUT=$BASE/out
SINCE="${LOGWATCH_SINCE:-26 hours ago}"   # กราฟ 24 ชม. + เผื่อ
GID=65534                                  # container รันเป็น nobody:nogroup

install -d -m 755 "$BASE"
install -d -m 750 -o root -g "$GID" "$IN" "$GEO"
install -d -m 755 -o "$GID" -g "$GID" "$OUT"
rm -f "$IN"/*

# ---------- nginx ----------
for f in access.log access.log.1; do
  [[ -f /var/log/nginx/$f ]] && cp /var/log/nginx/$f "$IN/nginx_$f"
done

# ---------- kernel log: การบล็อกต่างประเทศ (GEOBLOCK-DROP) ----------
journalctl -k --since "$SINCE" --grep 'GEOBLOCK' -o short-unix --no-pager -q > "$IN/geoblock.log" || true

# ---------- SSH ----------
journalctl -u ssh --since "$SINCE" -o short-unix --no-pager -q > "$IN/ssh.log" || true

# ---------- fail2ban ----------
for f in fail2ban.log fail2ban.log.1; do
  [[ -f /var/log/$f ]] && cp /var/log/$f "$IN/$f"
done
python3 - > "$IN/f2b_status.json" <<'PY'
import json, re, subprocess
def run(*a):
    try: return subprocess.run(a, capture_output=True, text=True, timeout=10).stdout
    except Exception: return ""
jails = re.search(r"Jail list:\s*(.*)", run("fail2ban-client", "status"))
out = {}
for j in [x.strip() for x in (jails.group(1).split(",") if jails else []) if x.strip()]:
    m = re.search(r"Banned IP list:\s*(.*)", run("fail2ban-client", "status", j))
    out[j] = m.group(1).split() if m else []
print(json.dumps(out))
PY

# ---------- สถานะระบบ ----------
python3 - > "$IN/system.json" <<'PY'
import json, os, shutil, subprocess, datetime, glob
def run(*a):
    try: return subprocess.run(a, capture_output=True, text=True, timeout=10).stdout.strip()
    except Exception: return ""
services = {s: run("systemctl", "is-active", s) or "unknown"
            for s in ["nginx", "php8.3-fpm", "mysql", "fail2ban", "netfilter-persistent", "ssh", "cron", "docker"]}
cert_days = None
pems = glob.glob("/etc/nginx/ssl/*/fullchain.pem")
if pems:
    end = run("openssl", "x509", "-enddate", "-noout", "-in", pems[0]).split("=", 1)[-1]
    try:
        t = datetime.datetime.strptime(end, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=datetime.timezone.utc)
        cert_days = (t - datetime.datetime.now(datetime.timezone.utc)).days
    except ValueError:
        pass
mem = {}
for line in open("/proc/meminfo"):
    k, v = line.split(":", 1); mem[k] = int(v.split()[0])
du = shutil.disk_usage("/")
ipsets = {}
for name in ("th-net", "th-net6", "cf-net"):
    out = run("ipset", "list", name, "-t")
    for line in out.splitlines():
        if line.startswith("Number of entries:"):
            ipsets[name] = int(line.split(":")[1])
print(json.dumps({
    "hostname": os.uname().nodename,
    "uptime_hours": round(float(open("/proc/uptime").read().split()[0]) / 3600, 1),
    "load_1m": os.getloadavg()[0],
    "mem_used_pct": round(100 * (1 - mem["MemAvailable"] / mem["MemTotal"]), 1),
    "disk_used_pct": round(100 * du.used / du.total, 1),
    "services": services,
    "cert_days_left": cert_days,
    "ipset_entries": ipsets,
}))
PY

chgrp "$GID" "$IN"/* 2>/dev/null || true
chmod 640 "$IN"/* 2>/dev/null || true

# ---------- ฐานข้อมูลประเทศ (ipdeny) — อัปเดตเดือนละครั้ง ----------
if [[ ! -f $GEO/.stamp ]] || [[ -n $(find "$GEO/.stamp" -mtime +30 2>/dev/null) ]]; then
  tmp=$(mktemp -d)
  if curl -fsSL --max-time 120 https://www.ipdeny.com/ipblocks/data/countries/all-zones.tar.gz -o "$tmp/z.tgz"; then
    tar -xzf "$tmp/z.tgz" -C "$tmp"
    count=$(find "$tmp" -name '*.zone' | wc -l)
    if (( count > 100 )); then
      find "$GEO" -name '*.zone' -delete
      find "$tmp" -name '*.zone' -exec cp {} "$GEO/" \;
      chgrp -R "$GID" "$GEO"; chmod 640 "$GEO"/*.zone
      touch "$GEO/.stamp"
    fi
  fi
  rm -rf "$tmp"
fi
