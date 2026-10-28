#!/usr/bin/env bash
# ===========================================================
#  00 — สร้าง user ธรรมดา + ให้สิทธิ sudo + วาง public key
#  รันด้วย root (ตอนนี้ยังอนุญาต root login อยู่)
#      sudo ./00b-create-admin-user.sh
# ===========================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_root
load_config
require_vars ADMIN_USER

# ----- ตรวจว่ามี public key ให้วางจริง -----
mapfile -t KEYS < <(printf '%s\n' "${SSH_PUBLIC_KEYS:-}" | grep -E '^(ssh-(ed25519|rsa)|ecdsa-)' || true)
(( ${#KEYS[@]} > 0 )) || die "ยังไม่ได้ใส่ public key ใน SSH_PUBLIC_KEYS ของ config.env
      ดูวิธีสร้าง key ได้ที่ client/keygen-windows.md"
log "พบ public key ${#KEYS[@]} ดอก"

# ----- สร้าง user -----
if id "$ADMIN_USER" &>/dev/null; then
  log "มี user '$ADMIN_USER' อยู่แล้ว ข้ามการสร้าง"
else
  log "สร้าง user '$ADMIN_USER'"
  adduser --disabled-password --gecos "" "$ADMIN_USER"
  warn "ยังไม่ได้ตั้งรหัสผ่านให้ '$ADMIN_USER'"
  warn "แต่ sudo ต้องใช้รหัสผ่าน จึงต้องตั้งตอนนี้:"
  passwd "$ADMIN_USER"
fi

# ----- มอบสิทธิ sudo -----
# ตามที่เรียน: root มอบสิทธิ sudo ให้ user ธรรมดา เพื่อรันคำสั่งในฐานะ root ได้
usermod -aG sudo "$ADMIN_USER"
ok "เพิ่ม '$ADMIN_USER' เข้ากลุ่ม sudo แล้ว"

# ----- วาง public key -----
HOME_DIR=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
AUTH_KEYS="$HOME_DIR/.ssh/authorized_keys"

install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$HOME_DIR/.ssh"
backup_file "$AUTH_KEYS"
touch "$AUTH_KEYS"

for k in "${KEYS[@]}"; do
  # ใช้ field ที่ 2 (ตัว key จริง) เทียบ กันใส่ซ้ำเวลารันสคริปต์หลายรอบ
  keybody=$(awk '{print $2}' <<<"$k")
  if grep -qF "$keybody" "$AUTH_KEYS" 2>/dev/null; then
    log "key ของ '$(awk '{print $3}' <<<"$k")' มีอยู่แล้ว ข้าม"
  else
    printf '%s\n' "$k" >>"$AUTH_KEYS"
    ok "เพิ่ม key: $(awk '{print $3}' <<<"$k")"
  fi
done

chown "$ADMIN_USER:$ADMIN_USER" "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"      # rw- --- ---  ssh จะไม่ยอมรับถ้าเปิดกว้างกว่านี้

# ----- สรุป -----
echo
ok "เตรียม user เรียบร้อย"
cat <<EOF

${_C_YELLOW}===================  ต้องทดสอบก่อนไปขั้นถัดไป  ===================${_C_RESET}
เปิด terminal ${_C_YELLOW}หน้าต่างใหม่${_C_RESET} (อย่าปิดหน้าต่างนี้!) แล้วลอง:

    ssh -i <private-key> ${ADMIN_USER}@$(hostname -I | awk '{print $1}')

ถ้าเข้าได้แล้วลองรัน:  sudo whoami      → ต้องได้คำว่า root

${_C_RED}ถ้ายังเข้าไม่ได้ ห้ามรัน 01-harden-ssh.sh${_C_RESET} เพราะจะล็อกตัวเองออกจาก server
=================================================================
EOF
