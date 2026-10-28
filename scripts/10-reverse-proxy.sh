#!/usr/bin/env bash
# ===========================================================
#  10 — Stage 2 Phase 2: Nginx หน้าบ้าน (reverse proxy)
#
#    ผู้ใช้ ─443─► Nginx หน้าบ้าน: TLS · rate limit · micro-cache · X-Cache-Status
#                   ├─► 127.0.0.1:8080  Nginx origin + PHP-FPM (WordPress)
#                   └─► 127.0.0.1:8081  /security-dashboard/ (logwatch container, มีรหัสผ่าน)
#
#      sudo ./10-reverse-proxy.sh             ติดตั้ง (สลับแบบ atomic ด้วย nginx reload)
#      sudo ./10-reverse-proxy.sh --rollback  คืน config ก่อนติดตั้ง
#  ไม่แตะ firewall — origin/dashboard ฟังแค่ 127.0.0.1
# ===========================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_root
load_config
require_vars DUCKDNS_SUBDOMAIN WP_ROOT

DOMAIN=$(full_domain)
SITES=/etc/nginx/sites-available
FRONT=$SITES/$DOMAIN                       # ไฟล์เดิม (จากขั้น 05) → กลายเป็นหน้าบ้าน
ORIGIN=$SITES/wp-origin
HTPASSWD=/etc/nginx/.htpasswd-dashboard
BK=/root/nginx-backup-phase2
SSL_DIR=/etc/nginx/ssl/$DOMAIN
# โดเมนเพิ่มเติม (Phase 3 — Cloudflare) คั่นด้วยช่องว่าง
EXTRA_DOMAINS="${EXTRA_DOMAINS:-}"

reload_or_die() {
  if nginx -t 2>/tmp/nginx-t.log; then systemctl reload nginx; ok "nginx reload แล้ว"
  else cat /tmp/nginx-t.log >&2; return 1; fi
}

if [[ ${1:-} == --rollback ]]; then
  [[ -d $BK ]] || die "ไม่พบไฟล์สำรองที่ $BK"
  cp -a "$BK/$DOMAIN" "$FRONT"
  rm -f /etc/nginx/sites-enabled/wp-origin /etc/nginx/conf.d/20-proxy.conf
  reload_or_die || die "rollback แล้วแต่ nginx -t ไม่ผ่าน — ตรวจด้วยมือ"
  ok "คืน config เดิมแล้ว (WordPress รับ 443 ตรงเหมือนก่อน Phase 2)"
  exit 0
fi

[[ -f $SSL_DIR/fullchain.pem ]] || die "ไม่พบใบรับรองที่ $SSL_DIR — ทำขั้น 05 ก่อน"
grep -q 'proxy_pass http://wp_origin' "$FRONT" 2>/dev/null && log "หน้าบ้านติดตั้งอยู่แล้ว — เขียนทับด้วยค่าปัจจุบัน"

# ----- 0) สำรองครั้งแรก (ไม่ทับของเดิมถ้ารันซ้ำ) -----
if [[ ! -d $BK ]]; then
  install -d -m 700 "$BK"
  cp -a "$FRONT" "$BK/$DOMAIN"
  ok "สำรอง vhost เดิมไว้ที่ $BK"
fi
apt_install apache2-utils     # htpasswd

# ===========================================================
#  1) ค่าระดับ http: rate limit zone, cache zone, upstream
# ===========================================================
install -d -o www-data -g www-data -m 700 /var/cache/nginx/micro
cat >/etc/nginx/conf.d/20-proxy.conf <<'EOF'
# สร้างโดย 10-reverse-proxy.sh — ค่าระดับ http ของ Nginx หน้าบ้าน

# ---------- rate limit (นับต่อ IP จริงของผู้ใช้) ----------
# ทั่วไป 10 req/s: block editor เรียก request ถี่ และทีมที่ใช้เน็ตมหาลัยแชร์ IP เดียวกัน
limit_req_zone  $binary_remote_addr zone=perip:10m rate=10r/s;
# หน้า login: 10 ครั้ง/นาที (กันเดารหัส — ชั้นเดียวกับ fail2ban + Limit Login Attempts)
limit_req_zone  $binary_remote_addr zone=login:10m rate=10r/m;
limit_conn_zone $binary_remote_addr zone=conn:10m;
limit_req_status  429;
limit_conn_status 429;

