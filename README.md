# โปรเจคกลุ่ม: WordPress บน VPS (ปลอดภัย + จำกัดเฉพาะไทย)

ชุดสคริปต์และเอกสารสำหรับงานกลุ่มวิชาเครือข่าย/ระบบปฏิบัติการ
ส่ง **สัปดาห์สุดท้ายของเดือนตุลาคม 2026** · กลุ่ม **6-8 คน**

---

## โจทย์ที่ต้องทำ (สรุปจาก lecture note)

| ด่าน | สิ่งที่ต้องส่ง | สคริปต์/เอกสารที่เกี่ยวข้อง |
|---|---|---|
| **1** | เข้าเว็บผ่าน `https://<ชื่อ>.duckdns.org` ชี้มาที่ VPS ที่ลง WordPress | `scripts/02` – `scripts/05` |
| **1** | SSH: **ปิด root login**, **ปิด password auth**, **เปิด PKI เท่านั้น** | `scripts/00`, `scripts/01` |
| **1** | แสดงสถาปัตยกรรม + **version ของ nginx / PHP / WordPress / MySQL** | `docs/01-architecture.md`, `scripts/99` |
| **2** | Firewall บล็อกการเชื่อมต่อจากต่างประเทศ (เข้าได้เฉพาะจากไทย) | `scripts/06`, `docs/03-firewall-geoblock.md` |
| **3** | เว็บ WordPress แนะนำหลักสูตรวิทยาการคอมพิวเตอร์ ให้ดูสวยงาม | `docs/04-wordpress-content.md` |
| **Stage 2** | reverse proxy / Cloudflare cache / AI scan log → dashboard | `docs/05-stage2-roadmap.md` |

---

## ลำดับการทำงาน (สำคัญ — อย่าสลับขั้น)

```
[เครื่องตัวเอง]  สร้าง SSH key pair                → client/keygen-windows.md
       │
[VPS]  00a อัปเดตระบบ + สร้าง swap 2 GB
       │
[VPS]  00b สร้าง user ธรรมดา + ให้สิทธิ sudo + วาง public key
       │   ← ต้องทดสอบ ssh ด้วย key ให้ได้ก่อน ห้ามข้าม!
       ▼
[VPS]  01  ปิด root login / ปิด password auth / เปิด PKI
       ▼
[VPS]  04  ตั้ง DuckDNS ให้โดเมนชี้มาที่ public IP ของ VPS
       ▼
[VPS]  02  ติดตั้ง nginx + PHP-FPM + MySQL 8
       ▼
[VPS]  03  ติดตั้ง WordPress + สร้าง database
       ▼
[VPS]  05  ขอใบรับรอง HTTPS (Let's Encrypt, acme.sh DNS-01)
       ▼
[VPS]  06  ติดตั้ง firewall จำกัดเฉพาะ IP ประเทศไทย
       ▼
[VPS]  07  fail2ban
       ▼
[VPS]  08  ทำเว็บ: theme + plugin + หน้าเว็บ + เมนู
       ▼
[VPS]  99  เก็บหลักฐาน version + สถานะทั้งหมดเป็นรายงาน
```

> **ทำไม firewall ต้องท้ายสุด?** เพราะขั้น 05 ต้องคุยกับเซิร์ฟเวอร์ของ
> Let's Encrypt / DuckDNS / ipdeny ซึ่งอยู่ต่างประเทศ (ขาออกไม่โดน block แต่ทำก่อนจะ debug ง่ายกว่า)
> (รายละเอียดและวิธีให้ auto-renew ทำงานได้หลัง block อยู่ใน `docs/03`)

---

## วิธีเริ่ม

### 1. เตรียม config
```bash
cp config.env.example config.env
nano config.env          # กรอก subdomain, token, รหัส database, อีเมล
chmod 600 config.env     # ไฟล์นี้มีความลับ อย่า commit ขึ้น git
```

### 2. อัปโหลดโฟลเดอร์นี้ขึ้น VPS
```bash
# จากเครื่องตัวเอง (Windows PowerShell / Git Bash)
scp -r -i ~/.ssh/id_ed25519 wordpress-vps-project <user>@<vps-ip>:~/
```

### 3. รันทีละขั้น
```bash
cd ~/wordpress-vps-project/scripts
sudo ./02-install-lemp.sh
```

> **หมายเหตุสำหรับคนทำบน Windows:** ไฟล์ `.sh` ที่แก้ด้วย Notepad อาจติด
> CRLF แล้วรันบน Linux ไม่ได้ (error `bad interpreter: ^M`) แก้ด้วย
> `sed -i 's/\r$//' scripts/*.sh scripts/lib/*.sh`

---

## โครงสร้างไฟล์

```
wordpress-vps-project/
├── config.env.example          ตัวแปรทั้งหมดของโปรเจค (คัดลอกเป็น config.env)
├── client/
│   └── keygen-windows.md       วิธีสร้าง SSH key บน Windows
├── scripts/
│   ├── lib/common.sh           ฟังก์ชันร่วม (log, require_root, โหลด config)
│   ├── 00a-update-swap.sh      อัปเดตระบบ + swap 2 GB
│   ├── 00b-create-admin-user.sh สร้าง user + sudo + authorized_keys
│   ├── 01-harden-ssh.sh        ปิด root/password, เปิด PKI
│   ├── 02-install-lemp.sh      nginx + PHP-FPM + MySQL 8
│   ├── 03-install-wordpress.sh WordPress + database + nginx vhost
│   ├── 04-duckdns.sh           อัปเดต DNS + cron ทุก 5 นาที
│   ├── 05-https-acme.sh        Let's Encrypt ด้วย acme.sh แบบ DNS-01
│   ├── 06-firewall-th-only.sh  iptables + ipset เฉพาะไทย (IPv4+IPv6) + auto-rollback
│   ├── 07-fail2ban.sh          fail2ban: sshd + WordPress login + bot scan
│   ├── 08-site-content.sh      ด่าน 3: theme + plugin + 8 หน้า + เมนู (WP-CLI)
│   └── 99-collect-evidence.sh  ออกรายงาน version + สถานะ
├── site/
│   ├── pages/*.html            เนื้อหา 8 หน้า (Gutenberg block markup)
│   └── posts/*.html            ข่าวตัวอย่าง
├── runbook.md                  บันทึกคำสั่ง + ผลลัพธ์จริงทุกขั้น (ใช้ทำรายงาน)
└── docs/
    ├── 01-architecture.md      แผนภาพสถาปัตยกรรม + ตาราง version
    ├── 02-checkpoint-ssh.md    หลักฐานด่าน 1 (SSH hardening)
    ├── 03-firewall-geoblock.md ด่าน 2 (อธิบายหลักการ + ข้อจำกัด)
    ├── 04-wordpress-content.md ด่าน 3 (โครงเว็บ + theme/plugin)
    ├── 05-stage2-roadmap.md    Stage 2
    └── division-of-work.md     แบ่งงาน 6-8 คน
```
