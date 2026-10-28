#!/usr/bin/env bash
# ===========================================================
#  08 — ด่านที่ 3: เว็บแนะนำหลักสูตรวิทยาการคอมพิวเตอร์
#       theme + plugin + หน้าเว็บ 8 หน้า + เมนู + ข่าวตัวอย่าง (ผ่าน WP-CLI)
#
#  รันซ้ำได้: หน้าที่มีอยู่แล้ว (เทียบจาก slug) จะถูกอัปเดตเนื้อหาจากไฟล์ใน site/
#  ⚠️ ถ้าแก้หน้าเว็บผ่าน wp-admin แล้ว อย่ารันซ้ำ ไม่งั้นเนื้อหาจะถูกทับ
#      sudo ./08-site-content.sh            ติดตั้งครั้งแรก
#      sudo ./08-site-content.sh --force    ทับเนื้อหาเดิมทั้งหมด (สำรองให้อัตโนมัติก่อนทับ)
# ===========================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_root
load_config
require_vars WP_ROOT

SITE_DIR="$PROJECT_ROOT/site"
[[ -d $SITE_DIR/pages ]] || die "ไม่พบ $SITE_DIR/pages"

# รัน wp ในฐานะ www-data (เจ้าของไฟล์เว็บ) — ห้ามรันเป็น root ไม่งั้นไฟล์ plugin จะเป็นของ root
# cd ไปที่ $WP_ROOT ก่อน: บางคำสั่ง (เช่น rewrite structure) spawn wp ตัวใหม่ใน cwd เดิม
# ซึ่งเป็น home ของ sysadmin (700) → www-data เข้าไม่ได้ → posix_spawn: Permission denied
WP() { ( cd "$WP_ROOT" && sudo -u www-data env WP_CLI_CACHE_DIR=/tmp/wp-cli-cache wp --path="$WP_ROOT" "$@" ); }

WP core is-installed || die "WordPress ยังไม่ได้ทำ setup wizard"

# ----- กันเขียนทับงานที่กลุ่มแก้ใน wp-admin -----
if [[ -n $(WP post list --post_type=page --name=home --format=ids) ]]; then
  [[ ${1:-} == --force ]] || die "มีหน้าเว็บอยู่แล้ว — รันซ้ำจะทับเนื้อหาที่กลุ่มแก้ใน wp-admin
      ถ้าตั้งใจจริงให้ใส่ --force (จะสำรองฐานข้อมูลก่อนทับ)"
  BK=/root/wp-backup-$(date +%Y%m%d-%H%M%S).sql.gz
  WP db export - | gzip >"$BK"
  warn "สำรองฐานข้อมูลไว้ที่ $BK ก่อนเขียนทับ"
fi

# ===========================================================
#  1. ตั้งค่าทั่วไป
# ===========================================================
log "ตั้งค่าทั่วไป (timezone, permalink, คำโปรย)"
WP option update timezone_string 'Asia/Bangkok' >/dev/null
WP option update date_format 'j F Y' >/dev/null
WP option update start_of_week 1 >/dev/null
WP option update blogdescription 'เรียนรู้ สร้างสรรค์ เปลี่ยนโลกด้วยโค้ด' >/dev/null
WP rewrite structure '/%postname%/' >/dev/null      # URL สวย: /curriculum/ แทน /?page_id=12
WP option update default_comment_status closed >/dev/null   # เว็บหลักสูตรไม่ต้องเปิดคอมเมนต์ (ลดสแปม)
ok "ตั้งค่าทั่วไปแล้ว"

# ===========================================================
#  2. Theme: Kadence (ฟรี, เบา, โหลดเร็ว, รองรับ block editor)
# ===========================================================
log "ติดตั้ง theme Kadence"
WP theme is-installed kadence || WP theme install kadence >/dev/null
WP theme activate kadence >/dev/null
ok "theme: $(WP theme list --status=active --field=name) $(WP theme get kadence --field=version)"

