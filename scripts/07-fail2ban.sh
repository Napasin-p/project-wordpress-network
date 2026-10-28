#!/usr/bin/env bash
# ===========================================================
#  07 — fail2ban: ชั้นป้องกันเพิ่มจาก geo-block
#       แม้จะอนุญาตแค่ IP ไทย คนในไทยก็ยังโจมตีได้ → แบน IP ที่พยายามเดารหัส/สแกน
#
#  jail ที่เปิด:
#    sshd             ssh login ล้มเหลว (อ่านจาก journald)
#    wordpress-login  POST /wp-login.php แล้วได้ 200 = รหัสผิด (สำเร็จจะได้ 302)
#    nginx-botsearch  สแกนหา path ที่ไม่มีอยู่ เช่น /phpmyadmin, /.git
#
#      sudo ./07-fail2ban.sh
# ===========================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_root
load_config

apt_install fail2ban python3-systemd

# ----- filter สำหรับ WordPress login -----
log "เขียน filter wordpress-login"
cat >/etc/fail2ban/filter.d/wordpress-login.conf <<'EOF'
# สร้างโดย 07-fail2ban.sh
# nginx access log (combined):  IP - - [date] "POST /wp-login.php HTTP/2.0" 200 ...
# WordPress ตอบ 200 เมื่อรหัสผิด (แสดงฟอร์มพร้อม error) และ 302 เมื่อ login สำเร็จ
[Definition]
failregex = ^<HOST> \S+ \S+ \[[^\]]*\] "POST /wp-login\.php[^"]*" 200
ignoreregex =
EOF

# ----- jail.local (ไม่แก้ jail.conf ตรง ๆ เพราะ apt upgrade จะทับ) -----
log "เขียน /etc/fail2ban/jail.local"
backup_file /etc/fail2ban/jail.local
cat >/etc/fail2ban/jail.local <<EOF
# สร้างโดย 07-fail2ban.sh
[DEFAULT]
# ใช้ iptables ให้เข้ากับ firewall ของขั้น 06 (สร้าง chain f2b-<jail> แทรกบนสุดของ INPUT)
banaction          = iptables-multiport
banaction_allports = iptables-allports
bantime  = 1h
findtime = 10m
maxretry = 5
# โดนซ้ำ ๆ → แบนนานขึ้นเรื่อย ๆ (1h, 2h, 4h, ... สูงสุด 1 สัปดาห์)
bantime.increment = true
bantime.maxtime   = 1w
# ห้ามแบน: localhost และแพลตฟอร์ม Azure (+ IP ที่กำหนดเองใน config.env)
ignoreip = 127.0.0.1/8 ::1 168.63.129.16 ${F2B_IGNORE_IP:-}

[sshd]
enabled = true
backend = systemd
port    = ${SSH_PORT:-22}
mode    = aggressive

[wordpress-login]
enabled  = true
port     = http,https
filter   = wordpress-login
logpath  = /var/log/nginx/access.log
maxretry = 5

[nginx-botsearch]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/access.log
           /var/log/nginx/error.log
EOF

systemctl enable fail2ban &>/dev/null
systemctl restart fail2ban
sleep 2
systemctl is-active --quiet fail2ban || die "fail2ban start ไม่ขึ้น — ดู: sudo journalctl -u fail2ban -n 50"
ok "fail2ban ทำงานแล้ว"

# ----- ทดสอบ filter กับ log ตัวอย่าง -----
log "ทดสอบ filter wordpress-login"
SAMPLE=$(mktemp)
cat >"$SAMPLE" <<'EOF'
203.0.113.7 - - [11/Oct/2026:10:00:00 +0000] "POST /wp-login.php HTTP/2.0" 200 4500 "-" "Mozilla/5.0"
203.0.113.8 - - [11/Oct/2026:10:00:01 +0000] "POST /wp-login.php HTTP/2.0" 302 0 "-" "Mozilla/5.0"
203.0.113.9 - - [11/Oct/2026:10:00:02 +0000] "GET /wp-login.php HTTP/2.0" 200 4500 "-" "Mozilla/5.0"
EOF
fail2ban-regex "$SAMPLE" /etc/fail2ban/filter.d/wordpress-login.conf | grep -E '^(Failregex|Lines):'
echo "    ↑ ต้องได้ Failregex: 1 total (เฉพาะบรรทัด POST ที่ได้ 200 = รหัสผิด)"
rm -f "$SAMPLE"

echo
fail2ban-client status
for j in sshd wordpress-login nginx-botsearch; do
  fail2ban-client status "$j" | sed -n '1p;/Currently banned/p;/Total failed/p'
done

cat <<EOF

ดู IP ที่ถูกแบน:   sudo fail2ban-client status <jail>
ปลดแบน:          sudo fail2ban-client set <jail> unbanip <IP>
EOF
