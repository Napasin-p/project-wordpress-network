# เอกสารที่ 3 — ด่านที่ 2: Firewall จำกัดเฉพาะประเทศไทย

> โจทย์: *"มีการติดตั้ง firewall อะไรบ้าง เช่น iptables เพื่อ block ไม่ให้มีการต่อเข้ามาจาก
> ประเทศอื่น — กติกาเว็บที่สร้างยอมให้เชื่อมจากประเทศไทยไปที่ server ได้เท่านั้น"*

---

## 1. iptables ทำงานที่ชั้นไหน

iptables คือส่วนติดต่อผู้ใช้ของ **netfilter** ซึ่งเป็น framework ใน Linux kernel
ที่แทรกตัวอยู่ในเส้นทางเดินของ packet

```
   สายเน็ต ──► NIC ──► netfilter ──► TCP/IP stack ──► nginx
               (L1/L2)   (L3/L4)        (L4)           (L7)
                            ▲
                     ★ iptables ตัดสินที่นี่
```

**iptables ตัดสินใจจากข้อมูลใน header ของ L3 และ L4:**

| ดูอะไร | อยู่ใน header ชั้นไหน | ใช้ทำอะไรในโปรเจคนี้ |
|---|---|---|
| source IP | L3 (Network) | ★ เทียบว่าอยู่ในรายการ IP ไทยหรือไม่ |
| dest port | L4 (Transport) | แยกว่าเป็น SSH (22) หรือเว็บ (80/443) |
| TCP flags / state | L4 | ทิ้ง packet ที่สถานะผิดปกติ (port scan) |

**ข้อสังเกตสำคัญ:** iptables **มองไม่เห็นว่าผู้ใช้ขอหน้าอะไร** เพราะ URL อยู่ใน L7
และถ้าเป็น HTTPS ข้อมูล L7 ก็ถูกเข้ารหัสไว้ด้วย → การกรองระดับเนื้อหาต้องทำที่ nginx
หรือ WAF (ซึ่งเป็นงานของ Stage 2)

---

## 2. ทำไมใช้ ipset ไม่ใช่ iptables rule ธรรมดา

ประเทศไทยมี CIDR block ที่จัดสรรไว้ **มากกว่า 1,000 block**

| วิธี | จำนวน rule | การค้นหา | ผลต่อประสิทธิภาพ |
|---|---|---|---|
| iptables rule ต่อ 1 CIDR | ~1,000+ | **O(n)** เรียงทีละบรรทัดจากบนลงล่าง | ทุก packet ต้องถูกเทียบได้ถึง 1,000 ครั้ง → CPU พุ่ง |
| **ipset (hash:net)** | **1** | **O(1)** คำนวณ hash แล้วเทียบรอบเดียว | แทบไม่กินทรัพยากรเพิ่ม |

```bash
# ทั้งรายการ 1,000+ block ย่อเป็น rule บรรทัดเดียว
iptables -A GEO-CHECK -m set --match-set th-net src -j ACCEPT
```

### แหล่งข้อมูลรายการ IP ของไทย
ใช้ `https://www.ipdeny.com/ipblocks/data/aggregated/th-aggregated.zone` ซึ่งรวบรวมจาก
**APNIC** (Regional Internet Registry ที่ดูแลการจัดสรร IP ในเอเชีย-แปซิฟิก) และ
อัปเดตรายวัน — เลือกไฟล์ `aggregated` เพราะยุบ CIDR ที่ต่อเนื่องกันเข้าด้วยกันแล้ว
ทำให้จำนวนรายการน้อยลง

ตัวอย่างข้อมูลในไฟล์:
```
1.0.128.0/17
1.1.128.0/17
1.2.128.0/17
...
```
→ เป็นการใช้ **CIDR notation** ตรงตามที่เรียน: `/17` คือ network ขนาด 17 bit
เหลือ host 15 bit = 32,768 เลขหมาย

---

## 3. โครงสร้าง rule ที่ใช้

```
INPUT (policy DROP ← ปฏิเสธเป็นค่าเริ่มต้น)
 │
 ├─ 1. interface lo ────────────────────► ACCEPT   (PHP ↔ MariaDB ในเครื่อง)
 ├─ 2. state ESTABLISHED,RELATED ──────► ACCEPT   (ขาตอบของ apt/curl ที่เราเริ่มเอง)
 ├─ 3. state INVALID ──────────────────► DROP     (packet ผิดปกติ/port scan)
 ├─ 4. ICMP echo (จากไทย, จำกัด 5/วิ) ─► ACCEPT   (ให้ ping ได้แต่ไม่ให้ถล่ม)
 ├─ 5. tcp/22 ──► [IP ของทีม] ─────────► ACCEPT
 │              └ อื่น ──────────────────► LOGDROP
 ├─ 6. tcp/80,443 ──► GEO-CHECK
 │                      ├─ src ∈ th-net ► ACCEPT  ★ หัวใจของด่านที่ 2
 │                      └─ อื่น ─────────► LOGDROP
 └─ 7. ที่เหลือทั้งหมด ─────────────────► LOGDROP
```

