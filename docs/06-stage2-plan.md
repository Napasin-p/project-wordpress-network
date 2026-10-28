# แผน Stage 2 (ฉบับใช้จริง) — ส่งพร้อม Stage 1 วันที่ 28 ต.ค. 2026

> อาจารย์ตรวจ Stage 1 + Stage 2 พร้อมกัน → วันที่ 28 ระบบต้องผ่านเกณฑ์ **ทั้งสอง stage ในเวลาเดียวกัน**
> เอกสารเทคนิคประกอบ: `05-stage2-roadmap.md` (บางส่วนเขียนก่อนลงมือจริง — ใช้ไฟล์นี้เป็นหลัก)

---

## แนวคิดหลัก: ทางเข้า 2 ทาง → เว็บเดียวกัน

```
 ทาง A (Stage 1)                         ทาง B (Stage 2)
 freexduk.duckdns.org                    <โดเมน>.me
        │ DNS ชี้ตรงมาที่ VM                     │ DNS อยู่ที่ Cloudflare (เมฆส้ม)
        │                                       ▼
        │                          Cloudflare: CDN cache · WAF บล็อกนอกไทย · DDoS
        │                                       │
        ▼                                       ▼
 ┌──────────────── Azure NSG: 22 / 80 / 443 ─────────────────┐
 │ iptables: 80/443 รับจาก  IP ไทย (ทาง A)  หรือ  IP Cloudflare (ทาง B) │
 │           22 รับจาก IP ไทยเท่านั้น · fail2ban                       │
 └───────────────────────────┬────────────────────────────────┘
                             ▼
        Nginx หน้าบ้าน (reverse proxy) :443
          TLS · rate limit · micro-cache · real IP (CF-Connecting-IP)
             ├──► 127.0.0.1:8080  Nginx + PHP-FPM ──► MySQL   (WordPress เดิม)
             └──► 127.0.0.1:8081  Security Dashboard (container)
                                      ▲
        log-analyzer (container, ทุก 6 ชม.) ──► Claude API ──► findings.json
          อ่าน log แบบ read-only: nginx · auth/ssh · fail2ban · GEOBLOCK-DROP
```

| เกณฑ์ | ทาง A — duckdns | ทาง B — โดเมนจริง |
|---|---|---|
| Stage 1: HTTPS + WordPress | ✅ Let's Encrypt (เหมือนเดิม) | ✅ Cloudflare edge + Origin Cert (Full strict) |
| Stage 1: VPN ต่างประเทศเข้าไม่ได้ | ✅ iptables + ipset | ✅ Cloudflare WAF (บล็อกที่ edge) |
| Stage 2: CDN cache / WAF | — | ✅ |
| Stage 2: origin รับเฉพาะ Cloudflare | — (ทางนี้ตั้งใจเปิดไว้ให้เกณฑ์ Stage 1) | ✅ ipset `cf-net` |
| Stage 2: reverse proxy + rate limit + cache | ✅ ใช้ร่วมกัน | ✅ ใช้ร่วมกัน |
| Stage 2: AI dashboard | ✅ ใช้ร่วมกัน | ✅ ใช้ร่วมกัน |

> ในรายงานอธิบายว่า: production จริงจะปิดทาง A ทิ้ง (เหลือแค่ Cloudflare) — เปิดไว้เพื่อให้ตรวจเกณฑ์ Stage 1 ได้
> และสาธิตได้ว่าถ้าปิดทาง A ด้วยคำสั่งเดียว origin จะซ่อนสมบูรณ์

WordPress ต้องตอบได้ 2 โดเมน → `WP_HOME` เลือกจาก `Host` ที่อยู่ใน whitelist เท่านั้น (กัน Host header injection)

---

## ตารางเวลา (13 วัน)

