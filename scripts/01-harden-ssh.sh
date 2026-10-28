#!/usr/bin/env bash
# ===========================================================
#  01 — ทำ SSH ให้ปลอดภัย (ด่านที่ 1 ของโจทย์)
#       * ปิด root login
#       * ปิด password authentication
#       * เปิด PKI (public key) เท่านั้น
#
#      sudo ./01-harden-ssh.sh            ติดตั้ง
#      sudo ./01-harden-ssh.sh --rollback ย้อนกลับ
# ===========================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_root
load_config
require_vars ADMIN_USER

# ขึ้นต้นด้วย 00- เพราะ sshd ใช้ค่าที่ "เจอก่อน" (first match wins)
# และอ่าน sshd_config.d/*.conf เรียงตามตัวอักษร ก่อนเนื้อหาส่วนที่เหลือของ sshd_config
# ถ้าตั้งเป็น 99- ไฟล์ของ Azure (50-cloudimg-settings.conf) จะชนะค่าของเรา
DROPIN=/etc/ssh/sshd_config.d/00-hardening.conf
MAIN_CONF=/etc/ssh/sshd_config
KEYS_RE='(PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PubkeyAuthentication)'

# ----- โหมดย้อนกลับ -----
if [[ ${1:-} == --rollback ]]; then
  rm -f "$DROPIN"
  systemctl reload ssh 2>/dev/null || systemctl reload sshd
  ok "ลบ $DROPIN แล้ว"
  warn "ค่าใน $MAIN_CONF ยังเป็นค่าที่ hardening ไว้ ถ้าต้องการคืนให้ copy ไฟล์สำรองล่าสุดกลับ:"
  ls -1t "$MAIN_CONF".bak.* 2>/dev/null | head -1 | sed 's/^/        /' >&2 || true
  exit 0
fi

# ===========================================================
#  ตรวจความปลอดภัยก่อนลงมือ — กันล็อกตัวเองออก
# ===========================================================
log "ตรวจสอบว่ามี public key พร้อมใช้งานก่อน"

HOME_DIR=$(getent passwd "$ADMIN_USER" | cut -d: -f6) \
  || die "ไม่พบ user '$ADMIN_USER' — รัน 00b-create-admin-user.sh ก่อน"
AUTH_KEYS="$HOME_DIR/.ssh/authorized_keys"

[[ -s $AUTH_KEYS ]] \
  || die "ไฟล์ $AUTH_KEYS ว่างหรือไม่มี — ถ้าปิด password auth ตอนนี้จะเข้า server ไม่ได้เลย"

KEY_COUNT=$(grep -cE '^(ssh-|ecdsa-)' "$AUTH_KEYS" || true)
(( KEY_COUNT > 0 )) || die "ไม่พบ public key ที่ใช้ได้ใน $AUTH_KEYS"
ok "พบ public key $KEY_COUNT ดอกของ '$ADMIN_USER'"

# user ต้องอยู่ในกลุ่ม sudo ไม่งั้นเข้าได้แต่ทำอะไรไม่ได้
id -nG "$ADMIN_USER" | grep -qw sudo \
  || die "'$ADMIN_USER' ไม่อยู่ในกลุ่ม sudo — ถ้าปิด root login จะไม่มีใครเป็น admin ได้"
ok "'$ADMIN_USER' อยู่ในกลุ่ม sudo"

echo
warn "หลังจากนี้จะ:  ปิด root login / ปิด password auth / อนุญาตเฉพาะ public key"
warn "และ ${_C_RED}เซสชันที่ login มาด้วยรหัสผ่านจะต่อใหม่ไม่ได้${_C_RESET}"
confirm "ยืนยันว่าทดสอบ ssh ด้วย key สำเร็จแล้ว?" || die "ยกเลิก — ไปทดสอบ key ให้ผ่านก่อน"

# ===========================================================
#  หาไฟล์ใน sshd_config.d/ ที่ override ค่าของเรา
#  (Azure/cloud-init มักสร้าง 50-cloudimg-settings.conf ที่มี PasswordAuthentication)
# ===========================================================
log "ตรวจไฟล์ใน /etc/ssh/sshd_config.d/ ที่อาจ override ค่า"
for f in /etc/ssh/sshd_config.d/*.conf; do
  [[ -f $f && $f != "$DROPIN" ]] || continue
  if grep -qiE "^[[:space:]]*${KEYS_RE}[[:space:]]" "$f"; then
    warn "พบค่าที่ซ้ำใน $f :"
    grep -iE "^[[:space:]]*${KEYS_RE}[[:space:]]" "$f" | sed 's/^/        /' >&2
    backup_file "$f"
    sed -i -E "s/^([[:space:]]*${KEYS_RE}[[:space:]].*)/# ปิดโดย 01-harden-ssh.sh: \1/I" "$f"
    ok "comment ค่าที่ซ้ำใน $f แล้ว"
  fi
done

# ===========================================================
#  แก้ /etc/ssh/sshd_config หลัก (ตามโจทย์) ให้ตรงกับ drop-in
#  ค่าที่มีผลจริงมาจาก 00-hardening.conf ซึ่งถูกอ่านก่อน
#  แต่ตั้งให้ตรงกันทั้งสองที่ เผื่อมีคนลบ drop-in
# ===========================================================
log "ตั้งค่าใน $MAIN_CONF"
backup_file "$MAIN_CONF"
set_main() {
  local key=$1 val=$2
  # แทนที่เฉพาะบรรทัดแรกที่เจอ (รวมบรรทัดที่ถูก comment ไว้ เช่น #PasswordAuthentication yes)
  if grep -qE "^[#[:space:]]*${key}[[:space:]]" "$MAIN_CONF"; then
    sed -i -E "0,/^[#[:space:]]*${key}[[:space:]]/ s/^[#[:space:]]*${key}[[:space:]].*/${key} ${val}/" "$MAIN_CONF"
  else
    printf '%s %s\n' "$key" "$val" >>"$MAIN_CONF"
  fi
}
set_main PermitRootLogin              no
set_main PasswordAuthentication       no
set_main KbdInteractiveAuthentication no
set_main PubkeyAuthentication         yes
grep -iE "^${KEYS_RE}[[:space:]]" "$MAIN_CONF" | sed 's/^/        /'

