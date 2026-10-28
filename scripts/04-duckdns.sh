#!/usr/bin/env bash
# ===========================================================
#  04 — ตั้งโดเมน DuckDNS ให้ชี้มาที่ public IP ของ VPS
#       + ตั้ง cron อัปเดต IP อัตโนมัติทุก 5 นาที
#         (เผื่อผู้ให้บริการเปลี่ยน IP ให้)
#      sudo ./04-duckdns.sh
# ===========================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_root
load_config
require_vars DUCKDNS_SUBDOMAIN DUCKDNS_TOKEN

DOMAIN=$(full_domain)
UPDATER=/usr/local/bin/duckdns-update.sh
SECRET=/etc/duckdns.env

apt_install curl dnsutils

# ===========================================================
#  1. เก็บ token แยกไว้ในไฟล์ที่อ่านได้เฉพาะ root
# ===========================================================
log "เขียน $SECRET"
cat >"$SECRET" <<EOF
DUCKDNS_SUBDOMAIN=${DUCKDNS_SUBDOMAIN}
DUCKDNS_TOKEN=${DUCKDNS_TOKEN}
EOF
chmod 600 "$SECRET"   # rw- --- ---  token คือความลับ
ok "เก็บ token แล้ว (สิทธิ 600)"

# ===========================================================
#  2. สคริปต์อัปเดต IP
# ===========================================================
log "เขียน $UPDATER"
cat >"$UPDATER" <<'SCRIPT'
#!/usr/bin/env bash
# อัปเดต A record ของ DuckDNS ให้ชี้มาที่ IP ปัจจุบันของเครื่องนี้
set -euo pipefail
source /etc/duckdns.env

# เว้น ip= ว่าง = ให้ DuckDNS ใช้ IP ต้นทางของ request นี้เอง
RESULT=$(curl -fsS --max-time 20 \
  "https://www.duckdns.org/update?domains=${DUCKDNS_SUBDOMAIN}&token=${DUCKDNS_TOKEN}&ip=")

if [[ $RESULT == OK ]]; then
  logger -t duckdns "updated ${DUCKDNS_SUBDOMAIN}.duckdns.org -> OK"
  echo "OK"
else
  logger -t duckdns "update FAILED: ${RESULT}"
  echo "FAILED: ${RESULT}" >&2
  exit 1
fi
SCRIPT
chmod 700 "$UPDATER"

# ===========================================================
#  3. รันทันทีหนึ่งรอบ
# ===========================================================
log "อัปเดต DNS record ครั้งแรก"
"$UPDATER" >/dev/null \
  || die "DuckDNS ตอบว่า KO — ตรวจว่า DUCKDNS_SUBDOMAIN และ DUCKDNS_TOKEN ถูกต้อง
      (subdomain ใส่แค่ชื่อ ไม่ต้องใส่ .duckdns.org)"
ok "อัปเดต $DOMAIN แล้ว"

# ===========================================================
#  4. cron ให้อัปเดตเองทุก 5 นาที
#     ใช้ /etc/cron.d (ไม่ใช่ crontab -e) เพราะเป็นไฟล์ → ตรวจ/แนบรายงานได้ง่าย
# ===========================================================
log "ติดตั้ง cron job"
# เวอร์ชันเก่าของสคริปต์ใช้ systemd timer — ปิดทิ้งกันรันซ้ำ
if systemctl list-unit-files duckdns.timer &>/dev/null; then
  systemctl disable --now duckdns.timer 2>/dev/null || true
  rm -f /etc/systemd/system/duckdns.{timer,service}
  systemctl daemon-reload
fi

cat >/etc/cron.d/duckdns <<EOF2
# อัปเดต IP ไปที่ DuckDNS ทุก 5 นาที — สร้างโดย 04-duckdns.sh
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root ${UPDATER} >/dev/null 2>&1
EOF2
chmod 644 /etc/cron.d/duckdns
ok "ตั้ง cron แล้ว: /etc/cron.d/duckdns (ดู log: journalctl -t duckdns)"

# ===========================================================
#  5. ตรวจว่า DNS ทำงานจริง
#     นี่คือหลักการที่เรียน: DNS server แปลงชื่อเป็น IP
# ===========================================================
echo
log "ตรวจสอบการแปลงชื่อเป็น IP (DNS resolution)"
MY_IP=$(curl -fsS --max-time 10 https://api.ipify.org || echo "?")
sleep 3
DNS_IP=$(dig +short "$DOMAIN" @1.1.1.1 | tail -1)

printf '\n  %-26s %s\n' "public IP ของ VPS:" "$MY_IP"
printf '  %-26s %s\n'   "$DOMAIN →" "${DNS_IP:-ยังไม่มี record}"
echo

if [[ -n $DNS_IP && $DNS_IP == "$MY_IP" ]]; then
  ok "DNS ชี้มาถูกเครื่องแล้ว"
else
  warn "ยังไม่ตรงกัน — DNS อาจยังไม่ propagate (รอ 1-2 นาทีแล้วลองใหม่)"
  warn "ตรวจซ้ำด้วย: dig +short $DOMAIN @1.1.1.1"
fi

log "ขั้นถัดไป: sudo ./05-https-acme.sh"
