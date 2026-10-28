# เอกสารที่ 4 — ด่านที่ 3: เว็บไซต์ WordPress

> โจทย์: *"สร้าง wordpress แนะนำหลักสูตรวิทยาการคอมพิวเตอร์ เพื่อโปรโมทให้นักเรียน
> ที่สนใจรับรู้ข่าวสาร ใช้ theme, plugin ตามสะดวก ให้ดูสวยงาม"*

---

## 1. ตั้งค่าเริ่มต้นหลังติดตั้ง

เปิด `https://<โดเมน>/wp-admin/install.php`

| ช่อง | ใส่อะไร | หมายเหตุ |
|---|---|---|
| Site Title | หลักสูตรวิทยาการคอมพิวเตอร์ | |
| Username | **ห้ามใช้ `admin`** | บอตเดา `admin` เป็นชื่อแรก |
| Password | ให้ WordPress สุ่มให้ | เก็บใน password manager |
| Email | อีเมลจริงของทีม | ใช้รีเซ็ตรหัสผ่าน |
| Search engine visibility | ไม่ติ๊ก | ให้ Google เก็บ index ได้ (เว็บโปรโมทต้องการคนเจอ) |

### ตั้งค่าที่ควรทำทันที

| เมนู | ตั้งอะไร | เหตุผล |
|---|---|---|
| Settings → General | timezone = `Asia/Bangkok` | วันที่โพสต์แสดงเวลาไทย |
| Settings → Permalinks | **Post name** | URL อ่านรู้เรื่อง `/curriculum/` ดีกว่า `/?p=123` และดีต่อ SEO |
| Settings → Discussion | ปิด comment | เว็บโปรโมทไม่ต้องมี comment และตัดปัญหา spam ทั้งหมด |
| Users → Profile | เปลี่ยน display name ให้ต่างจาก username | ไม่เปิดเผย username ให้คนเดา |
| Appearance → ลบ theme ที่ไม่ใช้ | | theme ที่ไม่ได้ใช้แต่ไม่อัปเดตเป็นช่องโหว่ |
| Plugins → ลบ Hello Dolly, Akismet (ถ้าไม่ใช้) | | ลดพื้นที่โจมตี |

---

## 2. โครงสร้างหน้าเว็บที่แนะนำ

```
หน้าแรก (Home)
├── Hero: ชื่อหลักสูตร + ปุ่ม "สมัครเรียน" / "ดูรายละเอียด"
├── ทำไมต้องเรียนที่นี่ (3-4 จุดขาย พร้อมไอคอน)
├── ข่าวล่าสุด (ดึง 3 โพสต์ใหม่สุดมาแสดง)
└── ปุ่มติดต่อ

เกี่ยวกับหลักสูตร
├── ปรัชญา/จุดมุ่งหมายของหลักสูตร
├── โครงสร้างหน่วยกิต (ตาราง)
├── แผนการเรียน 4 ปี (ปี 1-4 แยกเทอม)
└── คุณสมบัติผู้สมัคร + ค่าเล่าเรียน

รายวิชา
├── หมวดวิชาแกน (เช่น Data Structures, OS, Networking, Database)
├── วิชาเลือก แบ่งกลุ่มความสนใจ
│   • AI / Data Science
│   • Software Engineering
│   • Network & Security      ← อ้างอิงวิชานี้ได้เลย
└── สหกิจศึกษา / ฝึกงาน

อาชีพหลังจบ
└── ตำแหน่งงาน + ช่วงเงินเดือน + ชื่อบริษัทที่รุ่นพี่ทำงาน

คณาจารย์
└── รูป + ชื่อ + ความเชี่ยวชาญ + ผลงานวิจัย

ข่าวและกิจกรรม  ← ใช้ Post (ไม่ใช่ Page) เพราะเรียงตามวันที่
├── ประกาศรับสมัคร
├── กิจกรรมค่าย / แข่งขัน
└── ผลงานนักศึกษา

คำถามที่พบบ่อย (FAQ)

ติดต่อเรา
└── ฟอร์ม + แผนที่ + เบอร์โทร + Facebook/Line
```

