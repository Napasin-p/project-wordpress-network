#!/usr/bin/env bash
# ===========================================================
#  12 — ระบบแจ้งเตือนทาง Discord
#
#  ตรวจทุก 5 นาที (systemd timer) แล้วส่งเข้า Discord webhook เมื่อ:
#    • เว็บ/หน้า login ไม่ตอบ 200 · บริการหยุด (nginx, PHP, MySQL, fail2ban, Docker, dashboard)
#    • firewall ไม่ใช่ DROP หรือรายการ IP ไทยหาย · ใบรับรองเหลือ < 14 วัน · ดิสก์ > 90%
#    • สคริปต์รายการ IP ไทยปฏิเสธการอัปเดต (th-ipset) · AI สแกนล้มเหลวหรือไม่ได้สแกนเกิน 13 ชม.
#    • ผลวิเคราะห์ของ AI ระดับ medium ขึ้นไป
#  ปัญหาเดิมแจ้งครั้งแรก + เตือนซ้ำทุก 6 ชม. ถ้ายังไม่หาย + แจ้งตอนกลับมาปกติ
#
#      sudo ./12-alerts.sh            ติดตั้ง/อัปเดต
#  หลังติดตั้ง ใส่ webhook เอง (ห้ามส่งในแชท):
#      read -rsp "Webhook URL: " U; echo; echo "DISCORD_WEBHOOK_URL=$U" | sudo tee /etc/alert.env >/dev/null; sudo chmod 600 /etc/alert.env; unset U
#      sudo alert-check --test        ส่งข้อความทดสอบ
#      sudo alert-check --dry-run     ตรวจทุกอย่าง แต่พิมพ์ข้อความออกจอแทนการส่ง
# ===========================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_root
load_config

DOMAIN=$(full_domain)
BIN=/usr/local/sbin/alert-check
ENVF=/etc/alert.env

log "เขียน $BIN"
cat >"$BIN" <<'PY'
#!/usr/bin/env python3
"""ตรวจสุขภาพระบบ + ผลของ AI แล้วแจ้งเตือนทาง Discord — สร้างโดย 12-alerts.sh"""
import json, os, re, shutil, subprocess, sys, time, urllib.request
from datetime import datetime, timezone

DOMAIN = "__DOMAIN__"
ENV_FILE = "/etc/alert.env"
STATE_FILE = "/var/lib/alert/state.json"
LATEST = "/var/lib/logwatch/out/latest.json"
CERT = f"/etc/nginx/ssl/{DOMAIN}/fullchain.pem"
SERVICES = ["nginx", "php8.3-fpm", "mysql", "fail2ban", "docker"]
REMIND_SEC = 6 * 3600
AI_LEVELS = {"medium": 2, "high": 3, "critical": 4}
DASH = f"https://{DOMAIN}/security-dashboard/"


def sh(*cmd, timeout=20):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout.strip()
    except Exception:
        return ""


def http_code(path):
    return sh("curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "15",
              "--resolve", f"{DOMAIN}:443:127.0.0.1", "-H", "Accept: text/html",
              f"https://{DOMAIN}{path}")


def mask(text):
    """ข้อความจาก AI อ้างอิง log ที่คนร้ายควบคุมได้ — ซ่อน IP และตัด @mention ก่อนส่งออกไปนอกเครื่อง"""
    text = re.sub(r"\b(\d{1,3}\.\d{1,3})\.\d{1,3}\.\d{1,3}\b", r"\1.x.x", text)
    text = re.sub(r"\b([0-9a-fA-F]{1,4}:[0-9a-fA-F]{1,4}):[0-9a-fA-F:]{2,}\b", r"\1:…", text)
    return text.replace("@", "＠").replace("`", "'")


