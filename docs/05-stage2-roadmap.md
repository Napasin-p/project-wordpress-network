# เอกสารที่ 5 — Stage 2: ยกระดับความปลอดภัยและประสิทธิภาพ

> โจทย์: *"ปรับโครงสร้างของสถาปัตยกรรมที่ออกแบบไว้ให้มีความปลอดภัยสูงขึ้น หรือมี
> ประสิทธิภาพสูงขึ้น เช่น ทำ reverse proxy, ใช้ cloudflare cache, มีการนำเอา AI
> มา scan log ตามระยะเวลาที่กำหนดเพื่อสร้างเป็น dashboard สำหรับตรวจสอบการโจมตี
> ของบุคคลไม่พึงประสงค์"*

---

## สถาปัตยกรรมเป้าหมายของ Stage 2

```
   ผู้ใช้  ──https──►  ┌─────────────── Cloudflare ────────────────┐
                       │  • CDN cache ไฟล์ static (edge node)      │
                       │  • WAF บล็อก SQLi / XSS                   │
                       │  • Geo rule: อนุญาตเฉพาะ TH  ◄── ย้าย     │
                       │    geo-block มาทำที่นี่ (ประหยัด bandwidth)│
                       │  • DDoS protection + rate limit           │
                       └───────────────┬──────────────────────────┘
                                       │ ต่อเข้าได้เฉพาะ IP ของ Cloudflare
   ╔═══════════════════════════════════▼══════════════════════════════╗
   ║  iptables: อนุญาต 80/443 เฉพาะ ipset "cf-net"                   ║
   ║            (BEHIND_CLOUDFLARE=true ใน config.env)                ║
   ║            ★ ทำให้ origin IP ซ่อนอยู่ ไม่มีใครโจมตีตรงได้        ║
   ║       │                                                          ║
   ║       ▼                                                          ║
   ║  nginx (reverse proxy)  :443                                     ║
   ║    • rate limit ต่อ IP                                           ║
   ║    • micro-cache 1 วินาที (รับ traffic พุ่งได้)                  ║
   ║    • ส่งต่อไป upstream                                           ║
   ║       │ proxy_pass http://127.0.0.1:8080                         ║
   ║       ▼                                                          ║
   ║  nginx/Apache (origin)  :8080  ──► PHP-FPM ──► MariaDB          ║
   ║       +  Redis object cache (ลดการ query database)              ║
   ║                                                                  ║
   ║  ──── ชั้นเฝ้าระวัง ────                                        ║
   ║  fail2ban      อ่าน log → แบน IP ที่โจมตีอัตโนมัติ              ║
   ║  log-analyzer  ส่ง log ให้ Claude API วิเคราะห์ทุก 6 ชม.        ║
   ║       │                                                          ║
   ║       ▼                                                          ║
   ║  dashboard (/security-dashboard)                                 ║
   ╚══════════════════════════════════════════════════════════════════╝
```

---

## งานที่ 1 — Reverse Proxy

### Reverse proxy คืออะไร (ต่างจาก forward proxy)
```
Forward proxy :  client ──► proxy ──► internet     (ซ่อนตัว client, เช่น VPN)
Reverse proxy :  client ──► proxy ──► server       (ซ่อนตัว server)
                            ▲
                      ลูกค้าคิดว่านี่คือเว็บจริง
```

### ประโยชน์
| ได้อะไร | อธิบาย |
|---|---|
| **ซ่อน origin** | ผู้โจมตีไม่รู้ IP จริงของเครื่องที่รัน WordPress |
| **TLS termination** | ถอดรหัสที่จุดเดียว เครื่องหลังบ้านไม่ต้องเสีย CPU ทำ TLS |
| **cache ชั้นหน้า** | ตอบจาก cache ไม่ต้องรบกวน PHP เลย |
| **rate limit จุดเดียว** | คุมทุกการเข้าถึงจากที่เดียว |
| **ขยายได้** | ถ้าเครื่องเดียวไม่พอ เพิ่ม upstream แล้ว load balance |