### Page vs Post ต่างกันอย่างไร
- **Page** = เนื้อหาคงที่ ไม่เรียงตามเวลา (เกี่ยวกับหลักสูตร, ติดต่อเรา)
- **Post** = เนื้อหาตามเวลา มี category/tag, แสดงใหม่สุดก่อน (ข่าว, กิจกรรม)

---

## 3. Theme ที่แนะนำ

| Theme | เหมาะเพราะ |
|---|---|
| **Astra** | เบา เร็ว มี starter template สายการศึกษาให้นำเข้าได้ทันที ปรับแต่งง่าย |
| **Kadence** | ยืดหยุ่นสูง header/footer builder ดี |
| **Blocksy** | เร็ว มี option เยอะ |
| **Twenty Twenty-Four** | theme ติดมากับ WordPress ใช้ Full Site Editing ไม่ต้องลงอะไรเพิ่ม |

**แนะนำ Astra + Spectra (block builder)** — ได้งานสวยเร็วและโหลดเบา
ถ้าใช้ Elementor ระวังเว็บหนักและคะแนน PageSpeed ตก

```
Appearance → Themes → Add New → ค้นหา "Astra" → Install → Activate
→ ลง plugin "Starter Templates" → เลือก template หมวด Education → Import
```

---

## 4. Plugin ที่ควรมี

### จำเป็น
| Plugin | หน้าที่ |
|---|---|
| **Wordfence** หรือ **Solid Security** | firewall ระดับ application (L7) + สแกนมัลแวร์ + บล็อก brute-force login |
| **UpdraftPlus** | สำรองข้อมูลอัตโนมัติ (ไฟล์ + database) ส่งขึ้น Google Drive |
| **Rank Math SEO** | จัดการ meta/sitemap ให้ Google เจอเว็บ |
| **Contact Form 7** หรือ **WPForms Lite** | ฟอร์มติดต่อ/สมัครเรียน |
| **LiteSpeed Cache** หรือ **W3 Total Cache** | ทำ page cache → เว็บเร็วขึ้นหลายเท่า |

### เสริมถ้าต้องการ
| Plugin | หน้าที่ |
|---|---|
| **Smush** / **EWWW** | บีบอัดรูปอัตโนมัติ (รูปใหญ่คือสาเหตุเว็บช้าอันดับ 1) |
| **Polylang** | ทำเว็บ 2 ภาษา ไทย/อังกฤษ |
| **WP Statistics** | ดูสถิติผู้เข้าเว็บโดยไม่พึ่ง Google Analytics |
| **Two-Factor** | ยืนยันตัวตน 2 ชั้นตอน login wp-admin |

> **ข้อควรระวัง:** plugin ยิ่งมาก ยิ่งเสี่ยงและยิ่งหนัก
> **ช่องโหว่ของ WordPress ส่วนใหญ่มาจาก plugin/theme ไม่ใช่ตัว core**
> ลงเท่าที่ใช้จริง และอัปเดตสม่ำเสมอ

---

## 5. ความปลอดภัยที่ทำไว้แล้วในระดับ server

สิ่งเหล่านี้สคริปต์ตั้งไว้ให้แล้ว — **เขียนอธิบายในรายงานได้**

