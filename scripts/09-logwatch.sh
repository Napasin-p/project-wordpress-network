#!/usr/bin/env bash
# ===========================================================
#  09 — Stage 2: AI สแกน log → dashboard (container)
#
#  ต้องมี Docker แบบ "iptables": false ก่อน (ดู runbook Stage 2 ข้อ 1.1)
#      sudo ./09-logwatch.sh             ติดตั้ง/อัปเดต + ทดสอบแบบไม่เรียก AI
#      sudo ./09-logwatch.sh --run       สั่งวิเคราะห์ทันที 1 รอบ (เรียก Claude — มีค่าใช้จ่าย)
#      sudo ./09-logwatch.sh --status    ดูสถานะ timer + ผลรอบล่าสุด
# ===========================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_root
load_config

SRC="$PROJECT_ROOT/logwatch"
DST=/opt/logwatch
ENVF=/etc/logwatch.env
COMPOSE=(docker compose -f "$DST/docker-compose.yml")

case "${1:-}" in
  --run)
    systemctl daemon-reload
    systemctl start logwatch.service || true
    journalctl -u logwatch.service -n 5 --no-pager -o cat
    exit 0 ;;
  --status)
    systemctl list-timers logwatch.timer --no-pager
    "${COMPOSE[@]}" ps
    tail -c 600 /var/lib/logwatch/out/history.json 2>/dev/null; echo
    exit 0 ;;
  "") ;;
  *) die "ไม่รู้จัก option: $1" ;;
esac

command -v docker >/dev/null || die "ยังไม่ได้ติดตั้ง Docker"
grep -q '"iptables": false' /etc/docker/daemon.json 2>/dev/null \
  || die "/etc/docker/daemon.json ต้องมี \"iptables\": false — ไม่งั้น Docker จะแก้ firewall เอง"
require_vars ANTHROPIC_API_KEY

# ----- 1) คัดลอกไฟล์ไป /opt (เจ้าของ root) — ไม่รันโค้ดจาก home ของ user ด้วยสิทธิ root -----
log "ติดตั้งไฟล์ที่ $DST"
install -d -m 755 "$DST" "$DST/dashboard"
install -m 644 "$SRC/logwatch.py" "$SRC/Dockerfile" "$SRC/docker-compose.yml" "$DST/"
install -m 755 "$SRC/prepare.sh" "$DST/"
install -m 644 "$SRC"/dashboard/* "$DST/dashboard/"
install -m 644 "$SRC/systemd/logwatch.service" "$SRC/systemd/logwatch.timer" /etc/systemd/system/

# ----- 2) API key แยกไฟล์ สิทธิ 600 root -----
umask 077
cat >"$ENVF" <<EOF
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
CLAUDE_MODEL=${CLAUDE_MODEL:-claude-opus-5-5}
CLAUDE_EFFORT=${CLAUDE_EFFORT:-medium}
ANTHROPIC_WORKSPACE_ID=${ANTHROPIC_WORKSPACE_ID:-}
EOF
chmod 600 "$ENVF"; umask 022
ok "เก็บ API key ที่ $ENVF (600) · model: ${CLAUDE_MODEL:-claude-opus-5-5}"

# ----- 3) build image + เปิด dashboard -----
log "build analyzer image"
"${COMPOSE[@]}" --profile job build --quiet analyzer
"$DST/prepare.sh"   # สร้าง /var/lib/logwatch/* ให้สิทธิถูกต้องก่อน mount
log "เปิด dashboard container (127.0.0.1:8081)"
"${COMPOSE[@]}" up -d dashboard

# ----- 4) ทดสอบแบบไม่เรียก AI -----
log "ทดสอบเก็บสถิติ (ไม่เรียก AI)"
"$DST/prepare.sh"
"${COMPOSE[@]}" run --rm analyzer --no-ai

# ----- 5) timer ทุก 6 ชม. -----
systemctl daemon-reload
systemctl enable --now logwatch.timer >/dev/null
ok "logwatch.timer: $(systemctl list-timers logwatch.timer --no-pager | sed -n 2p | awk '{print $1, $2, $3}')"

curl -s -o /dev/null -w '    dashboard (local) → HTTP %{http_code}\n' http://127.0.0.1:8081/
curl -s -o /dev/null -w '    data/latest.json  → HTTP %{http_code}\n' http://127.0.0.1:8081/data/latest.json
cat <<EOF

  สั่งวิเคราะห์ด้วย AI ทันที:  sudo $0 --run
  ดูสถานะ:                   sudo $0 --status
EOF