# ---------- ตรวจแบบ "สถานะ" (มีปัญหาอยู่ / หายแล้ว) ----------
def check_conditions():
    bad = {}
    for p in ("/", "/wp-login.php"):
        c = http_code(p)
        if c != "200":
            bad[f"http{p}"] = f"เว็บ {p} ตอบ {c or 'ไม่ได้'} (ต้องเป็น 200)"
    for s in SERVICES:
        st = sh("systemctl", "is-active", s)
        if st != "active":
            bad[f"svc:{s}"] = f"บริการ {s} ไม่ทำงาน ({st or 'unknown'})"
    if sh("docker", "inspect", "-f", "{{.State.Running}}", "logwatch-dashboard-1") != "true":
        bad["dashboard"] = "container ของ Security Dashboard ไม่ทำงาน"
    pol = sh("iptables", "-S", "INPUT").splitlines()[:1]
    if pol != ["-P INPUT DROP"]:
        bad["fw-policy"] = "firewall: INPUT policy ไม่ใช่ DROP — geo-block อาจไม่ทำงาน"
    m = re.search(r"Number of entries: (\d+)", sh("ipset", "list", "th-net", "-t"))
    if not m or int(m.group(1)) < 100:
        bad["fw-ipset"] = f"firewall: รายการ IP ไทยเหลือ {m.group(1) if m else 0} ช่วง (ควร > 600)"
    end = sh("openssl", "x509", "-enddate", "-noout", "-in", CERT).replace("notAfter=", "")
    try:
        days = (datetime.strptime(end, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc)
                - datetime.now(timezone.utc)).days
        if days < 14:
            bad["cert"] = f"ใบรับรอง HTTPS เหลือ {days} วัน (ต่ออายุอัตโนมัติอาจล้มเหลว)"
    except ValueError:
        bad["cert"] = "อ่านวันหมดอายุของใบรับรองไม่ได้"
    du = shutil.disk_usage("/")
    pct = du.used * 100 // du.total
    if pct > 90:
        bad["disk"] = f"ดิสก์ใช้ไป {pct}%"
    try:
        gen = datetime.fromisoformat(json.load(open(LATEST))["generated_at"])
        hours = (datetime.now(timezone.utc) - gen).total_seconds() / 3600
        if hours > 13 and sh("systemctl", "is-enabled", "logwatch.timer") == "enabled":
            bad["ai-stale"] = f"AI ไม่ได้สแกนมา {hours:.0f} ชม. (ปกติทุก 6 ชม.)"
    except Exception:
        bad["ai-stale"] = "อ่านผลสแกนของ AI ไม่ได้"
    return bad


# ---------- ตรวจแบบ "เหตุการณ์" (แจ้งครั้งเดียวต่อเรื่อง) ----------
def check_events(state):
    msgs = []
    since = state.get("last_run", int(time.time()) - 600)
    warn = sh("journalctl", "-t", "th-ipset", "-p", "warning", "--since", f"@{since}", "--no-pager", "-o", "cat")
    if warn:
        msgs.append("⚠️ **รายการ IP ไทยผิดปกติ — ไม่ได้อัปเดต (คงรายการเดิม)**\n" + mask(warn[:500]))
    try:
        d = json.load(open(LATEST))
    except Exception:
        return msgs
    run = d.get("run_id")
    if not run or run == state.get("last_ai_run"):
        return msgs
    state["last_ai_run"] = run
    meta, f = d["ai"].get("meta", {}), d["ai"].get("findings")
    if meta.get("error"):
        msgs.append(f"⚠️ **AI สแกนไม่สำเร็จ** ({run})\n{mask(str(meta['error'])[:300])}")
        return msgs
    if not f:
        return msgs
    incs = [i for i in f.get("incidents", []) if AI_LEVELS.get(i.get("severity"), 0) >= 2]
    if AI_LEVELS.get(f.get("threat_level"), 0) >= 2 or incs:
        icon = "🚨" if f.get("threat_level") in ("high", "critical") else "🟡"
        lines = [f"{icon} **AI: ระดับภัย {f.get('threat_level', '?').upper()}** — {len(incs)} เหตุการณ์ (medium ขึ้นไป)",
                 mask(f.get("summary_th", ""))[:600]]
        for i in incs[:5]:
            lines.append(f"• [{i.get('severity')}] {mask(i.get('title_th', ''))[:150]}")
        lines.append(f"ดูรายละเอียด: {DASH}")
        msgs.append("\n".join(lines))
    return msgs


