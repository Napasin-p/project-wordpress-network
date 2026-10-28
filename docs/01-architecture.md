# เอกสารที่ 1 — สถาปัตยกรรมระบบ

> ตอบโจทย์ด่านที่ 1: *"แสดงโครงสร้างของสถาปัตยกรรมที่ทำพร้อม version ของโปรแกรมแต่ละตัว"*
> ตาราง version จริงให้ใช้ output จาก `sudo ./scripts/99-collect-evidence.sh report.md`

---

## 1. ภาพรวมระบบ

```
   ผู้ใช้ (browser)
        │ ① ถามชื่อ  <SUBDOMAIN>.duckdns.org
        ▼
  ┌────────────────────────────┐
  │  DuckDNS (DNS)             │   A record → public IP ของ VM
  │  อัปเดตโดย cron ทุก 5 นาที  │   TXT record ← acme.sh (DNS-01)
  └────────────┬───────────────┘
               │ ② ได้ IP กลับมา → ต่อ TCP 443
               ▼
  ┌────────────────────────────┐
  │  Azure NSG                 │   firewall ชั้นนอก (ระดับ cloud)
  │  inbound: 22, 80, 443      │   port อื่นถูกทิ้งก่อนถึง VM
  └────────────┬───────────────┘
               ▼
  ╔══════════════════ VM: Ubuntu 24.04 LTS (Azure, Malaysia West) ════════╗
  ║                                                                        ║
  ║  ③ iptables + ipset (+ fail2ban)        ◄── ด่านที่ 2                  ║
  ║     INPUT policy = DROP                                                ║
  ║     22/80/443 อนุญาตเฉพาะ src IP ใน ipset "th-net" (IP ประเทศไทย)       ║
  ║                    │ ผ่านด่าน                                           ║
  ║                    ▼                                                    ║
  ║  ④ nginx (port 443, server_tokens off)                                 ║
  ║     • ถอดรหัส TLS ด้วยใบรับรอง Let's Encrypt                           ║
  ║     • เสิร์ฟไฟล์ static (รูป/css/js) เอง เร็วกว่าให้ PHP ทำ             ║
  ║     • redirect 80 → 443 ทั้งหมด                                         ║
  ║                    │ ถ้าเป็น .php ส่งต่อ (FastCGI, unix socket)         ║
  ║                    ▼                                                    ║
  ║  ⑤ PHP-FPM  /run/php/php8.x-fpm.sock (expose_php = Off)                ║
  ║     • รันโค้ด WordPress                                                 ║
  ║                    │ unix socket /var/run/mysqld/mysqld.sock            ║
  ║                    ▼   (DB_HOST=localhost → PHP ใช้ socket ไม่ใช่ TCP)   ║
  ║  ⑥ MySQL 8                                                             ║
  ║     • bind-address = 127.0.0.1 (ไม่เปิดออกอินเทอร์เน็ต)                  ║
  ║     • database แยก + user แยกสำหรับ WordPress (ไม่ใช้ root)              ║
  ║                                                                         ║
  ║  ──── งานเบื้องหลัง ────                                                ║
  ║  /etc/cron.d/duckdns     อัปเดต A record ทุก 5 นาที                     ║
  ║  crontab ของ root        acme.sh ต่ออายุใบรับรอง (DNS-01) วันละครั้ง     ║
  ║  /etc/cron.d/th-ipset    อัปเดตรายการ IP ไทยสัปดาห์ละครั้ง               ║
  ╚═════════════════════════════════════════════════════════════════════════╝
```

---

## 2. เหตุผลในการเลือกแต่ละองค์ประกอบ

| เลือก | ทางเลือกอื่น | เหตุผล |
|---|---|---|
| **nginx** | Apache | กินหน่วยความจำน้อยกว่าบน VPS ที่ RAM จำกัด (event-driven แทน process-per-request) และตั้งเป็น reverse proxy ใน Stage 2 ง่าย |
| **PHP-FPM** | mod_php | nginx ไม่มี module รัน PHP ในตัว ต้องแยก process pool คุยผ่าน FastCGI |
| **unix socket** | TCP 127.0.0.1:9000 | เร็วกว่าเพราะไม่ต้องผ่าน network stack และปิดช่องให้คนต่อเข้า PHP-FPM ตรง |
| **MySQL 8** | MariaDB | โจทย์กำหนด และเป็น DBMS ที่ WordPress รองรับเป็นหลัก (Ubuntu 24.04 มี mysql-server 8.0 ใน repo)|
| **DNS-01 (acme.sh + dns_duckdns)** | HTTP-01 (certbot) | HTTP-01 ต้องให้เซิร์ฟเวอร์ Let's Encrypt (ต่างประเทศ) ต่อเข้ามาที่ port 80 → ชนกับ geo-block ของด่านที่ 2 |
| **ipset** | iptables rule ทีละบรรทัด | ไทยมี CIDR กว่า 1,000 block ถ้าเขียนเป็น rule ต้องเช็คเรียงทีละบรรทัด (O(n)) ส่วน ipset ใช้ hash ค้นหารอบเดียว (O(1)) |