# ---------- micro-cache ----------
# cache หน้าเว็บสั้น ๆ (10 วินาที): ถ้ามีคนเข้าพร้อมกันมาก PHP ถูกเรียกแค่ครั้งเดียวต่อ 10 วินาที
proxy_cache_path /var/cache/nginx/micro levels=1:2 keys_zone=micro:10m max_size=256m inactive=10m use_temp_path=off;

# ไม่ cache คนที่ login / ใส่รหัสหน้า / เคยคอมเมนต์ (จะเห็นหน้าส่วนตัวของคนอื่น!)
map $http_cookie $wp_private_cookie {
    default                   0;
    ~*wordpress_logged_in_    1;
    ~*wp-postpass_            1;
    ~*comment_author_         1;
}

upstream wp_origin { server 127.0.0.1:8080; keepalive 16; }
upstream logwatch_dashboard { server 127.0.0.1:8081; keepalive 4; }
EOF

cat >/etc/nginx/snippets/proxy-params.conf <<'EOF'
# สร้างโดย 10-reverse-proxy.sh — header ที่ส่งต่อให้ upstream
# ถ้าไม่ส่ง X-Forwarded-For origin จะเห็นทุกคนเป็น 127.0.0.1 → log ไร้ประโยชน์, Limit Login แบนทุกคนพร้อมกัน
proxy_http_version 1.1;
proxy_set_header Connection        "";
proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host  $host;
proxy_read_timeout 120s;
proxy_buffer_size  16k;
proxy_buffers      16 16k;
EOF

# ===========================================================
#  2) origin: WordPress ฟัง 127.0.0.1:8080 (http ภายในเครื่อง)
# ===========================================================
cat >"$ORIGIN" <<EOF
# ===== WordPress origin — สร้างโดย 10-reverse-proxy.sh =====
# รับจาก Nginx หน้าบ้านเท่านั้น (127.0.0.1) — ไม่มี TLS เพราะไม่ออกนอกเครื่อง
server {
    listen 127.0.0.1:8080;
    server_name ${DOMAIN} ${EXTRA_DOMAINS};

    root ${WP_ROOT};
    index index.php index.html;
    client_max_body_size 32m;          # ตรงกับ upload_max_filesize ของ PHP (ค่า default ของ nginx คือ 1m)

    # IP จริงของผู้ใช้จาก header ที่หน้าบ้านส่งมา (เชื่อเฉพาะ 127.0.0.1)
    set_real_ip_from 127.0.0.1;
    real_ip_header   X-Forwarded-For;
    real_ip_recursive on;

    # log หลักอยู่ที่หน้าบ้าน (fail2ban/logwatch อ่านที่นั่น) — origin แยกไฟล์ไว้ debug
    access_log /var/log/nginx/origin-access.log timed;

    include snippets/wordpress-common.conf;
}
EOF
ln -sfn "$ORIGIN" /etc/nginx/sites-enabled/wp-origin
log "เปิด origin ที่ 127.0.0.1:8080 (หน้าบ้านยังเป็นของเดิม)"
reload_or_die || { rm -f /etc/nginx/sites-enabled/wp-origin /etc/nginx/conf.d/20-proxy.conf; die "origin config ผิด — ถอนออกแล้ว เว็บยังเหมือนเดิม"; }

code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $DOMAIN" -H 'X-Forwarded-Proto: https' http://127.0.0.1:8080/)
[[ $code == 200 ]] || die "origin ตอบ $code (ต้องได้ 200) — หน้าบ้านยังไม่ถูกแตะ ตรวจ /var/log/nginx/error.log"
ok "origin ตอบ 200"

# ===========================================================
#  3) dashboard password (ไฟล์ว่าง = ทุกคนได้ 401 จนกว่าจะเพิ่ม user)
# ===========================================================
if [[ ! -f $HTPASSWD ]]; then
  install -m 640 -o root -g www-data /dev/null "$HTPASSWD"
  warn "ยังไม่มี user ของ dashboard — เพิ่มเองด้วย: sudo htpasswd $HTPASSWD <ชื่อ>"
