#!/usr/bin/env bash
# ===========================================================
#  00a — อัปเดตระบบ + สร้าง swap 2 GB
#  VM ใช้ B2als_v2 (RAM 4 GB) แต่ทำ swap ตามโจทย์ไว้กันกรณี RAM เต็ม/ลดขนาดเครื่องทีหลัง
#  MySQL 8 + PHP-FPM อาจโดน OOM killer ถ้าไม่มี swap
#      sudo ./00a-update-swap.sh
# ===========================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_root

SWAPFILE=/swapfile
SWAP_SIZE=${SWAP_SIZE:-2G}

# ===========================================================
#  1. อัปเดตระบบ
# ===========================================================
log "อัปเดตรายชื่อ package และอัปเกรดทั้งระบบ"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get -y -qq -o Dpkg::Options::=--force-confold full-upgrade
apt_install unattended-upgrades curl ca-certificates
ok "อัปเดตระบบแล้ว"

if [[ -f /var/run/reboot-required ]]; then
  warn "kernel ถูกอัปเดต — ควร reboot ก่อนไปขั้นถัดไป: sudo reboot"
fi

# ===========================================================
#  2. swap file
# ===========================================================
if swapon --show=NAME --noheadings | grep -qx "$SWAPFILE"; then
  log "มี swap ที่ $SWAPFILE อยู่แล้ว ข้าม"
else
  log "สร้าง swap file ขนาด $SWAP_SIZE ที่ $SWAPFILE"
  fallocate -l "$SWAP_SIZE" "$SWAPFILE"
  chmod 600 "$SWAPFILE"      # swap มีข้อมูลจาก RAM (อาจมีรหัสผ่าน) ห้ามคนอื่นอ่าน
  mkswap "$SWAPFILE" >/dev/null
  swapon "$SWAPFILE"
  ok "เปิดใช้ swap แล้ว"
fi

# ให้ swap เปิดเองหลัง reboot
grep -q "^$SWAPFILE " /etc/fstab || echo "$SWAPFILE none swap sw 0 0" >>/etc/fstab

# swappiness ต่ำ = ใช้ RAM ก่อน ค่อยไป swap เมื่อจำเป็น (disk ช้ากว่า RAM มาก)
cat >/etc/sysctl.d/99-swap.conf <<'EOF'
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
sysctl -q -p /etc/sysctl.d/99-swap.conf

# ----- Azure: ระวัง waagent สร้าง swap บน resource disk ซ้ำ -----
if [[ -f /etc/waagent.conf ]] && grep -q '^ResourceDisk.EnableSwap=y' /etc/waagent.conf; then
  warn "waagent ตั้ง EnableSwap=y ไว้ — จะมี swap 2 ก้อน (ไม่อันตราย แต่ซ้ำซ้อน)"
fi

# ===========================================================
#  สรุป
# ===========================================================
echo
free -h
echo
swapon --show
echo
log "ขั้นถัดไป: sudo ./00b-create-admin-user.sh"
