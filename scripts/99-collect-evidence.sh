#!/usr/bin/env bash
# ===========================================================
#  99 — เก็บหลักฐานทั้งหมดเป็นรายงาน Markdown
#       ตอบโจทย์ด่านที่ 1: "แสดงโครงสร้างสถาปัตยกรรมพร้อม version
#       ของโปรแกรมแต่ละตัว เช่น nginx ver? php ver? wordpress ver? MySQL ver?"
#
#      sudo ./99-collect-evidence.sh            แสดงบนจอ
#      sudo ./99-collect-evidence.sh report.md  เขียนลงไฟล์
# ===========================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_root
load_config

OUT="${1:-/dev/stdout}"
[[ $OUT != /dev/stdout ]] && exec 3>&1 && exec >"$OUT"

DOMAIN=$(full_domain)

# ---------- เก็บเวอร์ชัน ----------
V_OS=$(. /etc/os-release && echo "$PRETTY_NAME")
V_KERNEL=$(uname -r)
V_NGINX=$(nginx -v 2>&1 | grep -oP '[\d.]+' || echo "ไม่ได้ติดตั้ง")
V_PHP=$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo "ไม่ได้ติดตั้ง")
V_DB_RAW=$(mysql --version 2>/dev/null || echo "")
V_DB=$(grep -oP '\d+\.\d+\.\d+' <<<"$V_DB_RAW" | head -1 || echo "ไม่ได้ติดตั้ง")
V_DB_NAME=MySQL
V_WP=$(grep -oP "wp_version = '\K[^']+" "${WP_ROOT}/wp-includes/version.php" 2>/dev/null || echo "ไม่ได้ติดตั้ง")
V_OPENSSL=$(openssl version | awk '{print $2}')
V_ACME=$(/root/.acme.sh/acme.sh --version 2>/dev/null | tail -1 || echo "ไม่ได้ติดตั้ง")
PUBLIC_IP=$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || echo "?")

cat <<EOF
# รายงานสถาปัตยกรรมและหลักฐานการติดตั้ง

**โดเมน:** https://${DOMAIN}
**Public IP:** ${PUBLIC_IP}
**วันที่เก็บข้อมูล:** $(date '+%d/%m/%Y %H:%M:%S %Z')
**Hostname:** $(hostname)

---

## 1. ตารางเวอร์ชันของซอฟต์แวร์ (ด่านที่ 1)

| ชั้น | ซอฟต์แวร์ | เวอร์ชัน | บทบาท |
|---|---|---|---|
| OS | ${V_OS} | kernel ${V_KERNEL} | ระบบปฏิบัติการของ VPS |
| Web server | nginx | **${V_NGINX}** | รับ HTTP/HTTPS ที่ port 80/443 |
| Runtime | PHP-FPM | **${V_PHP}** | ประมวลผลไฟล์ .php ของ WordPress |
| Database | ${V_DB_NAME} | **${V_DB}** | เก็บเนื้อหา/ผู้ใช้/ตั้งค่าของเว็บ |
| CMS | WordPress | **${V_WP}** | ระบบจัดการเนื้อหา |
| TLS | OpenSSL | ${V_OPENSSL} | เข้ารหัสการเชื่อมต่อ HTTPS |
| ACME | acme.sh | ${V_ACME} | ขอ/ต่ออายุใบรับรองจาก Let's Encrypt |