### ตัวอย่างการตั้งค่า
```nginx
# /etc/nginx/conf.d/ratelimit.conf
# ---------- zone นับจำนวน request ต่อ IP ----------
# $binary_remote_addr ใช้พื้นที่น้อยกว่า $remote_addr
limit_req_zone  $binary_remote_addr zone=general:10m rate=30r/m;
limit_req_zone  $binary_remote_addr zone=login:10m   rate=5r/m;
limit_conn_zone $binary_remote_addr zone=perip:10m;

# ---------- micro-cache ----------
# cache แค่ 1 วินาที — ผู้ใช้ไม่รู้สึกว่าเนื้อหาเก่า
# แต่ถ้ามี 1,000 request/วินาที PHP ถูกเรียกแค่ 1 ครั้ง
proxy_cache_path /var/cache/nginx/micro levels=1:2
                 keys_zone=micro:10m max_size=500m inactive=10m;
```

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name cs-xxx.duckdns.org;

    ssl_certificate     /etc/letsencrypt/live/cs-xxx.duckdns.org/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/cs-xxx.duckdns.org/privkey.pem;

    limit_conn perip 20;

    # ---------- หน้า login: จำกัดเข้มที่สุด ----------
    location = /wp-login.php {
        limit_req zone=login burst=3 nodelay;
        proxy_pass http://origin;
        include proxy_params;
    }

    # ---------- เนื้อหาทั่วไป ----------
    location / {
        limit_req zone=general burst=20 nodelay;

        proxy_cache micro;
        proxy_cache_valid 200 301 302 1s;
        proxy_cache_use_stale error timeout updating http_500 http_502 http_503;
        proxy_cache_lock on;            # request พร้อมกันหลายตัว → ไปหา origin แค่ตัวเดียว
        add_header X-Cache-Status $upstream_cache_status;   # ใช้พิสูจน์ว่า cache ทำงาน

        # ไม่ cache ให้คนที่ล็อกอินอยู่ (จะเห็นหน้าของคนอื่น!)
        proxy_no_cache     $cookie_wordpress_logged_in;
        proxy_cache_bypass $cookie_wordpress_logged_in;

        proxy_pass http://origin;
        include proxy_params;
    }
}

upstream origin {
    server 127.0.0.1:8080;
    keepalive 32;         # ใช้ connection ซ้ำ ไม่ต้อง TCP handshake ใหม่ทุกครั้ง
}
```

```nginx
# /etc/nginx/proxy_params
# ★ สำคัญมาก: ถ้าไม่ส่ง header เหล่านี้ WordPress จะเห็น IP ผู้ใช้
#   เป็น 127.0.0.1 ทุกคน → log ไร้ประโยชน์, fail2ban แบนไม่ได้
proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_http_version 1.1;
proxy_set_header Connection "";
```

### พิสูจน์ว่า cache ทำงาน
```bash
curl -sI https://cs-xxx.duckdns.org | grep X-Cache-Status
# ครั้งแรก : MISS
# ครั้งที่ 2: HIT   ← ไม่ได้แตะ PHP เลย

# วัดเวลาตอบสนองเทียบกัน
for i in 1 2 3; do curl -s -o /dev/null -w "%{time_total}s\n" https://cs-xxx.duckdns.org; done
```

---

## งานที่ 2 — Cloudflare

### ขั้นตอน
1. DuckDNS ไม่ให้เราย้าย nameserver ได้ → **ต้องจดโดเมนจริงเพิ่ม** (เช่น `.xyz` ปีละไม่กี่สิบบาท)
   หรือใช้ **Cloudflare Tunnel** ซึ่งไม่ต้องย้าย nameserver
2. เพิ่มโดเมนใน Cloudflare → เปลี่ยน nameserver ที่ registrar
3. ตั้ง A record ชี้มา VPS แล้วเปิดเมฆสีส้ม (proxied)
4. SSL/TLS mode = **Full (strict)** ← ต้อง strict ไม่ใช่ Flexible
   (Flexible = Cloudflare→origin ไม่เข้ารหัส ข้อมูลวิ่งเปล่าในอินเทอร์เน็ต)
5. ตั้ง `BEHIND_CLOUDFLARE=true` ใน `config.env` แล้วรัน `06-firewall-th-only.sh` ใหม่
   → firewall จะอนุญาตเฉพาะ IP ของ Cloudflare

### ย้าย geo-block ขึ้นไปทำที่ Cloudflare
```
Security → WAF → Custom rules → Create rule
  ชื่อ     : Allow Thailand only
  เงื่อนไข : (ip.geoip.country ne "TH")
  action  : Block
