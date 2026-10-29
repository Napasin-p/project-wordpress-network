# WordPress บน VPS แบบปลอดภัย (เข้าได้เฉพาะจากไทย)

โปรเจคกลุ่มวิชาเครือข่าย ม.บูรพา: เว็บแนะนำหลักสูตรวิทยาการคอมพิวเตอร์ บน VPS ที่ติดตั้งและป้องกันเองทั้งหมดด้วยสคริปต์

- เว็บ: https://freexduk.duckdns.org
- Security Dashboard: https://freexduk.duckdns.org/security-dashboard/ (มีรหัสผ่าน)
- บันทึกคำสั่งและผลลัพธ์จริงทุกขั้น: [runbook.md](runbook.md)

| | สถานะ |
|---|---|
| Stage 1 · ด่าน 1: HTTPS + SSH แบบ key เท่านั้น | ✅ |
| Stage 1 · ด่าน 2: Firewall รับเฉพาะ IP ไทย | ✅ |
| Stage 1 · ด่าน 3: เว็บแนะนำหลักสูตร | ✅ |
| Stage 2: Reverse proxy + AI วิเคราะห์ log + Dashboard + แจ้งเตือน Discord | ✅ |

---

## สถาปัตยกรรม

```
ผู้ใช้ในไทย ──443──► Azure NSG ─► iptables + ipset (รับเฉพาะ IP ไทย · fail2ban · จำกัด SSH)
                                   │
                                   ▼
                    Nginx หน้าบ้าน  TLS · rate limit · micro-cache · CSP แบบ hash
                       ├─► 127.0.0.1:8080  Nginx origin + PHP-FPM 8.3 + MySQL 8 (WordPress)
                       └─► 127.0.0.1:8081  /security-dashboard/ (container, Basic Auth)

logwatch.timer  ทุก 6 ชม.  ─► สรุป log ─► Claude วิเคราะห์ ─► Dashboard
alert-check     ทุก 5 นาที ─► ตรวจเว็บ/บริการ/firewall/ใบรับรอง/ดิสก์ ─► Discord
```

VPS: Azure for Students · Ubuntu 24.04 LTS · Standard_B2als_v2 (2 vCPU, 4 GiB) · Malaysia West
ดู version ของทุกโปรแกรมด้วย `sudo ./scripts/99-collect-evidence.sh`

---

## สคริปต์ (รันตามลำดับ อย่าสลับขั้น)

| ลำดับ | สคริปต์ | ทำอะไร |
|---|---|---|
| 1 | `00a-update-swap.sh` | อัปเดตระบบ + swap 2 GB |
| 2 | `00b-create-admin-user.sh` | user ธรรมดา + sudo + public key (**ทดสอบ ssh ด้วย key ให้ผ่านก่อนไปขั้นต่อไป**) |
| 3 | `01-harden-ssh.sh` | ปิด root login / ปิด password / ใช้ key เท่านั้น |
| 4 | `04-duckdns.sh` | ให้โดเมนชี้มาที่ VPS + อัปเดตทุก 5 นาที |
| 5 | `02-install-lemp.sh` | Nginx + PHP-FPM + MySQL 8 |
| 6 | `03-install-wordpress.sh` | WordPress + database + vhost |
| 7 | `05-https-acme.sh` | ใบรับรอง Let's Encrypt (acme.sh แบบ DNS-01) ต่ออายุอัตโนมัติ |
| 8 | `06-firewall-th-only.sh` | iptables + ipset เฉพาะไทย (IPv4+IPv6) มี auto-rollback 5 นาที |
| 9 | `07-fail2ban.sh` | บล็อกคนเดารหัส SSH / WordPress และ bot สแกน |
| 10 | `08-site-content.sh` | theme Kadence + plugin + หน้าเว็บ + เมนู (WP-CLI) |
| 11 | `09-logwatch.sh` | AI วิเคราะห์ log ทุก 6 ชม. + Dashboard (Docker) |
| 12 | `10-reverse-proxy.sh` | Nginx หน้าบ้าน: rate limit, micro-cache, security headers |
| 13 | `11-csp-strict.sh` | Content-Security-Policy แบบ hash (`--enforce` เพื่อบังคับใช้) |
| 14 | `12-alerts.sh` | แจ้งเตือนเข้า Discord ทุก 5 นาที |
| 15 | `13-site-identity.sh` | ชื่อแท็บ "ComSci Burapha" + ไอคอนตรามหาวิทยาลัย |
| — | `99-collect-evidence.sh` | ออกรายงาน version + สถานะทั้งหมด |