### output จริงของคำสั่ง (ตามที่โจทย์กำหนด)
\`\`\`
\$ lsb_release -a
$(lsb_release -a 2>/dev/null)

\$ nginx -v
$(nginx -v 2>&1)

\$ php -v
$(php -v 2>&1 | head -1)

\$ mysql --version
$(mysql --version 2>&1)

\$ wp core version
$(sudo -u www-data wp core version --path="$WP_ROOT" 2>/dev/null || echo "ไม่ได้ติดตั้ง WP-CLI")

\$ openssl version
$(openssl version)
\`\`\`

## 2. แผนภาพการไหลของข้อมูล

\`\`\`
  ผู้ใช้ในไทย
      │  https (443)
      ▼
  ┌─────────────────────── VPS: ${PUBLIC_IP} ───────────────────────┐
  │  iptables + ipset ──► ถ้า src IP ไม่อยู่ใน ipset "th-net" → DROP │
  │      │ ผ่าน                                                      │
  │      ▼                                                            │
  │  nginx ${V_NGINX}  ── ถอดรหัส TLS, เสิร์ฟไฟล์ static            │
  │      │ fastcgi ผ่าน unix socket                                  │
  │      ▼                                                            │
  │  PHP-FPM ${V_PHP} ── รัน WordPress ${V_WP}                     │
  │      │ unix socket /var/run/mysqld/mysqld.sock                 │
  │      ▼                                                            │
  │  ${V_DB_NAME} ${V_DB}                                            │
  └───────────────────────────────────────────────────────────────────┘
\`\`\`

---

## 3. Checkpoint ด่านที่ 1: SSH

ผลจากคำสั่ง \`sshd -T\` (ค่าที่ sshd ใช้งานจริง ไม่ใช่แค่ที่เขียนในไฟล์):

| รายการที่โจทย์กำหนด | ค่าที่ตั้งไว้ | ผล |
|---|---|---|
EOF

EFF=$(sshd -T 2>/dev/null || echo "")
check_ssh() {
  local key=$1 want=$2 label=$3 got
  got=$(grep -i "^$key " <<<"$EFF" | awk '{print $2}')
  if [[ ${got,,} == "${want,,}" ]]; then
    echo "| $label | \`$key $got\` | ✅ ผ่าน |"
  else
    echo "| $label | \`$key ${got:-ไม่พบ}\` | ❌ ไม่ผ่าน (ต้องเป็น $want) |"
  fi
}
check_ssh permitrootlogin        no  "ปิด root login"
check_ssh passwordauthentication no  "ปิด password authentication"
check_ssh pubkeyauthentication   yes "เปิด PKI (public key)"
check_ssh permitemptypasswords   no  "ห้ามรหัสผ่านว่าง"
check_ssh kbdinteractiveauthentication no "ปิด keyboard-interactive"

cat <<EOF

\`\`\`
\$ sudo sshd -T | grep -E 'permitroot|password|pubkey'
$(grep -E 'permitroot|password|pubkey' <<<"$EFF")
\`\`\`

**user ที่อนุญาตให้ ssh:** \`$(grep -i '^allowusers' <<<"$EFF" | cut -d' ' -f2- || echo 'ทุก user')\`
**port:** \`$(grep -i '^port ' <<<"$EFF" | awk '{print $2}')\`

### public key ที่ติดตั้งไว้
\`\`\`
$(awk '{print "  " $1 "  ..." substr($2, length($2)-15) "  " $3}' \
    "$(getent passwd "$ADMIN_USER" | cut -d: -f6)/.ssh/authorized_keys" 2>/dev/null \
    || echo "  ไม่พบไฟล์ authorized_keys")
\`\`\`

### สิทธิ sudo
\`\`\`
$(id "$ADMIN_USER" 2>/dev/null || echo "ไม่พบ user $ADMIN_USER")
\`\`\`

---

## 4. HTTPS

EOF

CERT_DIR="/etc/nginx/ssl/$DOMAIN"
if [[ -f "$CERT_DIR/fullchain.pem" ]]; then
  cat <<EOF
| รายการ | ค่า |
|---|---|
| ผู้ออกใบรับรอง | $(openssl x509 -issuer -noout -in "$CERT_DIR/fullchain.pem" | sed 's/.*CN *= *//') |
| ออกให้ | $(openssl x509 -subject -noout -in "$CERT_DIR/fullchain.pem" | sed 's/.*CN *= *//') |
| เริ่มใช้ได้ | $(openssl x509 -startdate -noout -in "$CERT_DIR/fullchain.pem" | cut -d= -f2) |
| หมดอายุ | $(openssl x509 -enddate -noout -in "$CERT_DIR/fullchain.pem" | cut -d= -f2) |
| วิธีตรวจสอบสิทธิ์ | DNS-01 (TXT record บน DuckDNS) |
| ต่ออายุอัตโนมัติ | $(crontab -l 2>/dev/null | grep -qF acme.sh && echo 'cron ของ acme.sh' || echo 'ไม่พบ cron') |

**เหตุผลที่เลือก DNS-01 ไม่ใช่ HTTP-01:** เซิร์ฟเวอร์ตรวจสอบของ Let's Encrypt
อยู่ต่างประเทศ ถ้าใช้ HTTP-01 แล้วเปิด geo-block ของด่านที่ 2 การต่ออายุอัตโนมัติ
จะล้มเหลวทุกครั้ง ส่วน DNS-01 เราเป็นฝ่ายไปวาง TXT record เองจึงไม่ติดปัญหานี้

### TLS protocol ที่เปิดใช้
\`\`\`
$(grep -h 'ssl_protocols' /etc/nginx/sites-available/$DOMAIN 2>/dev/null | tr -s ' ' || echo "ไม่พบ")
\`\`\`
EOF
else
  echo "> ยังไม่ได้ติดตั้งใบรับรอง — รัน \`05-https-acme.sh\`"
fi

cat <<EOF

---

## 5. Firewall (ด่านที่ 2)

EOF

if ipset list -n 2>/dev/null | grep -qx th-net; then
  cat <<EOF
| รายการ | ค่า |
|---|---|
| จำนวน CIDR block ของไทยใน ipset (IPv4) | **$(ipset list th-net | grep -c '^[0-9]')** |
| จำนวน CIDR block ของไทยใน ipset (IPv6) | **$(ipset list th-net6 2>/dev/null | grep -cE '^[0-9a-f]+:' || echo 0)** |
| INPUT policy | \`$(iptables -S | grep '^-P INPUT' | awk '{print $3}')\` |
| FORWARD policy | \`$(iptables -S | grep '^-P FORWARD' | awk '{print $3}')\` |
| IPv6 INPUT policy | \`$(ip6tables -S | grep '^-P INPUT' | awk '{print $3}')\` |
| cron อัปเดตรายการ IP | \`$(grep -v '^#' /etc/cron.d/th-ipset-refresh 2>/dev/null | grep -E '^[0-9*]' || echo 'ไม่พบ')\` |
| rule ถาวรหลัง reboot | netfilter-persistent: $(systemctl is-enabled netfilter-persistent 2>/dev/null || echo 'ไม่ได้เปิด') + ipset-persistent |
| fail2ban jails | $(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:\s*//p' || echo 'ไม่ได้ติดตั้ง') |

### \`sudo ipset list -t\`
\`\`\`
$(ipset list -t)
\`\`\`

### \`sudo iptables -L -n -v\` (พร้อมจำนวน packet ที่ผ่าน/ถูกบล็อก)
\`\`\`
$(iptables -L -n -v)
\`\`\`

### \`sudo ip6tables -L INPUT -n -v\`
\`\`\`
$(ip6tables -L INPUT -n -v)
\`\`\`

### chain ตรวจประเทศ
\`\`\`
$(iptables -L GEO-CHECK -n -v 2>/dev/null || echo "ไม่พบ chain GEO-CHECK")
\`\`\`

### ตัวอย่าง log การเชื่อมต่อที่ถูกบล็อก (20 รายการล่าสุด)
\`\`\`
$(journalctl -k --grep='GEOBLOCK-DROP' -n 20 --no-pager -o short 2>/dev/null \
   | sed 's/SRC=\([0-9.]*\)/SRC=\1/' || echo "ยังไม่มี log")
\`\`\`
EOF
else
  echo "> ยังไม่ได้ติดตั้ง firewall — รัน \`06-firewall-th-only.sh\`"
fi

cat <<EOF

---

## 6. สถานะ service

\`\`\`
$(for s in ssh nginx mysql "php$(php_version)-fpm" cron fail2ban netfilter-persistent; do
    printf '%-24s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null || echo '-')"
  done)
\`\`\`

## 7. Port ที่เปิดฟังอยู่

\`\`\`
$(ss -tulnp 2>/dev/null | grep -E 'LISTEN' | awk '{printf "%-8s %-24s %s\n", $1, $5, $7}')
\`\`\`

> **สิ่งที่ควรเห็น:** 3306 (ฐานข้อมูล) ต้องผูกกับ \`127.0.0.1\` ไม่ใช่ \`0.0.0.0\`
> เพราะไม่ควรเปิดฐานข้อมูลออกอินเทอร์เน็ต

## 8. การใช้ทรัพยากร

\`\`\`
$(free -h)

$(df -h / | tail -1 | awk '{print "disk /: ใช้ " $3 " จาก " $2 " (" $5 ")"}')
swap: $(swapon --show --noheadings 2>/dev/null | awk '{print $1, $3}' || echo 'ไม่ได้ตั้ง swap')
\`\`\`

> ตามที่เรียน: ถ้า RAM ไม่พอระบบจะไปใช้ **swap area** บน disk ซึ่งช้ากว่า RAM มาก
> VPS ที่ RAM น้อย (1GB) ควรตั้ง swap ไว้ ไม่งั้น MySQL อาจถูก OOM killer ฆ่า

---
*รายงานนี้สร้างอัตโนมัติโดย \`scripts/99-collect-evidence.sh\`*
EOF

if [[ $OUT != /dev/stdout ]]; then
  exec >&3
  ok "เขียนรายงานลง $OUT แล้ว"
  log "แนบไฟล์นี้ไปกับงานที่ส่ง หรือแปลงเป็น PDF: pandoc $OUT -o report.pdf"
fi
