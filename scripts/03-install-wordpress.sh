#!/usr/bin/env bash
# ===========================================================
#  03 — ติดตั้ง WordPress + สร้าง database + nginx vhost
#      sudo ./03-install-wordpress.sh
# ===========================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_root
load_config
require_vars DUCKDNS_SUBDOMAIN WP_DB_NAME WP_DB_USER WP_DB_PASS WP_ROOT

DOMAIN=$(full_domain)
FPM_SOCK=$(php_fpm_sock)
VHOST=/etc/nginx/sites-available/${DOMAIN}

# ===========================================================
#  1. สร้าง database และ user ของ WordPress
#     หลักการ least privilege: user นี้แตะได้แค่ database ตัวเอง
# ===========================================================
log "สร้าง database '$WP_DB_NAME' และ user '$WP_DB_USER'"
mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${WP_DB_NAME}\`
  DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${WP_DB_USER}'@'localhost' IDENTIFIED BY '${WP_DB_PASS}';
ALTER USER '${WP_DB_USER}'@'localhost' IDENTIFIED BY '${WP_DB_PASS}';
GRANT ALL PRIVILEGES ON \`${WP_DB_NAME}\`.* TO '${WP_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
ok "database พร้อม (charset utf8mb4 — รองรับภาษาไทยและ emoji)"

# ===========================================================
#  2. ดาวน์โหลด WordPress
# ===========================================================
if [[ -f "$WP_ROOT/wp-includes/version.php" ]]; then
  log "มี WordPress อยู่ที่ $WP_ROOT แล้ว ข้ามการดาวน์โหลด"
else
  log "ดาวน์โหลด WordPress เวอร์ชันล่าสุด"
  apt_install curl tar
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL https://wordpress.org/latest.tar.gz -o "$TMP/wp.tar.gz" \
    || die "ดาวน์โหลดไม่ได้ — ตรวจว่า VPS ออกเน็ตได้ (ถ้าลง firewall ไปแล้วให้ตรวจ OUTPUT chain)"
  tar -xzf "$TMP/wp.tar.gz" -C "$TMP"
  install -d "$WP_ROOT"
  cp -a "$TMP/wordpress/." "$WP_ROOT/"
  ok "แตกไฟล์ลง $WP_ROOT"
fi

WP_VERSION=$(grep -oP "wp_version = '\K[^']+" "$WP_ROOT/wp-includes/version.php")
log "WordPress version: $WP_VERSION"

# ===========================================================
#  3. สร้าง wp-config.php
# ===========================================================
if [[ -f "$WP_ROOT/wp-config.php" ]]; then
  log "มี wp-config.php อยู่แล้ว ข้าม (ถ้าต้องการสร้างใหม่ให้ลบไฟล์เดิมก่อน)"
else
  log "สร้าง wp-config.php"
  # salt ใช้เข้ารหัส cookie/session — ต้องสุ่มและเป็นความลับ
  SALTS=$(curl -fsSL https://api.wordpress.org/secret-key/1.1/salt/ 2>/dev/null) || SALTS=""
  if [[ -z $SALTS ]]; then
    warn "ขอ salt จาก api.wordpress.org ไม่ได้ — สุ่มเองด้วย openssl"
    SALTS=""
    for k in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY \
             AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
      SALTS+="define('$k', '$(openssl rand -base64 48 | tr -d '\n')');"$'\n'
    done
  fi

  cat >"$WP_ROOT/wp-config.php" <<EOF
<?php
/**
 * wp-config.php — สร้างโดย 03-install-wordpress.sh
 * งานกลุ่มวิทยาการคอมพิวเตอร์
 */

// ---------- การเชื่อมต่อฐานข้อมูล ----------
define( 'DB_NAME',     '${WP_DB_NAME}' );
define( 'DB_USER',     '${WP_DB_USER}' );
define( 'DB_PASSWORD', '${WP_DB_PASS}' );
define( 'DB_HOST',     'localhost' );
define( 'DB_CHARSET',  'utf8mb4' );
define( 'DB_COLLATE',  '' );

// ---------- กุญแจสุ่มสำหรับเข้ารหัส cookie ----------
${SALTS}

\$table_prefix = 'wp_';

// ---------- บังคับใช้ HTTPS ----------
define( 'WP_HOME',    'https://${DOMAIN}' );
define( 'WP_SITEURL', 'https://${DOMAIN}' );
define( 'FORCE_SSL_ADMIN', true );

// อยู่หลัง reverse proxy / Cloudflare → ให้ WordPress รู้ว่า request เดิมเป็น https
if ( isset( \$_SERVER['HTTP_X_FORWARDED_PROTO'] )
     && 'https' === \$_SERVER['HTTP_X_FORWARDED_PROTO'] ) {
    \$_SERVER['HTTPS'] = 'on';
}

// ---------- ความปลอดภัย ----------
define( 'DISALLOW_FILE_EDIT', true );   // ปิดการแก้ไฟล์ธีม/ปลั๊กอินผ่านหน้าเว็บ
define( 'WP_AUTO_UPDATE_CORE', 'minor' ); // อัปเดตแพตช์ความปลอดภัยอัตโนมัติ

// ---------- ปิด debug บนเครื่องจริง ----------
define( 'WP_DEBUG', false );
define( 'WP_DEBUG_DISPLAY', false );
define( 'WP_DEBUG_LOG', false );

if ( ! defined( 'ABSPATH' ) ) {
    define( 'ABSPATH', __DIR__ . '/' );
}
require_once ABSPATH . 'wp-settings.php';
EOF
  ok "สร้าง wp-config.php แล้ว"
fi

# ===========================================================
#  4. ตั้งสิทธิไฟล์
#     directory 755 / file 644 — www-data อ่านได้ เขียนได้แค่ที่จำเป็น
# ===========================================================
log "ตั้งเจ้าของและสิทธิไฟล์"
chown -R www-data:www-data "$WP_ROOT"
find "$WP_ROOT" -type d -exec chmod 755 {} \;
find "$WP_ROOT" -type f -exec chmod 644 {} \;
chmod 640 "$WP_ROOT/wp-config.php"   # มีรหัส database อยู่ข้างใน จำกัดให้แคบลง
install -d -m 755 -o www-data -g www-data "$WP_ROOT/wp-content/uploads"
ok "สิทธิไฟล์เรียบร้อย (dir 755 / file 644 / wp-config 640)"

# ===========================================================
#  5. nginx virtual host
# ===========================================================
if [[ -f $VHOST ]] && grep -q 'listen 443' "$VHOST"; then
  # รันซ้ำหลังขั้น 05 แล้ว — อย่าเขียนทับ vhost แบบ HTTPS (อัปเดตแค่ snippet ด้านล่าง)
  log "vhost ของ $DOMAIN เป็น HTTPS แล้ว (จากขั้น 05) ข้ามการเขียนทับ"
else
log "สร้าง nginx vhost สำหรับ $DOMAIN"
backup_file "$VHOST"

cat >"$VHOST" <<EOF
# ===== WordPress vhost — $DOMAIN =====
# สร้างโดย 03-install-wordpress.sh

server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    root ${WP_ROOT};
    index index.php index.html;

    # ขั้น 05 (acme.sh) จะเขียนไฟล์นี้ใหม่: redirect http → https + server 443
    include snippets/wordpress-common.conf;
}
EOF
fi

# ----- ส่วนที่ใช้ร่วมกันทั้ง http และ https -----
install -d /etc/nginx/snippets
cat >/etc/nginx/snippets/wordpress-common.conf <<EOF
# ===================================================
#   กฎความปลอดภัย (ใช้อ้างอิงตอนนำเสนอได้)
#   ⚠️ ต้องอยู่ "ก่อน" location ~ \.php$ เพราะ nginx เลือก regex location
#      ข้อแรกที่ตรง ถ้าวางไว้หลัง กฎห้ามรัน PHP ใน uploads จะไม่มีผล
# ===================================================

# ห้ามเข้าถึงไฟล์ config ที่มีรหัสผ่าน
location = /wp-config.php { deny all; }

# ปิด xmlrpc.php — ถูกใช้ brute-force และ DDoS บ่อยที่สุดใน WordPress
location = /xmlrpc.php { deny all; access_log off; log_not_found off; }

# ห้ามรัน PHP ในโฟลเดอร์ uploads
# (กันกรณีคนแนบ shell.php ปลอมเป็นรูปแล้วเรียกใช้)
location ~* ^/wp-content/uploads/.*\.(php|phtml|phar)\$ { deny all; }

# ซ่อนไฟล์ซ่อนและไฟล์สำรอง
location ~ /\.(?!well-known) { deny all; }
location ~* \.(sql|bak|log|ini|conf|env)\$ { deny all; }

# การสืบรายชื่อ user (REST /wp/v2/users, ?author=N) กันที่ mu-plugin block-user-enum.php (สคริปต์ 08)
# ห้ามบล็อกที่ nginx: nginx แยกไม่ออกว่าใคร login → block editor ของทีมเรียก /wp/v2/users/me ไม่ได้

# ---------- permalink สวย ๆ ----------
# ถ้าไม่มีไฟล์จริงตาม URL ให้ส่งต่อให้ index.php จัดการ
location / {
    try_files \$uri \$uri/ /index.php?\$args;
}

# ---------- ส่ง .php ให้ PHP-FPM ----------
location ~ \.php\$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass unix:${FPM_SOCK};
    fastcgi_read_timeout 120;
}

# ---------- cache ไฟล์ static ----------
location ~* \.(jpg|jpeg|png|gif|webp|svg|ico|css|js|woff2?)\$ {
    expires 30d;
    add_header Cache-Control "public, immutable";
    access_log off;
}

# ---------- security header ----------
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header X-XSS-Protection "1; mode=block" always;

EOF

ln -sfn "$VHOST" "/etc/nginx/sites-enabled/${DOMAIN}"

log "ตรวจไวยากรณ์ nginx"
nginx -t || die "nginx config ผิด — แก้ก่อน reload"
systemctl reload nginx
ok "nginx reload แล้ว"

# ===========================================================
#  6. WP-CLI — ใช้ดึง version (wp core version) และจัดการ WordPress จาก command line
# ===========================================================
if ! command -v wp &>/dev/null; then
  log "ติดตั้ง WP-CLI"
  curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
       -o /usr/local/bin/wp
  chmod 755 /usr/local/bin/wp
fi
ok "WP-CLI $(wp --version --allow-root 2>/dev/null | awk '{print $2}')"
log "wp core version: $(sudo -u www-data wp core version --path="$WP_ROOT")"

# ===========================================================
#  7. ให้ WordPress เรียกตัวเองผ่าน localhost (WP-Cron, Site Health, loopback)
#     ถ้าไม่ทำ: เครื่อง resolve โดเมนเป็น public IP → packet ออกนอกแล้ววนกลับเข้ามา
#     ด้วย IP ของ Azure (ไม่ใช่ไทย) → geo-block ด่าน 2 ทิ้ง → WP-Cron ตายเงียบ ๆ
# ===========================================================
grep -q " ${DOMAIN}" /etc/hosts || echo "127.0.0.1 ${DOMAIN}   # WordPress loopback (กัน geo-block)" >>/etc/hosts
ok "/etc/hosts: ${DOMAIN} → 127.0.0.1"

# ===========================================================
#  สรุป
# ===========================================================
echo
ok "ติดตั้ง WordPress $WP_VERSION เสร็จแล้ว"
cat <<EOF

  ตำแหน่งไฟล์   : $WP_ROOT
  database      : $WP_DB_NAME (user: $WP_DB_USER)
  URL           : https://$DOMAIN  (ใช้ได้หลังขั้น 05)

${_C_YELLOW}ขั้นถัดไป${_C_RESET}
  1) ถ้ายังไม่ได้ตั้ง DNS:   sudo ./04-duckdns.sh
  2) ขอใบรับรอง HTTPS:      sudo ./05-https-acme.sh
     (wp-config บังคับ https แล้ว เปิด http ตอนนี้จะ redirect ไป https ที่ยังไม่มี cert)
  3) ${_C_RED}ทันทีหลังขั้น 05${_C_RESET} เปิด https://$DOMAIN แล้วทำ setup wizard ของ WordPress
     (ตั้งชื่อเว็บ, สร้าง admin — ${_C_RED}อย่าใช้ username ว่า admin${_C_RESET})
     ระหว่างที่ยังไม่ทำ wizard ใครเข้าเว็บก่อนก็ยึดเว็บไปได้ อย่าทิ้งไว้
  4) ติดตั้ง firewall ท้ายสุด: sudo ./06-firewall-th-only.sh
EOF