| มาตรการ | ตั้งที่ไหน | ป้องกันอะไร |
|---|---|---|
| `DISALLOW_FILE_EDIT` | `wp-config.php` | ถ้า admin ถูกแฮก ก็แก้ไฟล์ PHP ผ่านหน้าเว็บไม่ได้ |
| `FORCE_SSL_ADMIN` | `wp-config.php` | หน้า wp-admin ต้องผ่าน https เท่านั้น |
| บล็อก `xmlrpc.php` | nginx | ช่องทางที่ถูกใช้ brute-force และทำ DDoS มากที่สุด |
| ห้ามรัน PHP ใน `uploads/` | nginx | กันคนอัปโหลด `shell.php` ปลอมเป็นรูปแล้วเรียกใช้ |
| บล็อก `/wp-json/wp/v2/users` | nginx | WordPress เปิด API ให้ดูรายชื่อ user ได้โดย default |
| `wp-config.php` สิทธิ 640 | file system | ไฟล์นี้มีรหัส database |
| `expose_php = Off` | php.ini | ซ่อน header `X-Powered-By: PHP/8.3` |
| `server_tokens off` | nginx | ซ่อนเวอร์ชัน nginx จาก response header |
| `WP_AUTO_UPDATE_CORE = minor` | `wp-config.php` | แพตช์ความปลอดภัยติดตั้งเองอัตโนมัติ |

### ตรวจว่าซ่อนเวอร์ชันได้จริง
```bash
curl -sI https://<โดเมน> | grep -i 'server\|x-powered'
# ควรเห็นแค่: Server: nginx   (ไม่มีเลขเวอร์ชัน)
```

---

## 6. ตรวจสอบก่อนส่งงาน

### ความถูกต้อง
- [ ] ทุกเมนูคลิกได้ ไม่มีหน้า 404
- [ ] permalink เป็นชื่อหน้า ไม่ใช่ `?p=123`
- [ ] ไม่มีข้อความ Lorem ipsum หรือเนื้อหา placeholder ค้างอยู่
- [ ] ฟอร์มติดต่อส่งแล้วมีอีเมลเข้าจริง
- [ ] ไม่เหลือโพสต์ "Hello World" และหน้า "Sample Page"

### การแสดงผล
- [ ] เปิดบนมือถือแล้วไม่ล้นจอ (ทดสอบด้วย DevTools → Device Toolbar)
- [ ] รูปทุกรูปมี alt text (จำเป็นต่อ SEO และผู้ใช้ screen reader)
- [ ] favicon ไม่ใช่ไอคอน default ของ WordPress

### ประสิทธิภาพ
- [ ] https ขึ้นแม่กุญแจ ไม่มี mixed content warning (เปิด DevTools → Console)
- [ ] คะแนน PageSpeed Insights > 70 บนมือถือ
      https://pagespeed.web.dev
- [ ] รูปขนาดไม่เกิน 300KB ต่อไฟล์

### ความปลอดภัย
- [ ] username ของ admin ไม่ใช่ `admin`
- [ ] อัปเดต core/theme/plugin เป็นเวอร์ชันล่าสุด
- [ ] ตั้ง UpdraftPlus สำรองข้อมูลอัตโนมัติแล้ว
- [ ] ทดสอบ restore จาก backup ได้จริง (สำคัญ! backup ที่ restore ไม่ได้ = ไม่มี backup)

---

## 7. เครื่องมือตรวจคุณภาพ (แนบผลในรายงาน)

| เครื่องมือ | ตรวจอะไร |
|---|---|
| https://pagespeed.web.dev | ความเร็ว + Core Web Vitals |
| https://www.ssllabs.com/ssltest/ | คุณภาพการตั้งค่า TLS — **ตั้งใจให้ได้เกรด A** |
| https://securityheaders.com | security header ที่ตั้งใน nginx |
| https://validator.w3.org | HTML ถูกต้องตามมาตรฐาน |
| https://check-host.net/check-http | ใช้พิสูจน์ geo-block ของด่านที่ 2 |

> **เกร็ด:** SSL Labs จะทดสอบจากต่างประเทศ ถ้าเปิด geo-block แล้วจะทดสอบไม่ได้
> ให้ทำ SSL Labs **ก่อน** เปิด firewall แล้วเก็บผลไว้ หรือเพิ่ม IP ของ SSL Labs
> เข้า whitelist ชั่วคราว