def send(text, url):
    body = json.dumps({"content": text[:1900], "username": "freexduk alert",
                       "allowed_mentions": {"parse": []}}).encode()
    req = urllib.request.Request(url, data=body, method="POST",
                                 headers={"Content-Type": "application/json", "User-Agent": "alert-check"})
    urllib.request.urlopen(req, timeout=15).read()


def main():
    dry = "--dry-run" in sys.argv
    env = {}
    if os.path.exists(ENV_FILE):
        for line in open(ENV_FILE):
            if "=" in line and not line.startswith("#"):
                k, v = line.strip().split("=", 1)
                env[k] = v.strip().strip('"')
    url = env.get("DISCORD_WEBHOOK_URL", "")
    if not dry and not re.match(r"^https://(discord|discordapp)\.com/api/webhooks/\d+/[\w-]+$", url):
        print(f"ยังไม่ได้ตั้ง DISCORD_WEBHOOK_URL ที่ถูกต้องใน {ENV_FILE}", file=sys.stderr)
        sh("logger", "-t", "alert", "ยังไม่ได้ตั้ง webhook — ไม่ได้ส่งแจ้งเตือน")
        return 0            # ไม่ให้ timer ขึ้น failed ทุก 5 นาทีระหว่างรอใส่ webhook
    out = (lambda t: print("---\n" + t)) if dry else (lambda t: send(t, url))

    if "--test" in sys.argv:
        out(f"✅ ทดสอบระบบแจ้งเตือนของ {DOMAIN} — ถ้าเห็นข้อความนี้แปลว่าใช้งานได้")
        return 0

    try:
        state = json.load(open(STATE_FILE))
    except Exception:
        state = {}
    now = int(time.time())
    open_ = state.get("open", {})
    msgs = []

    bad = check_conditions()
    for key, text in bad.items():
        last = open_.get(key, {}).get("sent", 0)
        if key not in open_:
            msgs.append(f"🔴 **{text}**")
        elif now - last >= REMIND_SEC:
            msgs.append(f"🔴 ยังไม่หาย: {text}")
        else:
            continue
        open_[key] = {"text": text, "sent": now}
    for key in [k for k in open_ if k not in bad]:
        msgs.append(f"🟢 กลับมาปกติ: {open_.pop(key)['text']}")

    msgs += check_events(state)
    state.update(open=open_, last_run=now)

    for m in msgs:
        try:
            out(m)
        except Exception as e:
            sh("logger", "-t", "alert", f"ส่งไม่สำเร็จ: {e}")
            return 1
    if not dry:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        json.dump(state, open(STATE_FILE + ".tmp", "w"), ensure_ascii=False)
        os.replace(STATE_FILE + ".tmp", STATE_FILE)
        if msgs:
            sh("logger", "-t", "alert", f"ส่งแจ้งเตือน {len(msgs)} ข้อความ")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
sed -i "s/__DOMAIN__/${DOMAIN}/" "$BIN"
chmod 750 "$BIN"
install -d -m 700 /var/lib/alert
ok "ติดตั้ง $BIN"

[[ -f $ENVF ]] || { install -m 600 /dev/null "$ENVF"; echo "# DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/..." > "$ENVF"; }
chmod 600 "$ENVF"

log "ติดตั้ง systemd timer (ทุก 5 นาที)"
cat >/etc/systemd/system/alert-check.service <<'EOF'
[Unit]
Description=ตรวจสุขภาพระบบ + ผลของ AI แล้วแจ้งเตือนทาง Discord
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/alert-check
EOF
cat >/etc/systemd/system/alert-check.timer <<'EOF'
[Unit]
Description=รัน alert-check ทุก 5 นาที

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now alert-check.timer
ok "เปิด alert-check.timer แล้ว"

if grep -q '^DISCORD_WEBHOOK_URL=https' "$ENVF"; then
  ok "มี webhook แล้ว — ทดสอบด้วย: sudo alert-check --test"
else
  warn "ยังไม่ได้ใส่ webhook — ระบบจะยังไม่ส่งอะไร (ดูคำสั่งด้านบนของสคริปต์นี้)"
fi
log "ผลตรวจตอนนี้ (ไม่ส่งจริง):"
"$BIN" --dry-run || true
