#!/usr/bin/env bash
# ===========================================================
#  06 — ด่านที่ 2: Firewall อนุญาตเฉพาะการเชื่อมต่อจากประเทศไทย
#
#  หลักการ:
#    1. ดึงรายการ CIDR ของไทย (IPv4 + IPv6) จาก ipdeny ใส่ใน "ipset"
#       ipset = hash ที่เก็บ network ได้เป็นหมื่นรายการ แล้วให้ iptables เทียบครั้งเดียว
#       (ถ้าเขียนเป็น rule ทีละบรรทัดจะมีหลายพัน rule → เช็คทีละบรรทัด ช้า)
#    2. INPUT policy = DROP (ปฏิเสธเป็นค่าเริ่มต้น) แล้วเปิดเฉพาะที่ต้องการ
#       → whitelist ปลอดภัยกว่า blacklist
#
#  การใช้งาน:
#      sudo ./06-firewall-th-only.sh            ติดตั้ง (มี auto-rollback กันล็อกตัวเอง)
#      sudo ./06-firewall-th-only.sh --confirm  ยืนยันว่ายังเข้าได้ → ยกเลิก rollback + บันทึกถาวร
#      sudo ./06-firewall-th-only.sh --rollback ล้าง firewall กลับเป็นเปิดหมด
#      sudo ./06-firewall-th-only.sh --status   ดูสถานะ
#  อัปเดตรายการ IP ไทย: /usr/local/sbin/th-ipset-refresh.sh (cron ทุกสัปดาห์)
# ===========================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_root
load_config

SET_TH=th-net          # IPv4 ของไทย
SET_TH6=th-net6        # IPv6 ของไทย
SET_CF=cf-net          # Stage 2: IP ของ Cloudflare
RULES_V4=/etc/iptables/rules.v4
RULES_V6=/etc/iptables/rules.v6
IPSETS=/etc/iptables/ipsets
BACKUP_DIR=/root/firewall-backup
REFRESH=/usr/local/sbin/th-ipset-refresh.sh
DEADMAN_SEC=${DEADMAN_SEC:-300}

# Azure: 168.63.129.16 = IP ของแพลตฟอร์ม (DHCP, DNS, health probe, VM agent)
# Microsoft ระบุว่าห้ามบล็อก ไม่งั้นฟีเจอร์อย่าง "Reset password" ใน Portal จะใช้ไม่ได้
AZURE_PLATFORM_IP=168.63.129.16