# ===========================================================
#  3. Plugin ตามโจทย์
# ===========================================================
#   cache-enabler                  ทำแคชหน้าเว็บเป็นไฟล์ HTML (ลดงาน PHP/MySQL)
#   ewww-image-optimizer           บีบอัดรูปตอนอัปโหลด (ทำบนเครื่องเรา ไม่ส่งรูปออกไปข้างนอก)
#   contact-form-7 + flamingo      ฟอร์มติดต่อ + เก็บข้อความลงฐานข้อมูล
#   limit-login-attempts-reloaded  จำกัดจำนวนครั้ง login ผิด (คู่กับ fail2ban ของด่าน 2)
PLUGINS=(cache-enabler ewww-image-optimizer contact-form-7 flamingo limit-login-attempts-reloaded)
log "ติดตั้ง plugin: ${PLUGINS[*]}"
for p in "${PLUGINS[@]}"; do
  WP plugin is-installed "$p" || WP plugin install "$p" >/dev/null
  WP plugin is-active "$p"    || WP plugin activate "$p" >/dev/null
done
WP plugin list --status=active --fields=name,version --format=table

# Cache Enabler ทำงานเฉพาะเมื่อมี WP_CACHE=true ใน wp-config (ตอนติดตั้งครั้งแรกไม่ได้ตั้ง → ไม่ cache เลย)
# หมายเหตุ: Cache Enabler cache เฉพาะ request ที่มี "Accept: text/html" (browser) — curl เฉย ๆ จะไม่ถูก cache
WP config set WP_CACHE true --raw --anchor="// ---------- ปิด debug บนเครื่องจริง ----------" --placement=before >/dev/null

# ----- ปิด XML-RPC ในตัว WordPress อีกชั้น (nginx บล็อก /xmlrpc.php อยู่แล้ว) -----
log "ติดตั้ง mu-plugin ปิด XML-RPC"
install -d -o www-data -g www-data -m 755 "$WP_ROOT/wp-content/mu-plugins"
cat >"$WP_ROOT/wp-content/mu-plugins/disable-xmlrpc.php" <<'PHP'
<?php
/**
 * Plugin Name: Disable XML-RPC
 * Description: ปิด XML-RPC และ pingback (สร้างโดย 08-site-content.sh) — nginx บล็อก /xmlrpc.php อีกชั้น
 */
add_filter( 'xmlrpc_enabled', '__return_false' );
add_filter( 'wp_headers', function ( $h ) { unset( $h['X-Pingback'] ); return $h; } );
add_filter( 'xmlrpc_methods', function ( $m ) { unset( $m['pingback.ping'], $m['pingback.extensions.getPingbacks'] ); return $m; } );
PHP
chown www-data:www-data "$WP_ROOT/wp-content/mu-plugins/disable-xmlrpc.php"
ok "ปิด XML-RPC แล้ว"

# ----- ซ่อนเลขเวอร์ชัน WordPress (คู่กับ nginx ที่ตอบ 404 ให้ readme.html / license.txt) -----
cat >"$WP_ROOT/wp-content/mu-plugins/hide-wp-version.php" <<'PHP'
<?php
/**
 * Plugin Name: Hide WordPress version
 * Description: เอาเลขเวอร์ชัน WordPress ออกจาก <meta name="generator"> และ RSS feed
 *              (คนสแกนใช้เลขเวอร์ชันเทียบหาช่องโหว่ที่รู้จัก)
 */
remove_action( 'wp_head', 'wp_generator' );
add_filter( 'the_generator', '__return_empty_string' );
PHP
chown www-data:www-data "$WP_ROOT/wp-content/mu-plugins/hide-wp-version.php"
ok "ซ่อนเลขเวอร์ชัน WordPress แล้ว"

# ----- กันการสืบรายชื่อ user — เฉพาะคนที่ไม่ได้ login -----
# (เดิมบล็อกที่ nginx แต่ nginx แยกไม่ออกว่าใคร login → block editor ของทีมเรียก /users/me ไม่ได้)
cat >"$WP_ROOT/wp-content/mu-plugins/block-user-enum.php" <<'PHP'
<?php
/**
 * Plugin Name: Block user enumeration (anonymous only)
 * Description: คนที่ไม่ได้ login จะสืบรายชื่อ user ไม่ได้ — REST /wp/v2/users, ?author=N, หน้า /author/<ชื่อ>/,
 *              ลิงก์ผู้เขียน, oEmbed และชื่อผู้เขียนที่ตรงกับชื่อ login
 *              แต่ block editor ของคนที่ login อยู่ยังเรียก /wp/v2/users/me ได้ปกติ
 */
