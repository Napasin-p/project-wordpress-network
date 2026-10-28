#!/usr/bin/env bash
# ===========================================================
#  05 — ขอใบรับรอง HTTPS จาก Let's Encrypt ด้วย acme.sh (DNS-01 ผ่าน DuckDNS)
#
#  ทำไมต้อง DNS-01 ไม่ใช่ HTTP-01:
#    HTTP-01  : Let's Encrypt ต้องยิง HTTP เข้ามาที่ port 80 ของเรา
#               แต่เซิร์ฟเวอร์ตรวจสอบของเขาอยู่ "ต่างประเทศ"
#               → พอด่านที่ 2 บล็อก IP ต่างประเทศ การต่ออายุจะพังทุกครั้ง
#    DNS-01   : เราเป็นฝ่ายไปวาง TXT record บน DuckDNS เอง (connection ขาออก)
#               Let's Encrypt แค่อ่าน DNS ไม่ต้องต่อเข้า server เรา
#               → ใช้ร่วมกับ geo-block ได้ ต่ออายุอัตโนมัติไม่พัง
#
#      sudo ./05-https-acme.sh             ขอใบรับรองจริง
#      sudo ./05-https-acme.sh --staging   ทดสอบกับ staging CA ก่อน (ไม่ติด rate limit)
#      sudo ./05-https-acme.sh --force     ขอใหม่ทับของเดิม (เช่น หลังทดสอบ staging)
# ===========================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_root
load_config
require_vars DUCKDNS_SUBDOMAIN DUCKDNS_TOKEN ADMIN_EMAIL WP_ROOT

DOMAIN=$(full_domain)
VHOST=/etc/nginx/sites-available/${DOMAIN}
SSL_DIR=/etc/nginx/ssl/${DOMAIN}

# acme.sh ติดตั้งไว้ใน home ของ root (sudo บน Ubuntu ตั้ง HOME=/root ให้อยู่แล้ว กันพลาด)
export HOME=/root
ACME=/root/.acme.sh/acme.sh

SERVER=letsencrypt
EXTRA=()
for arg in "$@"; do
  case $arg in
    --staging) SERVER=letsencrypt_test; EXTRA+=(--force) ;;
    --force)   EXTRA+=(--force) ;;
    *) die "ไม่รู้จัก option: $arg" ;;
  esac
done

[[ -f /etc/nginx/sites-enabled/${DOMAIN} ]] || die "ไม่พบ vhost ของ $DOMAIN — รัน 03-install-wordpress.sh ก่อน"

# ===========================================================
#  1. ติดตั้ง acme.sh
# ===========================================================
apt_install curl cron openssl
if [[ ! -x $ACME ]]; then
  log "ติดตั้ง acme.sh (จะเพิ่ม cron ต่ออายุอัตโนมัติใน crontab ของ root ให้เอง)"
  curl -fsSL https://get.acme.sh | sh -s email="$ADMIN_EMAIL"
fi
"$ACME" --upgrade --auto-upgrade >/dev/null
# ค่า default ของ acme.sh คือ ZeroSSL — โจทย์ต้องการ Let's Encrypt
"$ACME" --set-default-ca --server letsencrypt >/dev/null
ok "acme.sh $("$ACME" --version | tail -1) (default CA: Let's Encrypt)"

# ===========================================================
#  2. ขอใบรับรองด้วย DNS-01 ผ่าน DuckDNS API
#     acme.sh จำ token ไว้ใน /root/.acme.sh/account.conf → ตอนต่ออายุไม่ต้องใส่ใหม่
#     --dnssleep 60: รอ 60 วินาทีให้ TXT record กระจายก่อนให้ Let's Encrypt ตรวจ
# ===========================================================
log "ขอใบรับรองสำหรับ $DOMAIN (server: $SERVER, DNS-01)"
warn "ขั้นนี้ใช้เวลาประมาณ 1-2 นาที"
rc=0
DuckDNS_Token="$DUCKDNS_TOKEN" "$ACME" --issue \
  --dns dns_duckdns \
  -d "$DOMAIN" \
  --server "$SERVER" \
  --keylength ec-256 \
  --dnssleep 60 \
  "${EXTRA[@]}" || rc=$?

case $rc in
  0) ok "ได้ใบรับรองแล้ว" ;;
  2) log "มีใบรับรองที่ยังไม่ถึงเวลาต่ออายุอยู่แล้ว ข้าม (ใช้ --force ถ้าต้องการขอใหม่)" ;;
  *) die "ขอใบรับรองไม่สำเร็จ (exit $rc) — สาเหตุที่พบบ่อย:
      token/subdomain ผิด, DNS ยังไม่ propagate (ลองใหม่), โดน rate limit
      ดู log เต็ม: sudo $ACME --issue ... --debug 2" ;;
