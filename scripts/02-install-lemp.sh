#!/usr/bin/env bash
# ===========================================================
#  02 — ติดตั้ง LEMP stack:  nginx + PHP-FPM + MySQL 8
#       (L=Linux, E=Engine-x/nginx, M=MySQL, P=PHP)
#      sudo ./02-install-lemp.sh
# ===========================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_root
load_config

log "อัปเดตรายชื่อ package"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

# ===========================================================
#  1. nginx — web server ฟัง port 80 (HTTP) / 443 (HTTPS)
# ===========================================================
log "ติดตั้ง nginx"
apt_install nginx
systemctl enable --now nginx

# ลบ default site ออก กันชนกับ vhost ของเรา
rm -f /etc/nginx/sites-enabled/default

# ----- ซ่อนเวอร์ชัน nginx (ทั้ง header "Server:" และหน้า error) -----
# วางใน conf.d/ ซึ่งถูก include ใน http {} → มีผลกับทุก server block
cat >/etc/nginx/conf.d/00-hardening.conf <<'EOF'
# สร้างโดย 02-install-lemp.sh
server_tokens off;
EOF
nginx -t && systemctl reload nginx
ok "nginx $(nginx -v 2>&1 | grep -oP '[\d.]+') (server_tokens off)"

# ===========================================================
#  2. PHP-FPM + extension ที่ WordPress ต้องใช้
#     nginx ไม่รัน PHP เอง แต่ส่งต่อให้ php-fpm ผ่าน unix socket
# ===========================================================
log "ติดตั้ง PHP-FPM และ extension"
apt_install \
  php-fpm php-cli php-mysql php-curl php-gd php-mbstring php-xml \
  php-zip php-intl php-bcmath php-imagick

PHPVER=$(php_version)
PHP_FPM_SERVICE="php${PHPVER}-fpm"
systemctl enable --now "$PHP_FPM_SERVICE"
ok "PHP $PHPVER (service: $PHP_FPM_SERVICE)"

# ----- ปรับ php.ini ให้เหมาะกับ WordPress -----
PHP_INI="/etc/php/${PHPVER}/fpm/php.ini"
if [[ -f $PHP_INI ]]; then
  log "ปรับค่าใน $PHP_INI"
  backup_file "$PHP_INI"
  # ปรับขนาดไฟล์อัปโหลด (ธีม/ปลั๊กอิน/รูปภาพของ WordPress มักเกิน 2M ที่เป็นค่า default)
  sed -i \
    -e 's/^;*upload_max_filesize *=.*/upload_max_filesize = 32M/' \
    -e 's/^;*post_max_size *=.*/post_max_size = 32M/' \
    -e 's/^;*memory_limit *=.*/memory_limit = 256M/' \
    -e 's/^;*max_execution_time *=.*/max_execution_time = 120/' \
    -e 's/^;*cgi.fix_pathinfo *=.*/cgi.fix_pathinfo = 0/' \
    -e 's/^;*expose_php *=.*/expose_php = Off/' \
    "$PHP_INI"
  # expose_php = Off ซ่อน header X-Powered-By ไม่บอกเวอร์ชัน PHP ให้คนสแกน
  systemctl restart "$PHP_FPM_SERVICE"
  ok "ปรับ php.ini แล้ว (upload 32M, memory 256M, expose_php = Off)"
fi

# ===========================================================
#  3. MySQL 8 — DBMS ที่ WordPress เก็บเนื้อหา
# ===========================================================
log "ติดตั้ง MySQL Server 8"
apt_install mysql-server mysql-client
systemctl enable --now mysql

# ----- ปรับการใช้ RAM ให้เหมาะกับ VM 4 GB (B2als_v2) — ยังรันได้ถ้าลดเหลือ 1 GB -----
# performance_schema กิน RAM ~200MB ถ้าเปิดไว้ — ปิดเพราะไม่ได้ใช้
LOWMEM_CNF=/etc/mysql/mysql.conf.d/99-lowmem.cnf
cat >"$LOWMEM_CNF" <<'EOF'
# สร้างโดย 02-install-lemp.sh — ขนาดสำหรับเว็บเล็ก บน VM 4 GB
[mysqld]
performance_schema      = OFF
innodb_buffer_pool_size = 512M
innodb_log_buffer_size  = 8M
max_connections         = 100
key_buffer_size         = 8M
tmp_table_size          = 16M
max_heap_table_size     = 16M
EOF

# ----- ให้ MySQL ฟังแค่ localhost ไม่เปิดออกเน็ต -----
# (ค่า default ของ Ubuntu เป็น 127.0.0.1 อยู่แล้ว ตรวจซ้ำกันพลาด)
BIND_CONF=/etc/mysql/mysql.conf.d/mysqld.cnf
if [[ -f $BIND_CONF ]] && ! grep -qE '^bind-address\s*=\s*127\.0\.0\.1' "$BIND_CONF"; then
  backup_file "$BIND_CONF"
  sed -i -E 's/^#?\s*bind-address\s*=.*/bind-address = 127.0.0.1/' "$BIND_CONF"
fi
systemctl restart mysql
ok "MySQL $(mysql --version | grep -oP '\d+\.\d+\.\d+' | head -1) ฟังที่ 127.0.0.1"

# ===========================================================
#  4. mysql_secure_installation (ตอบคำถามเอง)
#     บน Ubuntu root ของ MySQL ใช้ auth_socket → ต้องเป็น root ของเครื่องจึงเข้าได้
#     สคริปต์จะบอกว่า "Skipping password set for root" ซึ่งถูกต้องแล้ว
#
#     คำตอบที่แนะนำ:
#       VALIDATE PASSWORD component?            y  → เลือก 1 (MEDIUM) หรือ 2 (STRONG)
#       Remove anonymous users?                 y
#       Disallow root login remotely?           y
#       Remove test database?                   y
#       Reload privilege tables now?            y
# ===========================================================
echo
warn "ต่อไปจะรัน mysql_secure_installation — ตอบ y ทุกข้อ (ดูคำอธิบายในสคริปต์)"
mysql_secure_installation </dev/tty

# ===========================================================
#  สรุป
# ===========================================================
echo
ok "ติดตั้ง LEMP เสร็จแล้ว"
printf '\n  %-14s %s\n' "nginx"   "$(nginx -v 2>&1 | grep -oP '[\d.]+')"
printf '  %-14s %s\n'   "PHP"     "$(php -r 'echo PHP_VERSION;')"
printf '  %-14s %s\n'   "MySQL"   "$(mysql --version | grep -oP '\d+\.\d+\.\d+' | head -1)"
printf '  %-14s %s\n'   "FPM sock" "$(php_fpm_sock)"
echo
ss -tlnp | grep -E ':(80|443|3306|33060)\s' || true
echo
log "ขั้นถัดไป: sudo ./03-install-wordpress.sh"