```
**ข้อดีกว่าทำที่ iptables:** การบล็อกเกิดที่ edge node ทั่วโลก
→ traffic ต่างประเทศ **ไม่เดินทางมาถึง VPS เลย** ประหยัด bandwidth และ CPU

### ตั้ง cache
```
Caching → Configuration → Browser Cache TTL = 4 hours
Rules → Page Rules:
   cs-xxx.com/wp-admin/*   → Cache Level: Bypass    ★ ต้องมี
   cs-xxx.com/wp-login.php → Cache Level: Bypass    ★ ต้องมี
   cs-xxx.com/*            → Cache Level: Standard
Speed → Optimization → เปิด Brotli, Early Hints
```
> ⚠️ **ถ้าไม่ bypass หน้า wp-admin** Cloudflare จะ cache หน้า dashboard
> ของ admin คนหนึ่งแล้วส่งให้คนอื่นเห็น — เป็นช่องโหว่ร้ายแรง

### ★ ปัญหาที่ต้องแก้: IP ของผู้ใช้
เมื่ออยู่หลัง Cloudflare, nginx จะเห็น source IP เป็น **IP ของ Cloudflare** ทุกคน
ต้องตั้ง `real_ip` ให้อ่าน IP จริงจาก header ที่ Cloudflare ส่งมา:
```nginx
# /etc/nginx/conf.d/cloudflare-realip.conf
# (สร้างด้วยสคริปต์ให้อัปเดต list เองเป็นระยะ)
set_real_ip_from 173.245.48.0/20;
set_real_ip_from 103.21.244.0/22;
# ... (ดูรายการเต็มที่ https://www.cloudflare.com/ips-v4)
real_ip_header CF-Connecting-IP;
```
ถ้าไม่ตั้ง → log ทุกบรรทัดเป็น IP ของ Cloudflare → **fail2ban จะแบน Cloudflare
แล้วเว็บล่มทั้งเว็บ**

---

## งานที่ 3 — fail2ban (ป้องกันแบบตอบสนองอัตโนมัติ)

ต่างจาก iptables ที่เป็นกฎนิ่ง — fail2ban **อ่าน log แล้วแบน IP ที่มีพฤติกรรมน่าสงสัยเอง**

```ini
# /etc/fail2ban/jail.local
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd
# อย่าแบนตัวเองและ Cloudflare
ignoreip = 127.0.0.1/8 ::1 <ip-ของทีม>

[sshd]
enabled = true
maxretry = 3
bantime = 24h

[nginx-http-auth]
enabled = true

[nginx-limit-req]
enabled = true
# จับคนที่ชน rate limit ของ nginx บ่อย ๆ

[wordpress-login]
enabled  = true
filter   = wordpress-login
logpath  = /var/log/nginx/access.log
maxretry = 5
bantime  = 2h
```

```ini
# /etc/fail2ban/filter.d/wordpress-login.conf
[Definition]
# จับ POST ไปหน้า login ที่ถูกตอบ 200 (= login ไม่ผ่าน WordPress ส่งหน้าเดิมกลับ)
failregex = ^<HOST> .* "POST /wp-login\.php.*" 200
ignoreregex =
```

```bash
sudo fail2ban-client status                   # ดู jail ทั้งหมด
sudo fail2ban-client status wordpress-login   # ดูว่าแบนใครไปแล้ว
sudo fail2ban-client set sshd unbanip 1.2.3.4 # ปลดแบน
```

---

## งานที่ 4 — ★ AI สแกน log → Dashboard

นี่คือส่วนที่โจทย์ระบุชัดและเป็นจุดที่ทำคะแนนได้มาก

### สถาปัตยกรรม
```
  ┌──── แหล่ง log ────┐
  │ nginx access.log  │
  │ nginx error.log   │   ทุก 6 ชั่วโมง
  │ auth.log (ssh)    │ ──────────────►  collector
  │ GEOBLOCK-DROP     │                  (จาก journalctl -k)
  │ fail2ban.log      │
  └───────────────────┘
            │
            ▼  ① สรุปเชิงสถิติด้วย awk/python (ลดขนาดก่อนส่ง)
      pre-aggregate
       • top 20 source IP + จำนวน request
       • การกระจายของ HTTP status code
       • path ที่โดนยิงบ่อยที่สุด
       • จำนวน 404 ต่อ IP (= พฤติกรรมสแกนหาช่องโหว่)
       • จำนวนครั้งที่ ssh ล้มเหลว แยกตาม IP
            │
            ▼  ② ส่งสรุปให้ Claude API วิเคราะห์
      ╔═══════════════════════════════════════════════╗
      ║  model: claude-sonnet-5                       ║
      ║  ให้ตอบกลับเป็น JSON schema ที่กำหนด:          ║
      ║   { threat_level, incidents[], recommend[] }   ║
      ╚═══════════════════════════════════════════════╝
            │
            ▼  ③ เก็บผลลง SQLite
       /var/lib/logwatch/findings.db
            │
            ▼  ④ แสดงเป็นหน้า dashboard
       https://<โดเมน>/security-dashboard
       (ป้องกันด้วย HTTP Basic Auth + จำกัด IP)
```

### ทำไมต้อง pre-aggregate ก่อนส่งให้ AI
access.log วันละหลายหมื่นบรรทัด = หลายล้าน token
- **แพง** — คิดเงินตาม token
- **เกิน context window**
- **คุณภาพแย่กว่า** — ข้อมูลซ้ำ ๆ กลบสัญญาณที่สำคัญ

สรุปเชิงสถิติก่อนให้เหลือ ~2-3 พัน token แล้วให้ AI ทำสิ่งที่มันเก่งจริง คือ
**ตีความรูปแบบและอธิบายว่าพฤติกรรมนี้คืออะไร** ไม่ใช่ให้มานับเลข
(การนับใช้ `awk` เร็วกว่าและแม่นกว่า)

### สิ่งที่ AI ควรหา (เขียนใน prompt)
| รูปแบบ | สัญญาณบ่งชี้ |
|---|---|
| Brute-force | POST `/wp-login.php` ซ้ำจาก IP เดียวถี่ ๆ |
| Vulnerability scan | 404 จำนวนมากกับ path แปลก เช่น `/.env`, `/.git/config`, `/phpmyadmin` |
| SQL injection | query string มี `union select`, `' or 1=1`, `sleep(` |
| Path traversal | `../../`, `%2e%2e%2f` |
| Credential stuffing | POST login จาก IP หลายตัวแต่ user-agent เหมือนกัน |
| Content scraping | request รัว ๆ แต่ไม่โหลด css/js (bot ไม่ render) |
| Geo-block ทะลุ | มี 200 OK จาก IP ที่ควรถูกบล็อก = rule มีช่องโหว่ |

### ตัวอย่างโครง prompt
```
คุณเป็นนักวิเคราะห์ความปลอดภัย วิเคราะห์สรุป log ของเว็บ WordPress ด้านล่าง

[สรุปสถิติ 6 ชั่วโมงที่ผ่านมา]
{aggregated_stats}

ตอบกลับเป็น JSON ตามโครงนี้เท่านั้น:
{
  "threat_level": "low | medium | high | critical",
  "summary_th": "สรุปภาษาไทย 2-3 ประโยค",
  "incidents": [
    {
      "type": "brute_force | vuln_scan | sqli | scraping | other",
      "source_ips": ["..."],
      "evidence": "หลักฐานจาก log",
      "severity": 1-5,
      "recommended_action": "สิ่งที่ควรทำ"
    }
  ],
  "ips_to_block": ["..."],
  "notes_th": "ข้อสังเกตเพิ่มเติม"
}

หากไม่พบสิ่งผิดปกติ ให้ threat_level เป็น "low" และ incidents เป็น []
อย่าคาดเดาเกินกว่าหลักฐานที่มีใน log
```

### หัวข้อที่ dashboard ควรแสดง
- ไฟสถานะปัจจุบัน (เขียว/เหลือง/แดง) + เวลาสแกนล่าสุด
- กราฟจำนวน request ที่ถูกบล็อกรายชั่วโมง (24 ชม.ย้อนหลัง)
- แผนที่/ตารางประเทศต้นทางของ traffic ที่ถูกบล็อก
- ตาราง incident ที่ AI ตรวจพบ เรียงตามความรุนแรง
- รายการ IP ที่ fail2ban แบนอยู่ + ปุ่มปลดแบน
- สถานะ service (nginx/php/mariadb/firewall) และวันหมดอายุใบรับรอง
- ปริมาณใช้ CPU/RAM/disk

### ⚠️ ข้อควรระวังด้านความปลอดภัยของตัว dashboard เอง
1. **ปิดกั้นการเข้าถึง** — HTTP Basic Auth + จำกัด IP ของทีม
   (dashboard ที่เปิดสาธารณะ = บอกผู้โจมตีว่าเรารู้อะไรและไม่รู้อะไร)
2. **ปิดบัง IP บางส่วน** ถ้าจะเอาขึ้นนำเสนอ (PDPA — IP ถือเป็นข้อมูลส่วนบุคคล)
3. **อย่าให้ dashboard สั่งแบน IP ได้โดยอัตโนมัติ 100%** — ถ้า AI เข้าใจผิดแล้วแบน
   IP ของ Cloudflare หรือ Googlebot เว็บจะล่มหรือหลุดจาก Google
   → ให้ AI **เสนอ** แล้วคนกดยืนยัน
4. **อย่า hardcode API key ในโค้ด** — เก็บใน `/etc/logwatch.env` สิทธิ 600

```nginx
location /security-dashboard {
    satisfy all;                       # ต้องผ่านทั้ง 2 เงื่อนไข
    allow <ip-ของทีม>;
    deny all;
    auth_basic "Security Dashboard";
    auth_basic_user_file /etc/nginx/.htpasswd;
    # สร้างด้วย: sudo htpasswd -c /etc/nginx/.htpasswd admin
}
```

---

## งานที่ 5 — เพิ่มประสิทธิภาพอื่น ๆ

| สิ่งที่ทำ | วัดผลได้อย่างไร |
|---|---|
| **Redis object cache** (plugin: Redis Object Cache) | จำนวน query ต่อหน้าลดลง (วัดด้วย Query Monitor) |
| **PHP OPcache** (เปิด default แต่ควรปรับ `opcache.memory_consumption=256`) | เวลาประมวลผล PHP ลดลง |
| **แปลงรูปเป็น WebP/AVIF** | ขนาดหน้าเว็บลดลง 30-50% |
| **เปิด HTTP/2** (ทำไว้แล้ว) | หลายไฟล์ส่งพร้อมกันใน connection เดียว |
| **ตั้ง swap** ถ้า RAM 1GB | กัน MariaDB ถูก OOM killer ฆ่า |
| **gzip/brotli** | ขนาด HTML/CSS/JS ลดลง ~70% |

### เก็บตัวเลขเปรียบเทียบก่อน/หลัง (ใส่ในรายงาน)
```bash
# ทดสอบด้วย ab (apache2-utils) — รันจากเครื่องในไทย
ab -n 200 -c 10 https://cs-xxx.duckdns.org/

# เปรียบเทียบ:
#              requests/sec   time per request   95th percentile
#   ก่อน        _____          _____              _____
#   หลัง        _____          _____              _____
```
> ⚠️ อย่ายิง load test จำนวนมากใส่ VPS ตัวเอง — ผู้ให้บริการบางรายถือว่าเป็น
> การละเมิดข้อตกลง และถ้าอยู่หลัง Cloudflare อาจถูกมองว่าเป็น DDoS

---

## เช็คลิสต์ Stage 2

- [ ] reverse proxy ทำงาน (`X-Cache-Status: HIT` ปรากฏ)
- [ ] rate limit ทำงาน (ยิงรัว ๆ แล้วได้ 429)
- [ ] Cloudflare proxy เปิด + SSL mode = Full (strict)
- [ ] firewall อนุญาตเฉพาะ IP Cloudflare (origin ซ่อนแล้ว)
- [ ] `real_ip` ตั้งแล้ว — log เห็น IP จริงของผู้ใช้ ไม่ใช่ IP ของ Cloudflare
- [ ] fail2ban แบน IP ได้จริง (ทดสอบด้วยการใส่รหัสผิดซ้ำ)
- [ ] AI log scan รันตามเวลาผ่าน systemd timer
- [ ] dashboard แสดงผล + ป้องกันการเข้าถึงแล้ว
- [ ] มีตัวเลขเปรียบเทียบประสิทธิภาพก่อน/หลัง