esac

# ===========================================================
#  3. ติดตั้งใบรับรองให้ nginx
#     --install-cert คัดลอกไฟล์ไปที่ที่เรากำหนด และจำ reloadcmd ไว้
#     ทุกครั้งที่ต่ออายุสำเร็จ acme.sh จะ copy ไฟล์ใหม่ + reload nginx ให้เอง
# ===========================================================
log "ติดตั้งใบรับรองที่ $SSL_DIR"
install -d -m 700 "$SSL_DIR"
"$ACME" --install-cert -d "$DOMAIN" --ecc \
  --key-file       "$SSL_DIR/privkey.pem" \
  --fullchain-file "$SSL_DIR/fullchain.pem" \
  --reloadcmd      "systemctl reload nginx"
chmod 600 "$SSL_DIR/privkey.pem"

# ===========================================================
#  4. nginx: redirect http → https + server 443
# ===========================================================
log "ตั้งค่า nginx ให้ใช้ HTTPS"
backup_file "$VHOST"

cat >"$VHOST" <<EOF
# ===== WordPress vhost (HTTPS) — $DOMAIN =====
# สร้างโดย 05-https-acme.sh

# ---------- port 80: redirect ไป https ทั้งหมด ----------
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

# ---------- port 443: ตัวเว็บจริง ----------
server {
    # Ubuntu 24.04 มี nginx 1.24 → ใช้ "listen ... http2" (คำสั่ง "http2 on;" ต้อง 1.25.1+)
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    root ${WP_ROOT};
    index index.php index.html;

    # ---------- ใบรับรองจาก Let's Encrypt (acme.sh ต่ออายุให้เอง) ----------
    ssl_certificate     ${SSL_DIR}/fullchain.pem;
    ssl_certificate_key ${SSL_DIR}/privkey.pem;

    # ---------- การเข้ารหัส (TLS) ----------
    # รับแค่ TLS 1.2/1.3 — 1.0/1.1 มีช่องโหว่และเลิกใช้แล้ว
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    # ไม่เปิด ssl_stapling: Let's Encrypt เลิกให้บริการ OCSP ตั้งแต่ปี 2025

    # HSTS: บอก browser ว่าเว็บนี้ต้องต่อด้วย https เท่านั้น
    add_header Strict-Transport-Security "max-age=31536000" always;

    include snippets/wordpress-common.conf;
}
EOF

nginx -t || die "nginx config ผิด — ดูข้อความข้างบน (ไฟล์เดิมสำรองไว้เป็น .bak.*)"
systemctl reload nginx
ok "nginx ให้บริการ HTTPS แล้ว"

# ===========================================================
#  5. ตรวจผลลัพธ์ (ใช้เป็นหลักฐาน)
# ===========================================================
echo
log "ใบรับรองที่ nginx ใช้:"
openssl x509 -in "$SSL_DIR/fullchain.pem" -noout -subject -issuer -dates | sed 's/^/    /'

echo
log "กำหนดการต่ออายุ (acme.sh --list):"
"$ACME" --list | sed 's/^/    /'

echo
log "cron ต่ออายุของ acme.sh (crontab ของ root):"
crontab -l 2>/dev/null | grep -F acme.sh | sed 's/^/    /' \
  || warn "ไม่พบ cron ของ acme.sh — รัน: sudo $ACME --install-cronjob"

echo
log "ทดสอบ redirect http → https:"
curl -sSI --max-time 10 "http://${DOMAIN}" | grep -iE '^(HTTP|location)' | sed 's/^/    /' || true

[[ $SERVER == letsencrypt_test ]] && warn "นี่คือใบรับรอง STAGING (browser จะไม่เชื่อถือ) — ผ่านแล้วให้รัน: sudo $0 --force"

cat <<EOF

  URL       : ${_C_GREEN}https://${DOMAIN}${_C_RESET}
  ใบรับรอง   : Let's Encrypt (อายุ 90 วัน, acme.sh ต่ออายุเมื่อเหลือ ~30 วัน)
  ต่ออายุ    : cron ของ acme.sh → DNS-01 จึงไม่ติด geo-block ของด่านที่ 2

${_C_RED}ทำต่อทันที:${_C_RESET} เปิด https://${DOMAIN} แล้วทำ setup wizard ของ WordPress
            (username ห้ามเป็น "admin")
EOF