TH_V4_URL=${TH_ZONE_URL:-https://www.ipdeny.com/ipblocks/data/aggregated/th-aggregated.zone}
TH_V6_URL=${TH_ZONE6_URL:-https://www.ipdeny.com/ipv6/ipaddresses/aggregated/th-aggregated.zone}

# ===========================================================
#  ฟังก์ชันย่อย
# ===========================================================

install_deps() {
  # *-persistent ถามคำถามตอนติดตั้ง → ตอบไว้ล่วงหน้า (ไม่ต้องบันทึก rule ตอนนี้)
  echo "iptables-persistent iptables-persistent/autosave_v4 boolean false" | debconf-set-selections
  echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" | debconf-set-selections
  # ipset-persistent สำคัญมาก: โหลด ipset กลับมา "ก่อน" iptables ตอน boot
  # ถ้าไม่มี iptables-restore จะพังเพราะหา set ไม่เจอ → reboot แล้ว firewall เปิดหมด
  apt_install ipset curl iptables-persistent netfilter-persistent ipset-persistent
}

# ----- สคริปต์อัปเดตรายการ IP ไทย (แยกไว้ใน /usr/local/sbin ให้ root รัน) -----
# ไม่ให้ cron ของ root รันสคริปต์ใน home ของ user เพราะ user แก้ไฟล์แล้วได้สิทธิ root
write_refresh_script() {
  cat >"$REFRESH" <<EOF
#!/usr/bin/env bash
# อัปเดต ipset รายการ IP ของประเทศไทย — สร้างโดย 06-firewall-th-only.sh
# สร้าง set ใหม่ให้เสร็จก่อนแล้วค่อย swap → ไม่มีช่วงที่ set ว่าง (ซึ่งจะบล็อกทุกคน)
set -euo pipefail

load() {   # \$1=ชื่อ set  \$2=family  \$3=URL  \$4=จำนวนขั้นต่ำ
  local set=\$1 fam=\$2 url=\$3 min=\$4 tmp count
  tmp=\$(mktemp)
  curl -fsSL --max-time 60 "\$url" -o "\$tmp"
  count=\$(grep -cE '^[0-9a-fA-F:.]+/[0-9]+' "\$tmp" || true)
  if (( count < min )); then
    logger -t th-ipset "\$set: ได้แค่ \$count รายการ (< \$min) ไม่อัปเดต"
    echo "\$set: ได้แค่ \$count รายการ ดูไม่ปกติ — ไม่อัปเดต" >&2
    rm -f "\$tmp"; return 1
  fi
  ipset -exist create "\$set" hash:net family "\$fam" maxelem 262144
  ipset -exist create "\$set-new" hash:net family "\$fam" maxelem 262144
  ipset flush "\$set-new"
  awk -v s="\$set-new" '/^[0-9a-fA-F:.]+\/[0-9]+/ {print "add " s " " \$1}' "\$tmp" | ipset -exist restore
  ipset swap "\$set-new" "\$set"
  ipset destroy "\$set-new"
  rm -f "\$tmp"
  logger -t th-ipset "\$set: โหลด \$count รายการ"
  echo "\$set: \$count รายการ"
}

load ${SET_TH}  inet  "${TH_V4_URL}" 100
load ${SET_TH6} inet6 "${TH_V6_URL}" 10

# บันทึกเฉพาะ set ของเรา ให้ ipset-persistent โหลดกลับตอน boot
{ ipset save ${SET_TH}; ipset save ${SET_TH6}; ipset list -n | grep -qx ${SET_CF} && ipset save ${SET_CF} || true; } > ${IPSETS}.tmp
mv ${IPSETS}.tmp ${IPSETS}
EOF
  chmod 750 "$REFRESH"
}

load_cf_set() {
  log "โหลดรายการ IP ของ Cloudflare"
  ipset -exist create "$SET_CF" hash:net family inet maxelem 4096
  ipset flush "$SET_CF"
  curl -fsSL --max-time 30 https://www.cloudflare.com/ips-v4 \
    | awk -v s="$SET_CF" '/^[0-9]/ {print "add " s " " $1}' | ipset -exist restore
  ok "โหลด $(ipset list "$SET_CF" | grep -c '^[0-9]') รายการของ Cloudflare"
}

# ----- สำรอง rule เดิม -----
backup_rules() {
  install -d -m 700 "$BACKUP_DIR"
  local ts; ts=$(date +%Y%m%d-%H%M%S)
  BACKUP_V4="$BACKUP_DIR/rules.v4.$ts"
  BACKUP_V6="$BACKUP_DIR/rules.v6.$ts"
  iptables-save  >"$BACKUP_V4"
  ip6tables-save >"$BACKUP_V6"
  ok "สำรอง rule เดิมไว้ที่ $BACKUP_DIR/*.$ts"
}

# ----- บันทึก rule ถาวร (ไม่รวม chain ของ fail2ban) -----
# ถ้าบันทึก chain f2b-* ไปด้วย ตอน boot fail2ban จะสร้าง chain ซ้ำไม่ได้ → start ไม่ขึ้น
save_rules() {
  install -d /etc/iptables
  iptables-save  | grep -v 'f2b-' >"$RULES_V4"
  ip6tables-save | grep -v 'f2b-' >"$RULES_V6"
  { ipset save "$SET_TH"; ipset save "$SET_TH6"; ipset list -n | grep -qx "$SET_CF" && ipset save "$SET_CF" || true; } >"$IPSETS"
  systemctl enable netfilter-persistent &>/dev/null || true
}

# ----- auto-rollback กันล็อกตัวเองออกจาก server -----
# ⚠️ อย่าใช้แค่ "sleep 300 && iptables -F" — ถ้า policy เป็น DROP อยู่ การ flush rule
#    จะเหลือแต่ policy DROP = ล็อกทุกคนออกถาวร ต้อง reset policy เป็น ACCEPT ด้วยเสมอ
arm_deadman() {
  systemctl stop fw-rollback.timer 2>/dev/null || true
  systemctl reset-failed fw-rollback.service fw-rollback.timer 2>/dev/null || true
  systemd-run --unit=fw-rollback --on-active="${DEADMAN_SEC}s" --quiet \
    /bin/bash -c "iptables -P INPUT ACCEPT; ip6tables -P INPUT ACCEPT; \
                  iptables-restore < '$BACKUP_V4'; ip6tables-restore < '$BACKUP_V6'; \
                  logger -t firewall 'auto-rollback: คืนค่า firewall เดิมแล้ว'"
  warn "ตั้ง auto-rollback ไว้: ถ้าไม่ --confirm ภายใน ${DEADMAN_SEC} วินาที firewall จะย้อนกลับเอง"
}

flush_all() {
  for t in filter nat mangle raw; do
    iptables  -t $t -F; iptables  -t $t -X 2>/dev/null || true
    ip6tables -t $t -F; ip6tables -t $t -X 2>/dev/null || true
  done
}

# ===========================================================
#  โหมดต่าง ๆ
# ===========================================================
case "${1:-}" in
  --confirm)
    systemctl stop fw-rollback.timer 2>/dev/null || true
    systemctl reset-failed fw-rollback.service fw-rollback.timer 2>/dev/null || true
    save_rules
    # fail2ban ต้องใส่ chain ของตัวเองกลับ (ถ้าติดตั้งแล้ว)
    systemctl is-active --quiet fail2ban && systemctl restart fail2ban
    ok "ยกเลิก auto-rollback แล้ว และบันทึก rule ลง $RULES_V4, $RULES_V6, $IPSETS"
    exit 0 ;;

  --rollback)
    log "ล้าง firewall ทั้งหมด (เปิดรับทุก IP)"
    systemctl stop fw-rollback.timer 2>/dev/null || true
    iptables -P INPUT ACCEPT;  iptables -P FORWARD ACCEPT;  iptables -P OUTPUT ACCEPT
    ip6tables -P INPUT ACCEPT; ip6tables -P FORWARD ACCEPT; ip6tables -P OUTPUT ACCEPT
    flush_all
    systemctl is-active --quiet fail2ban && systemctl restart fail2ban
    warn "ล้างแล้ว — rule ที่บันทึกไว้ใน $RULES_V4 ยังอยู่ ถ้า reboot จะกลับมาบล็อกอีก"
    warn "ถ้าต้องการปิดถาวร: sudo rm $RULES_V4 $RULES_V6 $IPSETS"
    exit 0 ;;

  --status)
    echo "=============== ipset ==============="
    ipset list -t
    echo "=============== iptables (IPv4) ==============="
    iptables -L -n -v --line-numbers
    echo "=============== ip6tables (IPv6) ==============="
    ip6tables -L INPUT -n -v --line-numbers
    echo "=============== auto-rollback ==============="
    systemctl list-timers fw-rollback.timer --no-pager 2>/dev/null | head -2
    exit 0 ;;

  "") ;;
  *) die "ไม่รู้จัก option: $1" ;;