### ทำไม policy ต้องเป็น DROP ไม่ใช่ ACCEPT
- **whitelist (default DROP)**: อนุญาตเฉพาะที่ระบุ — ถ้าลืมอะไรไป ผลคือ "เข้าไม่ได้" (ปลอดภัย)
- **blacklist (default ACCEPT)**: ปิดเฉพาะที่ระบุ — ถ้าลืมอะไรไป ผลคือ "ช่องโหว่" (อันตราย)

เช่น ถ้าวันหนึ่งมีคนเผลอติดตั้ง service ที่เปิด port 8080 — แบบ DROP จะถูกบล็อกอยู่แล้ว
โดยไม่ต้องทำอะไร

### ทำไมต้องมี rule ข้อ 2 (ESTABLISHED)
ถ้าไม่มี เมื่อ server เรียก `apt update` → request ออกไปได้ (OUTPUT ACCEPT)
แต่ **ขาตอบกลับจาก mirror ต่างประเทศจะถูก DROP** → server ใช้เน็ตไม่ได้เลย
rule นี้อาศัย **conntrack** ที่จำสถานะของแต่ละ connection ไว้ จึงแยกออกว่า
packet ไหนเป็นขาตอบของสิ่งที่เราเป็นฝ่ายเริ่ม

---

## 4. ★ ปัญหาที่ต้องรู้: IPv6 เป็นช่องเลี่ยง geo-block

ถ้าตั้ง `iptables` (IPv4) อย่างเดียวแต่ server เปิด IPv6 ไว้ด้วย
คนต่างประเทศที่มี IPv6 จะ **ทะลุเข้ามาได้เลย** เพราะ `ip6tables` เป็นชุด rule แยกกัน

```bash
# ตรวจว่าเครื่องมี IPv6 หรือไม่
ip -6 addr show
```

**วิธีแก้ในโปรเจคนี้:** ปิด inbound IPv6 ทั้งหมด (`ip6tables -P INPUT DROP`)
เพราะ DuckDNS record ของเราเป็น A record (IPv4) อยู่แล้ว ผู้ใช้จึงต่อผ่าน IPv4 เสมอ

> ต้องเปิด `ipv6-icmp` ไว้ — ต่างจาก IPv4, โปรโตคอล IPv6 **ใช้ ICMPv6 ในการทำงานพื้นฐาน**
> (Neighbor Discovery ทำหน้าที่แทน ARP) ถ้าบล็อกหมด network จะพัง

---

## 5. ★ ลำดับการติดตั้งสำคัญ: HTTPS ต้องมาก่อน firewall

```
ถ้าทำผิดลำดับ:
   06 firewall (บล็อกต่างประเทศ) ──► 05 certbot
                                        └─► ❌ FAIL
   เพราะ Let's Encrypt validation server อยู่ต่างประเทศ ต่อเข้ามาไม่ได้
```

**และปัญหาที่ร้ายกว่า:** แม้ขอใบรับรองได้ตอนแรก การ **auto-renew ทุก 90 วัน
จะล้มเหลวทั้งหมด** ถ้าใช้ HTTP-01 — เว็บจะใบรับรองหมดอายุแล้ว browser ขึ้นเตือน

### วิธีแก้: ใช้ DNS-01 challenge

| | HTTP-01 | **DNS-01 (ที่เราเลือก)** |
|---|---|---|
| ใครต่อหาใคร | LE ต่อเข้า port 80 ของเรา | **เราไปวาง TXT record บน DuckDNS** |
| ต้องเปิด port 80 ให้ต่างประเทศ | ✅ ต้อง | ❌ ไม่ต้อง |
| ใช้ร่วมกับ geo-block | ❌ พัง | ✅ ได้ |
| auto-renew หลังเปิด firewall | ❌ fail | ✅ ทำงานปกติ |

กลไก: certbot เรียก hook ของเรา → hook ยิง API ของ DuckDNS วาง TXT record
→ Let's Encrypt อ่าน DNS (ไม่ต้องแตะ server เรา) → ตรวจผ่าน → hook ลบ TXT ออก

```bash
# ตรวจว่า renew จะทำงานจริงไหม (ทำหลังเปิด firewall แล้ว)
sudo certbot renew --dry-run
```

> **หมายเหตุ:** การ **ออก** request จาก server เราไปต่างประเทศยังทำได้ปกติ
> เพราะ `OUTPUT policy = ACCEPT` — geo-block จำกัดแค่ขา **เข้า**

---

## 6. วิธีทดสอบ (หลักฐานส่งอาจารย์)

### ทดสอบที่ 1 — จากในไทย ต้องเข้าได้ ✅
เปิด `https://cs-xxx.duckdns.org` ด้วยเน็ตบ้าน/มือถือไทย → เห็นหน้าเว็บ