add_filter( 'rest_endpoints', function ( $endpoints ) {
	if ( ! is_user_logged_in() ) {
		foreach ( array_keys( $endpoints ) as $route ) {
			if ( 0 === strpos( $route, '/wp/v2/users' ) ) {
				unset( $endpoints[ $route ] );
			}
		}
	}
	return $endpoints;
} );

// priority 1: ต้องทำงานก่อน redirect_canonical (priority 10)
// ไม่งั้น WordPress พา ?author=N ไปที่ /author/<ชื่อ login>/ ก่อนถึงโค้ดนี้
add_action( 'template_redirect', function () {
	if ( is_user_logged_in() ) {
		return;
	}
	if ( isset( $_GET['author'] ) ) {
		wp_safe_redirect( home_url( '/' ), 301 );
		exit;
	}
	if ( is_author() ) {
		global $wp_query;
		$wp_query->set_404();
		status_header( 404 );
		nocache_headers();
	}
}, 1 );

// ลิงก์ผู้เขียน (/author/<ชื่อ>/) ในหน้าข่าว → ชี้ไปหน้าแรกแทน
add_filter( 'author_link', function ( $link ) {
	return is_user_logged_in() ? $link : home_url( '/' );
} );

// oEmbed (/wp-json/oembed/...) ส่ง author_url ที่มีชื่อ login ออกไป
add_filter( 'oembed_response_data', function ( $data ) {
	if ( ! is_user_logged_in() ) {
		unset( $data['author_url'] );
		$data['author_name'] = get_bloginfo( 'name' );
	}
	return $data;
} );

// ชื่อผู้เขียนที่ตรงกับชื่อ login (หน้าข่าว + RSS dc:creator) → แสดงเป็นชื่อเว็บ
add_filter( 'the_author', function ( $name ) {
	global $authordata;
	if ( ! is_user_logged_in() && $authordata && $name === $authordata->user_login ) {
		return get_bloginfo( 'name' );
	}
	return $name;
} );
PHP
chown www-data:www-data "$WP_ROOT/wp-content/mu-plugins/block-user-enum.php"
ok "กันการสืบรายชื่อ user (เฉพาะคนที่ไม่ได้ login)"

# ===========================================================
#  4. ลบเนื้อหาตัวอย่างของ WordPress
# ===========================================================
for slug in hello-world; do
  id=$(WP post list --post_type=post --name="$slug" --format=ids)
  [[ -n $id ]] && WP post delete $id --force >/dev/null && log "ลบโพสต์ตัวอย่าง $slug"
done
id=$(WP post list --post_type=page --name=sample-page --format=ids)
[[ -n $id ]] && WP post delete $id --force >/dev/null && log "ลบหน้า sample-page"
for c in $(WP comment list --format=ids); do WP comment delete "$c" --force >/dev/null; done

# ===========================================================
#  5. ฟอร์มติดต่อ (Contact Form 7)
#     Azure บล็อก port 25 ขาออก → ส่งอีเมลจากเครื่องนี้ตรง ๆ ไม่ได้
#     จึงตั้ง skip_mail: on แล้วให้ Flamingo เก็บข้อความไว้ใน wp-admin → Flamingo → Inbound Messages
# ===========================================================
log "ตั้งค่าฟอร์มติดต่อ"
FORM_ID=$(WP post list --post_type=wpcf7_contact_form --format=ids | awk '{print $1}')
if [[ -z $FORM_ID ]]; then
  FORM_ID=$(WP post create --post_type=wpcf7_contact_form --post_title='แบบฟอร์มติดต่อ' --post_status=publish --porcelain)
fi
WP post update "$FORM_ID" --post_title='แบบฟอร์มติดต่อ' >/dev/null
WP post meta update "$FORM_ID" _form '<label> ชื่อ-นามสกุล
    [text* your-name autocomplete:name] </label>