---

## 3. การเดินทางของข้อมูลเทียบกับ OSI Layer

เชื่อมโยงกับที่เรียนในคลาส — เมื่อผู้ใช้พิมพ์ `https://cs-xxx.duckdns.org`:

| Layer | เกิดอะไรขึ้น | ข้อมูลเรียกว่า |
|---|---|---|
| **7 Application** | browser สร้าง HTTP request `GET / HTTP/1.1` | message |
| **6 Presentation** | TLS เข้ารหัสข้อมูล (encryption) | — |
| **5 Session** | เปิด/จัดการ session ของการเชื่อมต่อ | — |
| **4 Transport** | TCP ใส่ **port** (ต้นทางสุ่ม → ปลายทาง 443), รับประกันความถูกต้องและลำดับ (reliable, connection-oriented) | **segment** |
| **3 Network** | IP ใส่ **source IP / dest IP**, router หาเส้นทาง | **packet** = h3 + segment |
| **2 Data Link** | ใส่ **source/dest MAC**, เช็คความถูกต้องด้วย CRC32 (error control + flow control) | **frame** = h2 + packet + t2 |
| **1 Physical** | ส่งเป็นสัญญาณไฟฟ้า/แสงไปตามสาย | bit |

### จุดที่เครื่องเราเข้ามาเกี่ยวข้อง
- เครื่องผู้ใช้เอา IP ปลายทาง AND กับ subnet mask ของตัวเอง เทียบกับ network address ของตัวเอง
  → ได้ผลว่า **คนละเครือข่าย** จึงต้องส่งไปหา **default gateway**
- ต้องสร้าง frame ไปที่ MAC ของ default gateway → ไม่รู้ MAC ก็ดู **ARP table** ถ้าไม่มีก็ **ARP broadcast**
- packet เดินทางข้าม router ไปเรื่อย ๆ โดย **IP ต้นทาง/ปลายทางไม่เปลี่ยน แต่ MAC เปลี่ยนทุก hop**
  (เพราะ L2 คุมแค่ node-to-node ส่วน L3 คุม host-to-host)
- ถึง VPS → **iptables ทำงานที่ L3/L4** (ดู source IP + port) → ส่งขึ้น L7 ให้ nginx

### จุดที่ NAT เข้ามาเกี่ยว
ผู้ใช้ที่บ้านใช้ **private IP** (เช่น `192.168.1.x`) ซึ่งออกเน็ตตรงไม่ได้
router บ้านทำ **NAT** แปลงเป็น public IP ของ ISP ก่อน
→ **IP ที่ firewall ของเราเห็นคือ public IP ของ ISP ไม่ใช่ IP ในบ้าน**
นี่คือเหตุผลที่ geo-block แบบดู source IP ใช้งานได้จริง

---

## 4. ตาราง version (กรอกจาก output ของสคริปต์ 99)

| ชั้น | ซอฟต์แวร์ | เวอร์ชัน |
|---|---|---|
| OS | Ubuntu | `_____` |
| Web server | nginx | `_____` |
| Runtime | PHP-FPM | `_____` |
| Database | MySQL | `_____` |
| CMS | WordPress | `_____` |
| TLS | OpenSSL | `_____` |
| ACME client | acme.sh | `_____` |

**คำสั่งที่ใช้ตรวจแต่ละตัว** (ใส่ screenshot ประกอบในรายงาน):
```bash
nginx -v
php -v
mysql --version
lsb_release -a
sudo -u www-data wp core version --path=/var/www/<SUBDOMAIN>
openssl version
sudo /root/.acme.sh/acme.sh --version
```

---

## 5. ข้อมูล VPS ที่ใช้

| รายการ | ค่า |
|---|---|
| ผู้ให้บริการ | Azure for Students |
| ภูมิภาค | Malaysia West (Kuala Lumpur) |
| vCPU / RAM / Disk | `_____` |
| Public IP | `_____` |
| ค่าบริการต่อเดือน | `_____` |