### ทดสอบที่ 2 — จากต่างประเทศ ต้องถูกบล็อก ✅
**วิธี ก) VPN** — เปิด VPN ไปญี่ปุ่น/สิงคโปร์ แล้วเข้าเว็บ → **timeout**
(สังเกตว่าเป็น *timeout* ไม่ใช่ *connection refused* เพราะเราใช้ `DROP` ซึ่งเงียบไปเลย
ไม่ตอบอะไรกลับ — ทำให้คนสแกนไม่รู้ว่ามีเครื่องอยู่จริง ต่างจาก `REJECT` ที่ตอบกลับว่าปฏิเสธ)

**วิธี ข) บริการเช็คฟรี (แนะนำ — ได้หลักฐานเป็นตารางสวย)**
- https://check-host.net/check-http → ใส่ URL เว็บเรา
- จะเห็น node จากหลายประเทศ: **ไทยผ่าน (200 OK) / ประเทศอื่น fail (timeout)**
- capture หน้านี้แนบในรายงาน

**วิธี ค) จาก server อื่น**
```bash
# รันจาก VPS ต่างประเทศ หรือ Google Cloud Shell
curl -v --max-time 10 https://cs-xxx.duckdns.org
# → curl: (28) Connection timed out
```

### ทดสอบที่ 3 — ดู log ว่ามีใครโดนบล็อกบ้าง
```bash
sudo journalctl -k --grep='GEOBLOCK-DROP' -n 50
```
ตัวอย่างผล:
```
kernel: GEOBLOCK-DROP IN=eth0 SRC=45.146.xx.xx DST=... PROTO=TCP SPT=51234 DPT=443
```
> **log นี้คือ input ของ Stage 2** ที่จะเอา AI มาสแกนทำ dashboard

### ทดสอบที่ 4 — นับ packet ที่ rule แต่ละข้อจับได้
```bash
sudo iptables -L -n -v --line-numbers
```
คอลัมน์ `pkts`/`bytes` บอกว่า rule นั้นทำงานจริง — ถ้า LOGDROP มีเลขขึ้นเรื่อย ๆ
แปลว่ามีคนพยายามต่อเข้ามาจากต่างประเทศจริง

---

## 7. ข้อจำกัดของ geo-block ที่ต้องยอมรับ (เขียนในรายงานจะได้คะแนน)

| ข้อจำกัด | อธิบาย |
|---|---|
| **VPN/Proxy เลี่ยงได้** | คนต่างประเทศเช่า VPS ในไทยแล้วต่อผ่าน → source IP เป็นไทย ผ่านได้ |
| **ฐานข้อมูลไม่แม่น 100%** | IP ถูกซื้อขาย/ย้ายภูมิภาคได้ รายการจึงล้าหลังความจริงเล็กน้อย |
| **คนไทยในต่างประเทศเข้าไม่ได้** | เป็นผลข้างเคียงที่หลีกเลี่ยงไม่ได้ของการกรองตามภูมิศาสตร์ |
| **Mobile carrier ใช้ CGNAT** | บางเครือข่ายมือถือ NAT ออกด้วย IP ที่จด registry ต่างประเทศ → คนไทยอาจโดนบล็อกผิดพลาด |
| **บล็อกได้แค่ชั้น IP** | ถ้าผู้โจมตีอยู่ในไทย firewall นี้ช่วยไม่ได้เลย ต้องพึ่ง WAF/rate limit (Stage 2) |

**สรุป:** geo-block เป็นการ **ลดพื้นที่ถูกโจมตี** ไม่ใช่กำแพงกันได้สมบูรณ์
ยังต้องมีชั้นป้องกันอื่นประกอบ (defense in depth)

---

## 8. คำสั่งที่ใช้บ่อย

```bash
# ดูสถานะทั้งหมด
sudo ./scripts/06-firewall-th-only.sh --status

# อัปเดตรายการ IP ไทย (ทำอัตโนมัติทุกวันอยู่แล้ว)
sudo ./scripts/06-firewall-th-only.sh --refresh

# ฉุกเฉิน: ล้าง firewall ทั้งหมด
sudo ./scripts/06-firewall-th-only.sh --rollback

# เช็คว่า IP นี้อยู่ในรายการไทยไหม
sudo ipset test th-net 1.2.3.4

# เพิ่ม IP เฉพาะกิจเข้า whitelist (เช่น อาจารย์ขอดูจากต่างประเทศ)
sudo iptables -I INPUT 6 -s <ip> -p tcp -m multiport --dports 80,443 -j ACCEPT
sudo netfilter-persistent save   # บันทึกให้คงอยู่หลัง reboot

# ตรวจว่า rule ยังอยู่หลัง reboot
sudo reboot && sudo iptables -L -n | head
```

### ⚠️ ข้อควรระวัง: iptables ไม่ถาวรโดยตัวเอง
rule ของ iptables อยู่ใน memory — **หายหมดเมื่อ reboot**
เราจึงใช้ `netfilter-persistent` ซึ่งเก็บ rule ไว้ที่ `/etc/iptables/rules.v4`
และ ipset ที่ `/etc/iptables/ipsets` แล้วโหลดกลับตอนบูต
**ต้องรัน `--confirm` หรือ `netfilter-persistent save` ทุกครั้งที่แก้ rule**