<label> อีเมล
    [email* your-email autocomplete:email] </label>

<label> ฉันเป็น
    [select your-role "นักเรียน ม.ปลาย" "ผู้ปกครอง" "ครูแนะแนว" "อื่น ๆ"] </label>

<label> หัวข้อ
    [text* your-subject] </label>

<label> ข้อความ
    [textarea* your-message] </label>

[submit "ส่งข้อความ"]' >/dev/null
WP post meta update "$FORM_ID" _additional_settings 'skip_mail: on' >/dev/null
CF7_SHORTCODE="[contact-form-7 id=\"$FORM_ID\" title=\"แบบฟอร์มติดต่อ\"]"
ok "ฟอร์มติดต่อ id=$FORM_ID (ข้อความเก็บใน Flamingo)"

# ===========================================================
#  6. หน้าเว็บ 8 หน้า
# ===========================================================
# upsert <post_type> <slug> <title> <ไฟล์เนื้อหา | - (stdin)>  → พิมพ์ ID
upsert() {
  local type=$1 slug=$2 title=$3 file=$4 id
  id=$(WP post list --post_type="$type" --name="$slug" --post_status=any --format=ids </dev/null | awk '{print $1}')
  if [[ $file == - ]]; then file=/dev/stdin; fi
  if [[ -n $id ]]; then
    WP post update "$id" - --post_title="$title" --post_status=publish <"$file" >/dev/null
  else
    id=$(WP post create - --post_type="$type" --post_name="$slug" --post_title="$title" \
           --post_status=publish --porcelain <"$file")
  fi
  printf '%s' "$id"
}

# Kadence: ตั้ง layout รายหน้า (เต็มจอ ไม่มีกล่อง) — หน้าแรกซ่อนชื่อหน้าด้วยเพราะมี hero อยู่แล้ว
kadence_layout() {
  local id=$1 hide_title=${2:-no}
  # หน้าแรก: fullwidth (hero กว้างเต็มจอ มี padding ในตัว) · หน้าอื่น: normal (มีกรอบกลางจอ ไม่ชิดขอบ)
  WP post meta update "$id" _kad_post_layout "$([[ $hide_title == yes ]] && echo fullwidth || echo normal)" >/dev/null
  WP post meta update "$id" _kad_post_content_style unboxed >/dev/null
  if [[ $hide_title == yes ]]; then
    WP post meta update "$id" _kad_post_title hide >/dev/null
    WP post meta update "$id" _kad_post_vertical_padding hide >/dev/null
  fi
}

log "สร้าง/อัปเดตหน้าเว็บ"
P=$SITE_DIR/pages
declare -A ID
ID[home]=$(upsert page home 'หน้าแรก' "$P/home.html");                       kadence_layout "${ID[home]}" yes
ID[about]=$(upsert page about 'เกี่ยวกับหลักสูตร' "$P/about.html")
ID[curriculum]=$(upsert page curriculum 'วิชาที่เรียน / แผนการเรียน' "$P/curriculum.html")
ID[careers]=$(upsert page careers 'อาชีพหลังจบ' "$P/careers.html")
ID[showcase]=$(upsert page showcase 'ผลงานและกิจกรรมนักศึกษา' "$P/showcase.html")
ID[news]=$(upsert page news 'ข่าวสาร' /dev/null)
ID[admission]=$(upsert page admission 'การรับสมัคร' "$P/admission.html")
ID[contact]=$(sed "s|\[\[CF7_SHORTCODE\]\]|$CF7_SHORTCODE|" "$P/contact.html" | upsert page contact 'ติดต่อเรา' -)
for k in about curriculum careers showcase admission contact; do kadence_layout "${ID[$k]}"; done

# หน้าแรกเป็นหน้า static + หน้า "ข่าวสาร" แสดงรายการโพสต์
WP option update show_on_front page >/dev/null
WP option update page_on_front "${ID[home]}" >/dev/null
WP option update page_for_posts "${ID[news]}" >/dev/null
ok "สร้างหน้าเว็บครบ 8 หน้า"