fi

# ===========================================================
#  4) หน้าบ้าน: แทนที่ server 443 เดิม (สลับแบบ atomic ด้วย reload)
# ===========================================================
cat >"$FRONT" <<EOF
# ===== Nginx หน้าบ้าน (reverse proxy) — ${DOMAIN} =====
# สร้างโดย 10-reverse-proxy.sh (ของเดิมจากขั้น 05 สำรองที่ ${BK})

# ---------- port 80: redirect ไป https ----------
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} ${EXTRA_DOMAINS};
    return 301 https://\$host\$request_uri;
}

# ---------- port 443 ----------
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     ${SSL_DIR}/fullchain.pem;
    ssl_certificate_key ${SSL_DIR}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    # add_header ระดับ server เท่านั้น (ถ้าใส่ใน location ค่าระดับ server จะไม่ถูกส่ง)
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Cache-Status \$upstream_cache_status always;   # HIT / MISS / BYPASS — ใช้พิสูจน์ว่า cache ทำงาน

    client_max_body_size 32m;
    limit_conn conn 50;

    # ---------- เงื่อนไขที่ห้าม cache ----------
    set \$skip_cache \$wp_private_cookie;
    if (\$request_method !~ ^(GET|HEAD)\$)  { set \$skip_cache 1; }
    if (\$query_string != "")               { set \$skip_cache 1; }
    if (\$request_uri ~* "^/(wp-admin|wp-login\.php|wp-json|xmlrpc\.php|wp-cron\.php|feed|security-dashboard)") { set \$skip_cache 1; }

    # ---------- หน้า login: rate limit เข้ม ----------
    location = /wp-login.php {
        limit_req zone=login burst=5 nodelay;
        proxy_pass http://wp_origin;
        include snippets/proxy-params.conf;
    }

    # ---------- Security Dashboard (Stage 2) ----------
    location = /security-dashboard { return 301 /security-dashboard/; }
    location ^~ /security-dashboard/ {
        auth_basic "Security Dashboard";
        auth_basic_user_file ${HTPASSWD};
        limit_req zone=perip burst=20 nodelay;
        proxy_pass http://logwatch_dashboard/;      # ตัด /security-dashboard/ ออกก่อนส่งต่อ
        include snippets/proxy-params.conf;
    }

    # ---------- ทุกอย่างที่เหลือ → WordPress ----------
    location / {
        limit_req zone=perip burst=100 nodelay;

        proxy_cache micro;
        proxy_cache_key "\$scheme\$host\$request_uri";
        proxy_cache_valid 200 301 302 10s;
        proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
        proxy_cache_background_update on;
        proxy_cache_lock on;                # request พร้อมกันหลายตัว → ไปหา origin แค่ตัวเดียว
        proxy_cache_bypass \$skip_cache;
        proxy_no_cache     \$skip_cache;

        proxy_pass http://wp_origin;
        include snippets/proxy-params.conf;
    }
}
EOF
log "สลับ 443 → reverse proxy"
if ! reload_or_die; then
  cp -a "$BK/$DOMAIN" "$FRONT"; systemctl reload nginx
  die "หน้าบ้าน config ผิด — คืนของเดิมแล้ว"
fi

# ===========================================================
#  5) ทดสอบ
# ===========================================================
R="--resolve $DOMAIN:443:127.0.0.1"
echo
for p in / /wp-login.php /wp-admin/ /wp-json/ /xmlrpc.php /security-dashboard/; do
  printf '    %-22s %s\n' "$p" "$(curl -s -o /dev/null -w '%{http_code}' $R "https://$DOMAIN$p")"
done
echo "    micro-cache (หน้าแรก 3 ครั้ง):"
for i in 1 2 3; do
  printf '      %s\n' "$(curl -s -o /dev/null -D - $R -H 'Accept: text/html' "https://$DOMAIN/" | grep -i '^x-cache-status' | tr -d '\r')"
done
cat <<EOF

  ย้อนกลับ:  sudo $0 --rollback
  เพิ่ม user dashboard:  sudo htpasswd $HTPASSWD <ชื่อ>   แล้วเปิด https://$DOMAIN/security-dashboard/
EOF
