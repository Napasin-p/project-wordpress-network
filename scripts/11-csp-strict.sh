#!/usr/bin/env bash
# ===========================================================
#  11 — Content-Security-Policy แบบเข้ม (hash ของสคริปต์ inline)
#
#  ปัญหาเดิม: CSP ต้องอนุญาต 'unsafe-inline' เพราะหน้าเว็บมีสคริปต์ฝังในหน้าเยอะ
#            → ถ้าคนร้ายฝังสคริปต์ได้ CSP ก็ไม่ห้าม
#  วิธีนี้:   คำนวณ sha256 ของสคริปต์ inline ทุกตัวในหน้าสาธารณะ แล้วอนุญาตเฉพาะตัวที่ hash ตรง
#            สคริปต์ที่ถูกฝังเพิ่มจะ hash ไม่ตรง → เบราว์เซอร์ไม่รัน (ไม่ต้องแก้หน้าเว็บของทีม)
#            เบราว์เซอร์ที่รองรับ hash จะไม่สน 'unsafe-inline' (ใส่ไว้ให้เบราว์เซอร์เก่ามาก ๆ เท่านั้น)
#
#  ขอบเขต:   หน้าสาธารณะ (คนไม่ได้ login) = นโยบาย hash
#            คนที่ login / wp-admin / wp-login = นโยบายเดิมแบบ Report-Only (กัน block editor พัง)
#            /security-dashboard/ = ใช้ CSP ของ container เอง
#
#      sudo ./11-csp-strict.sh             ติดตั้ง + โหมดทดสอบ (บังคับนโยบายเดิม + รายงานนโยบาย hash)
#      sudo ./11-csp-strict.sh --enforce   บังคับใช้นโยบาย hash (ทดสอบในเบราว์เซอร์ให้ไม่มีแจ้งเตือนก่อน)
#
#  ⚠️ แก้สคริปต์ในหน้าเว็บเมื่อไหร่ ต้องรัน: sudo csp-update-hashes.sh --enforce
#     ไม่งั้นสคริปต์ที่แก้จะถูกบล็อก · ห้ามตั้ง cron ให้รันเอง (จะรับรองสคริปต์ที่ถูกฝังให้อัตโนมัติ)
#  ⚠️ ถ้ารัน 10-reverse-proxy.sh ใหม่ ต้องรันสคริปต์นี้ซ้ำ (10 เขียน vhost หน้าบ้านทับ)
# ===========================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_root
load_config

DOMAIN=$(full_domain)
GEN=/usr/local/sbin/csp-update-hashes.sh
FRONT=/etc/nginx/sites-available/$DOMAIN

[[ -f $FRONT ]] || die "ไม่พบ $FRONT — รัน 10-reverse-proxy.sh ก่อน"

# ----- 1. ตัวสร้างนโยบาย (รันซ้ำได้ทุกครั้งที่หน้าเว็บเปลี่ยน) -----
log "เขียน $GEN"
cat >"$GEN" <<EOF
#!/usr/bin/env bash
# สร้าง CSP แบบ hash ของสคริปต์ inline ในหน้าสาธารณะ — สร้างโดย 11-csp-strict.sh
#   csp-update-hashes.sh            โหมดทดสอบ: บังคับนโยบายเดิม + รายงานนโยบาย hash (Report-Only)
#   csp-update-hashes.sh --enforce  บังคับใช้นโยบาย hash
# ⚠️ รันใหม่ทุกครั้งที่แก้สคริปต์ในหน้าเว็บ · ห้ามตั้ง cron (จะรับรองสคริปต์ที่ถูกฝังให้อัตโนมัติ)
set -euo pipefail
MODE=report; [[ \${1:-} == --enforce ]] && MODE=enforce
DOMAIN=${DOMAIN}; WP=${WP_ROOT}; OUT=/etc/nginx/conf.d/21-csp.conf
work=\$(mktemp -d); trap 'rm -rf "\$work"' EXIT

# URL สาธารณะ: หน้าแรก + หน้า/โพสต์ที่เผยแพร่ + หมวดหมู่ + ค้นหา + 404
{ echo "https://\$DOMAIN/"
  ( cd "\$WP" && sudo -u www-data wp post list --post_type=page,post --post_status=publish --field=url 2>/dev/null )
  ( cd "\$WP" && sudo -u www-data wp term list category --field=url 2>/dev/null ) || true
  echo "https://\$DOMAIN/?s=test"
  echo "https://\$DOMAIN/csp-check-404/"
} | sort -u > "\$work/urls"

# ดึงทั้งหน้าที่อยู่ใน cache และหน้าสด (มี query string → ข้าม cache) เอา hash ของทั้งสองแบบ
i=0; bad=0
while read -r u; do
  for v in "\$u" "\$u\$([[ \$u == *\\?* ]] && echo '&' || echo '?')cspgen=1"; do
    i=\$((i+1))
    code=\$(curl -s --max-time 20 --resolve "\$DOMAIN:443:127.0.0.1" -H 'Accept: text/html' -o "\$work/p\$i.html" -w '%{http_code}' "\$v" || echo 000)
    [[ \$code == 200 || ( \$code == 404 && \$v == *csp-check-404* ) ]] || { echo "ดึง \$v ไม่ได้ (HTTP \$code)" >&2; bad=1; }
  done
done < "\$work/urls"
(( bad == 0 )) || { echo "ยกเลิก — ดึงบางหน้าไม่ได้ ไม่แก้นโยบาย" >&2; exit 1; }