# ===========================================================
#  7. ข่าวตัวอย่าง
# ===========================================================
log "สร้างข่าวตัวอย่าง"
WP term get category news-updates --by=slug &>/dev/null \
  || WP term create category 'ข่าวสาร' --slug=news-updates >/dev/null
declare -A NEWS=(
  [01-website-launch]='เปิดตัวเว็บไซต์หลักสูตร สร้างและดูแลโดยนักศึกษา'
  [02-open-house]='【ตัวอย่าง】 เชิญร่วมกิจกรรม Open House สำหรับน้อง ม.ปลาย'
  [03-tcas-portfolio]='เคล็ดลับทำ Portfolio TCAS รอบ 1 สายคอมพิวเตอร์'
)
for f in $(printf '%s\n' "${!NEWS[@]}" | sort -r); do   # สร้างจากเก่าไปใหม่ → 01 อยู่บนสุด
  pid=$(upsert post "$f" "${NEWS[$f]}" "$SITE_DIR/posts/$f.html")
  WP post term set "$pid" category news-updates --by=slug >/dev/null
done
ok "ข่าวตัวอย่าง ${#NEWS[@]} เรื่อง"

# ===========================================================
#  8. เมนูหลัก
# ===========================================================
log "สร้างเมนูหลัก"
MENU='เมนูหลัก'
# เก็บผลลงตัวแปรก่อนแล้วค่อย grep — ห้ามใช้ "wp ... | grep -q" เพราะ grep -q ปิด pipe ทันทีที่เจอ
# → wp โดน SIGPIPE → pipefail ทำให้เงื่อนไขเป็น false (เคยทำให้เมนูไม่ถูกผูกตำแหน่ง primary)
menus=$(WP menu list --fields=name --format=csv)
grep -qx "$MENU" <<<"$menus" && WP menu delete "$MENU" >/dev/null
WP menu create "$MENU" >/dev/null
for k in home about curriculum careers showcase news admission contact; do
  WP menu item add-post "$MENU" "${ID[$k]}" >/dev/null
done
locations=$(WP menu location list --format=csv)
for loc in primary mobile; do
  grep -q "^$loc," <<<"$locations" && WP menu location assign "$MENU" "$loc" >/dev/null
done
ok "เมนู: $(WP menu item list "$MENU" --fields=title --format=csv | tail -n +2 | paste -sd'|' | sed 's/|/ · /g')"

# ===========================================================
#  9. ล้างแคช + ตรวจทุกหน้า
# ===========================================================
WP cache flush >/dev/null
WP cache-enabler clear >/dev/null 2>&1 || true

DOMAIN=$(full_domain)
echo
log "ตรวจทุกหน้า:"
for k in home about curriculum careers showcase news admission contact; do
  url=$(WP post list --post_type=page --post__in="${ID[$k]}" --field=url)
  # --resolve → ต่อเข้า 127.0.0.1 ตรง ๆ (ถ้าวิ่งออก public IP ของตัวเอง firewall จะทิ้ง เพราะไม่ใช่ IP ไทย)
  printf '    %-4s %s\n' "$(curl -s -o /dev/null -w '%{http_code}' --resolve "$DOMAIN:443:127.0.0.1" "$url")" "$url"
done

echo
if [[ $(WP option get blog_public) == 0 ]]; then
  warn "ยังปิดกั้น search engine อยู่ (ตั้งใจไว้ระหว่างพัฒนา) — ก่อนส่งงานเปิดที่ ตั้งค่า → การอ่าน"
fi
cat <<EOF

${_C_YELLOW}ต่อไปให้กลุ่มทำใน wp-admin:${_C_RESET}
  1) ค้นหา "【แก้ไข" ในทุกหน้า แล้วแทนด้วยข้อมูลจริงของหลักสูตร
  2) ใส่โลโก้: ปรับแต่ง → Header → Logo
  3) อัปโหลดรูปผลงาน/กิจกรรมจริง (EWWW จะบีบอัดให้อัตโนมัติ)
  4) ข้อความจากฟอร์มติดต่อ: Flamingo → Inbound Messages
EOF
