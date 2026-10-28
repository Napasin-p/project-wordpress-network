#!/usr/bin/env bash
# ฟังก์ชันร่วมที่ทุกสคริปต์ source เข้าไปใช้
# ใช้: source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

set -euo pipefail

# ---------- สีและข้อความ ----------
if [[ -t 1 ]]; then
  _C_RESET=$'\033[0m'; _C_BLUE=$'\033[1;34m'; _C_GREEN=$'\033[1;32m'
  _C_YELLOW=$'\033[1;33m'; _C_RED=$'\033[1;31m'
else
  _C_RESET=''; _C_BLUE=''; _C_GREEN=''; _C_YELLOW=''; _C_RED=''
fi

log()  { printf '%s[ขั้นตอน]%s %s\n' "$_C_BLUE"   "$_C_RESET" "$*"; }
ok()   { printf '%s[ สำเร็จ ]%s %s\n' "$_C_GREEN"  "$_C_RESET" "$*"; }
warn() { printf '%s[ ระวัง ]%s %s\n' "$_C_YELLOW" "$_C_RESET" "$*" >&2; }
die()  { printf '%s[ ล้มเหลว ]%s %s\n' "$_C_RED" "$_C_RESET" "$*" >&2; exit 1; }

# ---------- ตรวจสิทธิ ----------
require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "สคริปต์นี้ต้องรันด้วย sudo: sudo $0"
}

# ---------- ถามยืนยัน ----------
confirm() {
  local prompt="${1:-ดำเนินการต่อหรือไม่?}" reply
  read -rp "$prompt [y/N] " reply </dev/tty
  [[ ${reply,,} == y || ${reply,,} == yes ]]
}

# ---------- โหลด config.env ----------
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/config.env}"

load_config() {
  [[ -f $CONFIG_FILE ]] || die "ไม่พบ $CONFIG_FILE — คัดลอกจาก config.env.example ก่อน"
  # shellcheck source=/dev/null
  set -a; source "$CONFIG_FILE"; set +a
  # ค่า default: /var/www/<subdomain> (ตามโจทย์)
  : "${WP_ROOT:=/var/www/${DUCKDNS_SUBDOMAIN:-wordpress}}"
  export WP_ROOT
}

# ตรวจว่าตัวแปรที่จำเป็นถูกกรอกแล้ว
require_vars() {
  local missing=()
  for v in "$@"; do
    [[ -n ${!v:-} ]] || missing+=("$v")
  done
  (( ${#missing[@]} == 0 )) || die "config.env ยังไม่ได้กรอก: ${missing[*]}"
}

# ---------- ค่าที่คำนวณได้ ----------
full_domain() { printf '%s.duckdns.org' "$DUCKDNS_SUBDOMAIN"; }

# หา socket ของ PHP-FPM ที่ติดตั้งอยู่จริง (ไม่ fix เวอร์ชัน)
php_fpm_sock() {
  local s
  s=$(find /run/php -maxdepth 1 -name 'php*-fpm.sock' -print -quit 2>/dev/null) || true
  [[ -n $s ]] || die "ไม่พบ socket ของ PHP-FPM — รัน 02-install-lemp.sh ก่อน"
  printf '%s' "$s"
}

php_version() { php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "?"; }

# ---------- สำรองไฟล์ก่อนแก้ ----------
backup_file() {
  local f=$1
  [[ -f $f ]] || return 0
  local b="${f}.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$f" "$b"
  log "สำรอง $f → $b"
}

# ---------- ติดตั้ง package ถ้ายังไม่มี ----------
apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  local todo=()
  for p in "$@"; do
    dpkg -s "$p" &>/dev/null || todo+=("$p")
  done
  if (( ${#todo[@]} )); then
    log "ติดตั้ง: ${todo[*]}"
    apt-get install -y -qq "${todo[@]}"
  fi
}
