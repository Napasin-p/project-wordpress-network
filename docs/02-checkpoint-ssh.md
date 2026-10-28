# เอกสารที่ 2 — Checkpoint ด่านที่ 1: ความปลอดภัยของ SSH

> โจทย์: *"การต่อเข้า VPS ต่อด้วย ssh ที่ปิด root, ปิด password authen, เปิด PKI เท่านั้นหรือไม่"*

---

## 1. สรุปสิ่งที่ทำ

| ข้อกำหนด | คำสั่งที่ตั้ง | ไฟล์ |
|---|---|---|
| ปิด root login | `PermitRootLogin no` | `/etc/ssh/sshd_config.d/99-hardening.conf` |
| ปิด password authentication | `PasswordAuthentication no`<br>`KbdInteractiveAuthentication no` | เดียวกัน |
| เปิด PKI เท่านั้น | `PubkeyAuthentication yes`<br>`AuthenticationMethods publickey` | เดียวกัน |

**ทำไมใช้ drop-in ใน `sshd_config.d/` ไม่แก้ `sshd_config` ตรง ๆ?**
- ย้อนกลับง่าย — ลบไฟล์เดียวจบ
- `apt upgrade` ของ openssh-server ไม่มาเขียนทับการตั้งค่าของเรา
- เห็นชัดว่าอะไรเป็นค่าที่ "เราตั้งเอง" แยกจากค่า default ของระบบ

**ทำไมต้องมี 4 คำสั่งไม่ใช่แค่ `PasswordAuthentication no`?**
เพราะถ้าปิดแค่ตัวนั้น SSH ยังเหลือช่องทาง **keyboard-interactive** ที่ผ่าน PAM
ซึ่งสุดท้ายก็ถามรหัสผ่านอยู่ดี — ต้องปิด `KbdInteractiveAuthentication` ด้วย
และ `AuthenticationMethods publickey` คือการประกาศชัดว่า **ยอมรับได้วิธีเดียว**

---

## 2. หลักฐานที่ต้องเก็บ (ทำ screenshot ทั้ง 4 ข้อ)

### ข้อ 1 — ค่าที่ sshd ใช้งานจริง

ไม่ใช่แค่ `cat` ไฟล์ config (ไฟล์อาจมีค่าซ้ำซ้อน/ถูก override)
ต้องใช้ `sshd -T` ซึ่งแสดง **ค่าผลลัพธ์สุดท้ายที่ sshd ใช้จริง**:

```bash
sudo sshd -T | grep -Ei 'permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractive|authenticationmethods'
```

ผลที่ต้องได้:
```
permitrootlogin no
passwordauthentication no
kbdinteractiveauthentication no
pubkeyauthentication yes
authenticationmethods publickey
```

### ข้อ 2 — เข้าด้วย key สำเร็จ ✅

```bash
ssh -i ~/.ssh/id_ed25519_vps sysadmin@cs-xxx.duckdns.org
```
ผล: login ได้ (อาจถาม passphrase ของ key ซึ่งถือว่าปกติ)

เพิ่ม `-v` เพื่อเก็บหลักฐานว่าใช้ publickey จริง:
```bash
ssh -v -i ~/.ssh/id_ed25519_vps sysadmin@cs-xxx.duckdns.org 2>&1 | grep -i 'authentications\|Authenticated'
```
ต้องเห็น: `Authenticated to ... using "publickey"`

### ข้อ 3 — เข้าด้วยรหัสผ่าน ถูกปฏิเสธ ✅

```bash
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive \
    sysadmin@cs-xxx.duckdns.org
```
ผลที่ต้องได้:
```
sysadmin@cs-xxx.duckdns.org: Permission denied (publickey).
```
สังเกตว่า **ไม่มีการถามรหัสผ่านเลย** — server บอกตรง ๆ ว่ารับแค่ publickey

### ข้อ 4 — เข้าด้วย root ถูกปฏิเสธ ✅

```bash
ssh root@cs-xxx.duckdns.org
```
ผล: `Permission denied (publickey).`

**ตรวจจากฝั่ง server ว่าถูกปฏิเสธด้วยเหตุผลอะไร:**
```bash
sudo journalctl -u ssh -n 30 | grep -i 'root\|denied'
```

---

## 3. การมอบสิทธิ sudo (ตามที่เรียน)

> *"สมมติในเครื่อง vps เราสร้างบัญชี pooh ในฐานะ user ธรรมดา แต่ root ต้องมอบสิทธิ
> sudo ให้กับ pooh เพื่อ pooh จะสามารถรันคำสั่งในฐานะ root ได้"*