| วันที่ | Phase | งาน | กระทบเว็บที่เพื่อนแก้อยู่? |
|---|---|---|---|
| **15–16 ต.ค.** | 0 | วัดตัวเลข "ก่อน" (TTFB, req/s, p95) · เก็บ log 30 วัน · เพิ่มเวลาประมวลผลใน access log | ไม่กระทบ |
| 15 ต.ค. | — | **สมาชิก:** ขอ GitHub Student Pack · สมัคร Cloudflare · สมัคร Anthropic Console + API key | — |
| **16–21 ต.ค.** | 1 | log collector + Claude วิเคราะห์ + dashboard ใน container | ไม่กระทบ (อ่าน log อย่างเดียว) |
| **21–23 ต.ค.** | 2 | Nginx หน้าบ้าน + WordPress ย้ายไป :8080 · rate limit · micro-cache | สะดุด < 1 นาที — ทำช่วงกลางคืน แจ้งทีมก่อน |
| **23–25 ต.ค.** | 3 | โดเมนใหม่ → Cloudflare · WAF TH-only · Origin Cert · real IP · firewall เพิ่ม `cf-net` · WP 2 โดเมน | สะดุดสั้น ๆ — แจ้งทีมก่อน |
| **25–27 ต.ค.** | 4 | วัดตัวเลข "หลัง" · เก็บหลักฐาน · รายงาน · **เผื่อเวลาแก้ปัญหา** | — |
| **25 ต.ค.** | — | **ทีมด่าน 3:** เนื้อหาเว็บเสร็จ (เพื่อเก็บภาพหน้าจอ) | — |
| **28 ต.ค.** | — | ส่ง / ตรวจ | ห้ามแก้ระบบวันนี้ |

**แผนสำรอง:** ถ้า GitHub Student Pack ยังไม่อนุมัติภายใน **21 ต.ค.** → ซื้อโดเมนราคาถูก (.xyz ฯลฯ) แทน

---

## รายละเอียดแต่ละ Phase

### Phase 0 — ตัวเลข "ก่อน" (ต้องทำก่อนแก้อะไรทั้งสิ้น)
- วัด TTFB ทุกหน้า + ยิง request เบา ๆ (ไม่กี่ร้อยครั้ง) จากเครื่องในไทย → req/s, p95
- logrotate nginx เก็บ 30 วัน (ข้อมูลให้ AI + dashboard)
- เพิ่ม `$request_time` ต่อท้าย access log (ต่อท้ายเท่านั้น — regex fail2ban ไม่พัง)

### Phase 1 — AI สแกน log → Dashboard
1. **collector** (Python): สรุปสถิติก่อนส่ง AI — top IP, ประเทศที่โดน GEOBLOCK-DROP, path ที่โดนสแกน, 404 ต่อ IP, SSH fail, fail2ban ban/unban, request ที่มี pattern SQLi/path traversal
2. **Claude API** (`claude-sonnet-5-5`): ส่งเฉพาะสรุป (ไม่ส่ง log ดิบ) → ตอบเป็น JSON ตาม schema (threat_level, incidents, evidence, recommended_action)
   — **AI เสนอเท่านั้น ไม่สั่งแบน IP เอง**
3. **dashboard**: ไฟสถานะ · กราฟบล็อกรายชั่วโมง · ตารางประเทศ · incident ที่ AI พบ · IP ที่ถูกแบน · วันหมดอายุใบรับรอง · CPU/RAM
4. **container**: analyzer รันใน Docker — mount log แบบ read-only, ไม่มีสิทธิ root บน host
5. **ความปลอดภัย**: dashboard มีรหัสผ่าน + เข้าได้เฉพาะ IP ไทย · API key ใน `/etc/logwatch.env` (600) · ปิดบัง IP บางส่วนเวลานำเสนอ (PDPA)
6. systemd timer ทุก 6 ชม. (+ ปุ่มสั่งสแกนทันทีสำหรับเดโม)

### Phase 2 — Reverse proxy
- WordPress vhost → `127.0.0.1:8080` · Nginx หน้าบ้านรับ 443 ทั้ง 2 โดเมน
- `proxy_set_header X-Forwarded-For/Proto` + `real_ip` → WordPress, fail2ban, Limit Login เห็น IP จริง
- rate limit: `/wp-login.php` 5 r/m · ทั่วไป 30 r/m → ทดสอบต้องได้ **429**
- micro-cache 1 วินาที + `X-Cache-Status` → ทดสอบต้องได้ **HIT** · bypass คนที่ login / wp-admin
- upstream ที่สอง: dashboard container