# ===========================================================
#  เขียนไฟล์ drop-in
#  ย้อนกลับง่าย (ลบไฟล์เดียว) และ apt upgrade ไม่ทับ
# ===========================================================
log "เขียน $DROPIN"
backup_file "$DROPIN"

cat >"$DROPIN" <<EOF
# ===== งานกลุ่มวิทยาการคอมพิวเตอร์ — SSH hardening =====
# สร้างโดย 01-harden-ssh.sh เมื่อ $(date '+%Y-%m-%d %H:%M:%S %Z')

# --- ด่านที่ 1 ข้อ 1: ห้าม login ด้วย root ---
# ผู้ดูแลต้อง login เป็น user ธรรมดาแล้วใช้ sudo ยกสิทธิ
PermitRootLogin no

# --- ด่านที่ 1 ข้อ 2: ปิด password authentication ---
# ตัดปัญหา brute-force เดารหัสผ่านทั้งหมด
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication no

# --- ด่านที่ 1 ข้อ 3: เปิด PKI (public key) ---
PubkeyAuthentication yes
AuthenticationMethods publickey

# --- จำกัดว่าใครเข้าได้บ้าง ---
AllowUsers $ADMIN_USER

# --- ตั้งค่าเสริมเพื่อลดความเสี่ยง ---
Port ${SSH_PORT:-22}
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2

# เลือกใช้เฉพาะอัลกอริทึมเข้ารหัสยุคใหม่
KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
EOF

chmod 644 "$DROPIN"

# ----- ตรวจไวยากรณ์ก่อน reload (สำคัญมาก) -----
log "ตรวจไวยากรณ์ด้วย sshd -t"
if ! sshd -t; then
  rm -f "$DROPIN"
  die "ไฟล์ตั้งค่าผิด — ลบไฟล์ออกแล้ว sshd ยังทำงานด้วยค่าเดิม"
fi
ok "ไวยากรณ์ถูกต้อง"

# ----- Ubuntu 22.10+ มี ssh.socket ที่ override Port ในไฟล์ config -----
if systemctl is-enabled ssh.socket &>/dev/null; then
  warn "ระบบนี้ใช้ ssh.socket — คำสั่ง Port ใน config จะไม่มีผล"
  warn "ถ้าต้องการเปลี่ยน port ให้แก้ที่ systemctl edit ssh.socket"
fi

log "reload sshd (เซสชันที่ต่ออยู่จะไม่ถูกตัด)"
systemctl reload ssh 2>/dev/null || systemctl reload sshd

# ===========================================================
#  ตรวจผลลัพธ์ — ใช้เป็นหลักฐานส่งอาจารย์ได้
# ===========================================================
echo
log "ค่าที่ sshd ใช้งานจริง (sshd -T):"
EFFECTIVE=$(sshd -T)
for key in permitrootlogin passwordauthentication pubkeyauthentication \
           kbdinteractiveauthentication permitemptypasswords authenticationmethods; do
  printf '    %-32s %s\n' "$key" "$(grep -i "^$key " <<<"$EFFECTIVE" | awk '{print $2}')"
done

echo
PASS=true
grep -qi '^permitrootlogin no'          <<<"$EFFECTIVE" || { warn "root login ยังไม่ถูกปิด"; PASS=false; }
grep -qi '^passwordauthentication no'   <<<"$EFFECTIVE" || { warn "password auth ยังไม่ถูกปิด"; PASS=false; }
grep -qi '^pubkeyauthentication yes'    <<<"$EFFECTIVE" || { warn "pubkey auth ยังไม่เปิด"; PASS=false; }

if $PASS; then
  ok "ผ่าน checkpoint ด่านที่ 1: ปิด root / ปิด password / เปิด PKI ครบ"
else
  die "ยังไม่ผ่าน checkpoint — ตรวจค่าข้างบน"
fi

cat <<EOF

${_C_YELLOW}ทดสอบด้วยหน้าต่างใหม่ก่อนปิดหน้าต่างนี้:${_C_RESET}

  1) เข้าด้วย key — ${_C_GREEN}ต้องสำเร็จ${_C_RESET}
       ssh -i <private-key> ${ADMIN_USER}@<ip>

  2) เข้าด้วยรหัสผ่าน — ${_C_GREEN}ต้องถูกปฏิเสธ${_C_RESET} (Permission denied (publickey))
       ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password ${ADMIN_USER}@<ip>

  3) เข้าด้วย root — ${_C_GREEN}ต้องถูกปฏิเสธ${_C_RESET}
       ssh root@<ip>

เก็บผลลัพธ์ทั้ง 3 ข้อเป็น screenshot → ใช้เป็นหลักฐาน docs/02-checkpoint-ssh.md
ถ้าพลาดและเข้าไม่ได้: ใช้ web console ของผู้ให้บริการ VPS แล้วรัน
    sudo ./01-harden-ssh.sh --rollback
EOF