HASHES=\$(python3 - "\$work" <<'PY'
import base64, glob, hashlib, re, sys
hashes, handlers, jsurl = set(), 0, 0
for f in glob.glob(sys.argv[1] + "/p*.html"):
    b = open(f, "rb").read()
    for attrs, body in re.findall(rb"<script\b([^>]*)>(.*?)</script\s*>", b, re.S | re.I):
        if re.search(rb"\bsrc\s*=", attrs, re.I):
            continue
        t = re.search(rb"\btype\s*=\s*[\"']?([^\"'\s>]+)", attrs, re.I)
        # speculationrules (WordPress 6.8+ ใช้ prefetch หน้าถัดไป) — CSP นับเป็นสคริปต์ ต้องมี hash ด้วย
        if t and t.group(1).lower() not in (b"text/javascript", b"application/javascript", b"module", b"speculationrules"):
            continue            # JSON / ld+json ไม่ถูกรันเป็นสคริปต์
        hashes.add("'sha256-" + base64.b64encode(hashlib.sha256(body).digest()).decode() + "'")
    handlers += len(re.findall(rb"<[a-z][^>]*\son[a-z]+\s*=", b, re.I))
    jsurl += len(re.findall(rb"(?:href|action|src)\s*=\s*[\"']\s*javascript:", b, re.I))
if handlers or jsurl:
    print(f"เตือน: พบ onclick=… {handlers} จุด / javascript: URL {jsurl} จุด — hash ใช้กับสองแบบนี้ไม่ได้", file=sys.stderr)
print(" ".join(sorted(hashes)))
PY
)
n=\$(wc -w <<< "\$HASHES")
(( n > 0 )) || { echo "ไม่พบสคริปต์ inline — ยกเลิก" >&2; exit 1; }

REST="worker-src 'self' blob:; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' data: https://fonts.gstatic.com; img-src 'self' data: https:; frame-src 'self' https://www.youtube.com https://www.youtube-nocookie.com https://www.google.com https://docs.google.com; connect-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'self'"
LOOSE="default-src 'self'; script-src 'self' 'unsafe-inline'; \$REST"
STRICT="default-src 'self'; script-src 'self' 'unsafe-inline' \$HASHES; \$REST"
if [[ \$MODE == enforce ]]; then PUB_ENF=\$STRICT; PUB_RO=""; else PUB_ENF=\$LOOSE; PUB_RO=\$STRICT; fi

[[ -f \$OUT ]] && cp -a "\$OUT" "\$work/old.conf"
cat > "\$OUT" <<CONF
# สร้างโดย csp-update-hashes.sh (\$MODE) — อย่าแก้มือ · สคริปต์ inline ที่อนุญาต: \$n ตัว
# key = "\\\$wp_private_cookie|\\\$uri" (1 = login อยู่) · ค่าว่าง = ไม่ส่ง header
map "\\\$wp_private_cookie|\\\$uri" \\\$csp_enforce {
    default "\$PUB_ENF";
    "~^1\\\\|" "";
    "~\\\\|/(wp-admin|wp-login\\\\.php|security-dashboard)" "";
}
map "\\\$wp_private_cookie|\\\$uri" \\\$csp_report {
    default "\$PUB_RO";
    "~\\\\|/security-dashboard" "";
    "~^1\\\\|" "\$LOOSE";
    "~\\\\|/(wp-admin|wp-login\\\\.php)" "\$LOOSE";
}
CONF
if nginx -t 2>/dev/null; then
  systemctl reload nginx
  find /var/cache/nginx/micro -type f -delete 2>/dev/null || true
  logger -t csp "อัปเดต CSP (\$MODE) — อนุญาตสคริปต์ inline \$n ตัว"
  echo "CSP \$MODE: อนุญาตสคริปต์ inline \$n ตัว จาก \$(wc -l < "\$work/urls") หน้า"
else
  [[ -f \$work/old.conf ]] && cp -a "\$work/old.conf" "\$OUT" || rm -f "\$OUT"
  echo "nginx -t ไม่ผ่าน — คืนค่าเดิมแล้ว" >&2; exit 1
fi
EOF
chmod 750 "$GEN"
ok "ติดตั้ง $GEN"

# ----- 2. สร้างนโยบายครั้งแรก (โหมดทดสอบ) — ต้องมี map ก่อน vhost จะอ้างตัวแปรได้ -----
log "สร้าง /etc/nginx/conf.d/21-csp.conf (โหมดทดสอบ)"
"$GEN"

# ----- 3. ให้ vhost หน้าบ้านใช้ตัวแปรจาก map แทน header แบบตายตัว -----
if ! grep -q 'csp_enforce' "$FRONT"; then
  backup_file "$FRONT"
  sed -i '/# CSP แบบ Report-Only/d; /add_header Content-Security-Policy-Report-Only/d' "$FRONT"
  sed -i '/add_header Permissions-Policy/a\
    # CSP: ค่ามาจาก conf.d/21-csp.conf (สร้างโดย csp-update-hashes.sh) — ค่าว่าง = ไม่ส่ง header\
    add_header Content-Security-Policy $csp_enforce always;\
    add_header Content-Security-Policy-Report-Only $csp_report always;' "$FRONT"
  nginx -t || die "nginx -t ไม่ผ่าน — กู้คืนจากไฟล์สำรองของ $FRONT"
  systemctl reload nginx
  ok "vhost หน้าบ้านใช้ CSP จาก map แล้ว"
fi

if [[ ${1:-} == --enforce ]]; then
  "$GEN" --enforce
  ok "บังคับใช้ CSP แบบ hash แล้ว"
else
  ok "โหมดทดสอบ: เปิดเว็บทุกหน้าแล้วดู console — ไม่มีแจ้งเตือนแล้วค่อยรัน: sudo $0 --enforce"
fi