```bash
# ตรวจว่า user อยู่ในกลุ่ม sudo
id sysadmin
# uid=1000(sysadmin) gid=1000(sysadmin) groups=1000(sysadmin),27(sudo)
#                                                              ^^^^^^^

# ทดสอบยกสิทธิ
sudo whoami      # → root
```

**แนวคิดสำคัญ:** การปิด root login ไม่ได้ทำให้เราทำงานระดับ root ไม่ได้
เพียงแต่บังคับให้ต้อง **ระบุตัวตนในฐานะบุคคลก่อน** แล้วจึงยกสิทธิ
→ ได้ **audit trail** ว่าใครรันคำสั่งอะไร (`/var/log/auth.log`) ซึ่ง login
ด้วย root ตรง ๆ จะไม่รู้เลยว่าเป็นใครในทีม

```bash
# ดูว่าใครใช้ sudo ทำอะไรไปบ้าง
sudo grep sudo /var/log/auth.log | tail -20
```

---

## 4. สิทธิไฟล์ที่เกี่ยวข้อง (ทบทวน chmod)

```bash
ls -la ~/.ssh/
```
| ไฟล์/โฟลเดอร์ | สิทธิที่ต้องเป็น | เลข | เหตุผล |
|---|---|---|---|
| `~/.ssh/` | `drwx------` | 700 | คนอื่นห้ามแม้แต่ดูว่ามีไฟล์อะไร |
| `authorized_keys` | `-rw-------` | 600 | ถ้าคนอื่นเขียนได้ = เอา key ตัวเองใส่แล้วเข้า server ได้ |
| private key (บนเครื่องเรา) | `-rw-------` | 600 | ssh จะปฏิเสธถ้าเปิดกว้างกว่านี้ |

```
600 = rw- --- ---        700 = rwx --- ---
      110 000 000              111 000 000
       6   0   0                7   0   0
      u    g   o           (user/group/other)
```

**ssh ตรวจเรื่องนี้จริง** — ถ้าสิทธิผิดจะขึ้น error และไม่ยอมใช้ key:
```
Permissions 0644 for 'id_ed25519' are too open.
```

---

## 5. ความปลอดภัยที่เพิ่มเติมจากโจทย์

| การตั้งค่า | ป้องกันอะไร |
|---|---|
| `AllowUsers sysadmin` | แม้มี user อื่นในเครื่อง (เช่น `www-data`) ก็ ssh เข้าไม่ได้ |
| `MaxAuthTries 3` | จำกัดจำนวนครั้งที่ลอง auth ต่อ 1 connection |
| `LoginGraceTime 30` | ตัดการเชื่อมต่อที่เปิดค้างไว้ไม่ยอม auth (กินทรัพยากร) |
| `AllowTcpForwarding no` | กันใช้ server เราเป็นสะพานทะลุเข้าเครือข่ายอื่น |
| `X11Forwarding no` | server ไม่มี GUI อยู่แล้ว ปิดไปลดพื้นที่โจมตี |
| `KexAlgorithms curve25519-sha256` | ตัดอัลกอริทึมเก่าที่มีช่องโหว่ออก |
| iptables จำกัด SSH (ด่านที่ 2) | ป้องกันในชั้น network ก่อนถึง sshd |

### ตรวจว่ามีคนพยายามเจาะเข้ามาแค่ไหน
```bash
# จำนวนครั้งที่ล้มเหลว แยกตาม IP
sudo grep 'Failed\|Invalid user' /var/log/auth.log | grep -oP 'from \K[0-9.]+' | sort | uniq -c | sort -rn | head
```
> เลขนี้มักน่าตกใจ — บอตสแกน port 22 ทั่วอินเทอร์เน็ตตลอดเวลา
> **และนี่คือหลักฐานว่าทำไมต้องปิด password auth** ถ้าเปิดไว้และรหัสผ่านอ่อน
> มีโอกาสถูกเจาะได้จริงภายในไม่กี่วัน

---

## 6. ตารางสรุปสำหรับนำเสนอ

| # | ข้อกำหนด | หลักฐาน | สถานะ |
|---|---|---|---|
| 1 | ปิด root login | `sshd -T \| grep permitrootlogin` → `no` + screenshot ข้อ 4 | ☐ |
| 2 | ปิด password authentication | `sshd -T` → `no` + screenshot ข้อ 3 | ☐ |
| 3 | เปิด PKI เท่านั้น | `AuthenticationMethods publickey` + screenshot ข้อ 2 | ☐ |
| 4 | user ธรรมดามีสิทธิ sudo | `id sysadmin` เห็นกลุ่ม sudo | ☐ |