### Phase 3 — Cloudflare
- เพิ่มโดเมนใน Cloudflare → เปลี่ยน nameserver ที่ Namecheap
- A record → 172.197.162.225 (เมฆส้ม) · SSL **Full (strict)** + Cloudflare Origin Certificate
- WAF custom rule: `ip.src.country ne "TH"` → Block
- Cache Rules: bypass `/wp-admin*`, `/wp-login.php`, cookie `wordpress_logged_in*` · cache static
- real IP: `set_real_ip_from <Cloudflare ranges>` + `real_ip_header CF-Connecting-IP`
  ⚠️ ถ้าไม่ตั้ง fail2ban จะเห็นทุกคนเป็น IP Cloudflare → แบน Cloudflare → เว็บทาง B ล่ม
- iptables: `BEHIND_CLOUDFLARE=true` → GEO-CHECK รับ `th-net` หรือ `cf-net` · cron อัปเดต IP Cloudflare
- WordPress รับ 2 โดเมน (whitelist)

### Phase 4 — หลักฐาน + รายงาน
| ต้องพิสูจน์ | วิธี |
|---|---|
| reverse proxy + cache | `curl -I` → `X-Cache-Status: HIT` · ตัวเลขก่อน/หลัง |
| rate limit | ยิง login รัว ๆ → 429 |
| Cloudflare | header `cf-ray`, `cf-cache-status: HIT` |
| WAF บล็อกต่างประเทศ | VPN → หน้า Cloudflare block + Security Events |
| origin รับเฉพาะ Cloudflare (ทาง B) | `curl --resolve <โดเมน>:443:172.197.162.225` จาก IP ที่ไม่ใช่ไทยหรือ Cloudflare → timeout |
| real IP | log มี IP จริง ไม่ใช่ IP Cloudflare |
| AI dashboard | ภาพหน้าจอ + ตัวอย่าง JSON ที่ AI วิเคราะห์จาก log จริง |

---

## สิ่งที่สมาชิกต้องทำ (เริ่มวันนี้)
1. **GitHub Student Developer Pack** — https://education.github.com/pack สมัครด้วยอีเมล `@my.buu.ac.th` + หลักฐานนักศึกษา
   → อนุมัติแล้วรับโดเมน `.me` ฟรีที่ Namecheap (อาจใช้เวลาหลายวัน — ต้องเริ่มเร็ว)
2. **Cloudflare** — สมัครบัญชีฟรีที่ https://dash.cloudflare.com
3. **Anthropic Console** — https://console.anthropic.com สมัคร + เติมเครดิตขั้นต่ำ + สร้าง API key
   → **ห้ามส่ง key ในแชท** — ใส่ใน `config.env` เอง (`ANTHROPIC_API_KEY=`)
4. **ทีมด่าน 3** — เนื้อหาเว็บเสร็จภายใน 25 ต.ค. และรับทราบว่าวันที่ 21–25 อาจมีช่วงเว็บสะดุดสั้น ๆ (จะแจ้งก่อน)

## ความเสี่ยง
| ความเสี่ยง | รับมือ |
|---|---|
| Student Pack อนุมัติช้า | 21 ต.ค. ยังไม่ได้ → ซื้อโดเมนถูก ๆ |
| ย้าย reverse proxy แล้วเว็บพัง | `nginx -t` ทุกครั้ง · สำรอง config · ทำกลางคืน · ย้อนกลับได้ด้วยไฟล์สำรอง |
| fail2ban แบน Cloudflare | ตั้ง real IP ก่อนเปิดเมฆส้ม · ignoreip ช่วง Cloudflare |
| ส่ง IP ให้ API ภายนอก (PDPA) | ส่งเฉพาะสรุป · ปิดบัง IP บน dashboard ตอนนำเสนอ |
| เครดิต Azure | ~$31/เดือน พอถึงต้นมกราคม — ไม่กระทบวันที่ 28 |