esac

# ===========================================================
#  ติดตั้ง
# ===========================================================
# IP ของทุกคนที่ ssh ค้างอยู่ตอนนี้ (sudo ล้างตัวแปร SSH_CLIENT ทิ้ง จึงอ่านจาก socket แทน)
mapfile -t SSH_PEERS < <(ss -Htn state established "( sport = :${SSH_PORT:-22} )" \
                         | awk '{print $4}' | sed -E 's/^\[?(.*)\]?:[0-9]+$/\1/; s/^::ffff://; s/\]$//' | sort -u)
echo
warn "สคริปต์นี้จะตั้ง INPUT policy เป็น DROP แล้วเปิด 22/80/443 เฉพาะ IP ประเทศไทย"
(( ${#SSH_PEERS[@]} )) && log "IP ที่กำลัง ssh เข้ามาตอนนี้: ${SSH_PEERS[*]}"
echo

install_deps
backup_rules

log "ดาวน์โหลดรายการ IP ประเทศไทยจาก ipdeny (IPv4 + IPv6)"
write_refresh_script
"$REFRESH" || die "โหลดรายการ IP ไม่สำเร็จ — ยังไม่ได้แตะ firewall"
[[ ${BEHIND_CLOUDFLARE,,} == true ]] && load_cf_set

# ----- เช็คก่อนว่า IP ของเราอยู่ในรายการไทยไหม -----
for ip in "${SSH_PEERS[@]}"; do
  [[ $ip == *:* ]] && set_name=$SET_TH6 || set_name=$SET_TH
  if ipset test "$set_name" "$ip" &>/dev/null; then
    ok "IP $ip อยู่ในรายการประเทศไทย"
  elif [[ " ${ALLOW_SSH_FROM:-} " == *" $ip "* ]]; then
    ok "IP $ip ไม่ใช่ไทย แต่อยู่ใน ALLOW_SSH_FROM"
  else
    die "IP $ip ไม่อยู่ในรายการประเทศไทย — ใส่ใน ALLOW_SSH_FROM ของ config.env ก่อน ไม่งั้นจะ ssh เข้าไม่ได้อีก
      (ยังไม่ได้แตะ firewall)"
  fi
done

log "เขียน iptables rules"

# ---------- ล้างของเดิม ----------
# เปิด policy เป็น ACCEPT ก่อนล้าง → รันสคริปต์ซ้ำได้โดยไม่ตัด ssh ของเรา
iptables -P INPUT ACCEPT; ip6tables -P INPUT ACCEPT
flush_all

# =================== IPv4 ===================
# chain สำหรับ log ของที่ถูกทิ้ง (ใช้ป้อน Stage 2 AI log scan)
iptables -N LOGDROP
iptables -A LOGDROP -m limit --limit 10/min --limit-burst 20 \
         -j LOG --log-prefix "GEOBLOCK-DROP " --log-level 4
iptables -A LOGDROP -j DROP

# chain ตรวจว่ามาจากไทยหรือไม่
iptables -N GEO-CHECK
iptables -A GEO-CHECK -m set --match-set "$SET_TH" src -j ACCEPT
[[ ${BEHIND_CLOUDFLARE,,} == true ]] && iptables -A GEO-CHECK -m set --match-set "$SET_CF" src -j ACCEPT
iptables -A GEO-CHECK -j LOGDROP

# 1) loopback — process ในเครื่องคุยกันเอง
iptables -A INPUT -i lo -j ACCEPT
# 2) connection ที่เราเป็นฝ่ายเริ่ม (apt, curl, acme.sh, DuckDNS) — conntrack จำสถานะไว้
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# 3) ทิ้ง packet ที่สถานะผิดปกติ (มักเป็น port scan / spoof)
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
iptables -A INPUT -p tcp ! --syn -m conntrack --ctstate NEW -j DROP
# 4) แพลตฟอร์ม Azure (ห้ามบล็อก)
iptables -A INPUT -s "$AZURE_PLATFORM_IP" -j ACCEPT
# 5) ping — ต้องมาจากไทย และจำกัดอัตรา
iptables -A INPUT -p icmp --icmp-type echo-request -m set --match-set "$SET_TH" src \
         -m limit --limit 5/sec -j ACCEPT
iptables -A INPUT -p icmp --icmp-type echo-request -j DROP
# 6) SSH
if [[ -n ${ALLOW_SSH_FROM:-} ]]; then
  for src in $ALLOW_SSH_FROM; do
    iptables -A INPUT -p tcp --dport "${SSH_PORT:-22}" -s "$src" -j ACCEPT
    log "อนุญาต SSH จาก $src (นอกเหนือจาก IP ไทย)"
  done
fi
# จำกัดการต่อใหม่ 10 ครั้ง/นาที/IP (กัน brute-force — ทั้งมหาวิทยาลัยอาจออกเน็ตด้วย IP เดียว จึงไม่ตั้งต่ำ)
iptables -A INPUT -p tcp --dport "${SSH_PORT:-22}" -m conntrack --ctstate NEW \
         -m recent --set --name SSHBRUTE
iptables -A INPUT -p tcp --dport "${SSH_PORT:-22}" -m conntrack --ctstate NEW \
         -m recent --update --seconds 60 --hitcount 10 --name SSHBRUTE -j LOGDROP
iptables -A INPUT -p tcp --dport "${SSH_PORT:-22}" -j GEO-CHECK
# 7) เว็บ 80/443 — ★ หัวใจของด่านที่ 2 ★
iptables -A INPUT -p tcp -m multiport --dports 80,443 -j GEO-CHECK
# 8) ที่เหลือทิ้งทั้งหมด
iptables -A INPUT -j LOGDROP

iptables -P INPUT   DROP      # ปฏิเสธเป็นค่าเริ่มต้น
iptables -P FORWARD DROP      # เครื่องนี้ไม่ใช่ router
iptables -P OUTPUT  ACCEPT    # ขาออกเปิด (apt / acme.sh / DuckDNS / ipdeny ต้องใช้)

# =================== IPv6 (ทำเหมือนกัน) ===================
# VM บน Azure ยังไม่มี IPv6 แต่ตั้งไว้ให้ครบ กันกลายเป็นช่องทางเลี่ยง geo-block ในอนาคต
ip6tables -N LOGDROP
ip6tables -A LOGDROP -m limit --limit 10/min -j LOG --log-prefix "GEOBLOCK6-DROP " --log-level 4
ip6tables -A LOGDROP -j DROP
ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip6tables -A INPUT -m conntrack --ctstate INVALID -j DROP
ip6tables -A INPUT -p ipv6-icmp -j ACCEPT     # IPv6 ต้องมี ICMPv6 (neighbor discovery) ไม่งั้น network พัง
ip6tables -A INPUT -p tcp -m multiport --dports "${SSH_PORT:-22}",80,443 \
          -m set --match-set "$SET_TH6" src -j ACCEPT
ip6tables -A INPUT -j LOGDROP
ip6tables -P INPUT   DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT  ACCEPT

ok "ติดตั้ง rule เรียบร้อย"

# fail2ban (ถ้ามี) ใส่ chain ของตัวเองกลับหลังเรา flush
systemctl is-active --quiet fail2ban && systemctl restart fail2ban

# ===========================================================
#  cron อัปเดตรายการ IP ไทยสัปดาห์ละครั้ง (อาทิตย์ 04:30)
# ===========================================================
if systemctl list-unit-files th-ipset-refresh.timer &>/dev/null; then   # ของเวอร์ชันเก่า
  systemctl disable --now th-ipset-refresh.timer 2>/dev/null || true
  rm -f /etc/systemd/system/th-ipset-refresh.{timer,service}; systemctl daemon-reload
fi
cat >/etc/cron.d/th-ipset-refresh <<EOF
# อัปเดตรายการ IP ประเทศไทย (ipdeny) สัปดาห์ละครั้ง — สร้างโดย 06-firewall-th-only.sh
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
30 4 * * 0 root $REFRESH >/dev/null 2>&1
EOF
chmod 644 /etc/cron.d/th-ipset-refresh
ok "ตั้ง cron อัปเดตรายการ IP ไทย: /etc/cron.d/th-ipset-refresh"

# ===========================================================
#  auto-rollback + สรุป
# ===========================================================
arm_deadman

cat <<EOF

${_C_RED}ต้องยืนยันภายใน ${DEADMAN_SEC} วินาที ไม่งั้น firewall จะย้อนกลับเอง${_C_RESET}

1) เปิด terminal ${_C_YELLOW}หน้าต่างใหม่${_C_RESET} แล้วลอง:   ssh wp-vps
2) ถ้าเข้าได้ → รัน:   sudo $0 --confirm
3) ถ้าเข้าไม่ได้ → รอ ${DEADMAN_SEC} วินาที firewall จะคืนค่าเดิมเอง

ดู log ของที่ถูกบล็อก:  sudo journalctl -k --grep='GEOBLOCK' -n 50
EOF
