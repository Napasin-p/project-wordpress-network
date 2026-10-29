#!/usr/bin/env bash
# ===========================================================
#  13 — ชื่อบนแท็บเบราว์เซอร์ + ไอคอนเว็บ (Site Icon)
#
#  - ชื่อเว็บ "ComSci Burapha" และลบคำโปรย → แท็บหน้าแรกขึ้นแค่ "ComSci Burapha"
#  - ไอคอนแท็บ = ตรามหาวิทยาลัยบูรพา สีทอง (site/assets/buu-seal-512.png, 512×512 จาก informatics.buu.ac.th)
#  ไม่แตะเนื้อหาหน้าเว็บ · รันซ้ำได้ (ถ้ามีรูปโลโก้ใน Media อยู่แล้วจะใช้ตัวเดิม)
#      sudo ./13-site-identity.sh
# ===========================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_root
load_config
require_vars WP_ROOT

LOGO="$PROJECT_ROOT/site/assets/buu-seal-512.png"
[[ -f $LOGO ]] || die "ไม่พบ $LOGO"

WP() { ( cd "$WP_ROOT" && sudo -u www-data env WP_CLI_CACHE_DIR=/tmp/wp-cli-cache wp --path="$WP_ROOT" "$@" ); }
WP core is-installed || die "WordPress ยังไม่ได้ทำ setup wizard"

log "ชื่อเว็บ + คำโปรย"
WP option update blogname 'ComSci Burapha' >/dev/null
WP option update blogdescription '' >/dev/null
ok "blogname='$(WP option get blogname)' · blogdescription='$(WP option get blogdescription)'"

log "ไอคอนเว็บ (Site Icon)"
ID=$(WP post list --post_type=attachment --title='ตรามหาวิทยาลัยบูรพา' --orderby=ID --order=ASC --format=ids | awk '{print $1}')
if [[ -z $ID ]]; then
  # www-data อ่านไฟล์ในโฟลเดอร์โปรเจกต์ (700) ไม่ได้ → คัดลอกไปที่ /tmp ก่อน
  TMP=$(mktemp -d); cp "$LOGO" "$TMP/"; chmod 755 "$TMP"; chmod 644 "$TMP/buu-seal-512.png"
  ID=$(WP media import "$TMP/buu-seal-512.png" --title='ตรามหาวิทยาลัยบูรพา' --porcelain)
  rm -rf "$TMP"
fi
WP option update site_icon "$ID" >/dev/null
ok "site_icon = attachment $ID"

WP cache-enabler clear >/dev/null 2>&1 || true
ok "ล้างแคชหน้าเว็บแล้ว"