> **ทำไม firewall มาทีหลัง HTTPS?** ขั้นขอใบรับรองต้องคุยกับ Let's Encrypt / DuckDNS ที่อยู่ต่างประเทศ
> (ขาออกไม่โดนบล็อก แต่ทำก่อนจะ debug ง่ายกว่า)
>
> ⚠️ สคริปต์ที่แตะ SSH หรือ firewall (`01`, `06`) ต้องเปิดหน้าต่าง ssh สำรองค้างไว้ก่อนรันเสมอ

---

## วิธีเริ่ม

### 1. สร้าง SSH key บนเครื่องตัวเอง (ทุกคนที่ต้องเข้า VPS)
```powershell
ssh-keygen -t ed25519 -f $env:USERPROFILE\.ssh\id_ed25519_vps   # ควรตั้ง passphrase
Get-Content $env:USERPROFILE\.ssh\id_ed25519_vps.pub            # public key → ใส่ใน config.env
```
private key (`id_ed25519_vps` ไม่มี .pub) ห้ามส่งให้ใครและห้ามขึ้น git

### 2. เตรียม config
```bash
cp config.env.example config.env
nano config.env          # subdomain, token DuckDNS, รหัส database, อีเมล, public key
chmod 600 config.env
```

### 3. อัปโหลดขึ้น VPS แล้วรันทีละขั้น
```bash
scp -r wordpress-vps-project <user>@<vps-ip>:~/
ssh <user>@<vps-ip>
cd ~/wordpress-vps-project && chmod -R go-rwx . && chmod +x scripts/*.sh
sudo ./scripts/00a-update-swap.sh
```
> แก้ไฟล์บน Windows แล้วรันไม่ได้ (`bad interpreter: ^M`) → `sed -i 's/\r$//' scripts/*.sh scripts/lib/*.sh`

---

## ความลับ (ไม่อยู่ใน repo)

| อะไร | อยู่ที่ |
|---|---|
| token DuckDNS · รหัส database · Claude API key | `config.env` (เครื่องเรา) · `/etc/duckdns.env` · `/etc/logwatch.env` (VPS, สิทธิ์ 600) |
| Discord webhook | `/etc/alert.env` (VPS, สิทธิ์ 600) |
| รหัสผ่าน Dashboard | `.htpasswd` บน VPS |

`.gitignore` กันไฟล์เหล่านี้ไว้แล้ว รวมถึง log และผลวิเคราะห์ของ AI (มี IP ของผู้ใช้จริง)
ถ้าเผลอ commit ความลับ ให้เปลี่ยนค่านั้นใหม่ทันที (ลบ commit อย่างเดียวไม่พอ)

---

## โครงสร้างไฟล์

```
wordpress-vps-project/
├── README.md                 ไฟล์นี้
├── runbook.md                คำสั่ง + ผลลัพธ์จริงทุกขั้น และปัญหาที่เจอ
├── config.env.example        ตัวแปรทั้งหมด (คัดลอกเป็น config.env)
├── scripts/
│   ├── lib/common.sh         ฟังก์ชันร่วม (log, require_root, โหลด config)
│   └── 00a … 13, 99          สคริปต์ตามตารางข้างบน
├── logwatch/                 Stage 2: AI วิเคราะห์ log
│   ├── logwatch.py           สรุป log + เรียก Claude
│   ├── prepare.sh            ดึง log จาก nginx / journald
│   ├── Dockerfile, docker-compose.yml
│   ├── systemd/              logwatch.service + timer ทุก 6 ชม.
│   └── dashboard/            หน้า Security Dashboard (HTML/CSS/JS + nginx.conf)
└── site/
    ├── pages/*.html          เนื้อหาหน้าเว็บ (Gutenberg block markup)
    ├── posts/*.html          ข่าวตัวอย่าง
    └── assets/               ไอคอนเว็บ (ตรามหาวิทยาลัย)
```
