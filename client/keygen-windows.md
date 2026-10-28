# สร้าง SSH Key Pair บนเครื่องตัวเอง (Windows)

ขั้นนี้ทำบน **เครื่องของเรา** ไม่ใช่บน VPS — เพราะ **private key ต้องไม่ออกจากเครื่องเรา**
สมาชิกทุกคนในกลุ่มที่ต้องการ ssh เข้า VPS ต้องทำขั้นนี้ของตัวเอง

---

## 1. สร้างคู่กุญแจ

เปิด PowerShell แล้วรัน (`ed25519` สั้นและปลอดภัยกว่า RSA):

```powershell
ssh-keygen -t ed25519 -C "pooh@laptop" -f $env:USERPROFILE\.ssh\id_ed25519_vps
```

- ถาม **passphrase** → ควรตั้ง เป็นชั้นป้องกันกรณีไฟล์ private key หลุด
  (ถ้าไม่ตั้งก็ใช้ได้ แต่ใครได้ไฟล์ไปก็เข้า server ได้ทันที)
- ได้ไฟล์ 2 ไฟล์
  | ไฟล์ | คือ | เก็บไว้ที่ |
  |---|---|---|
  | `id_ed25519_vps` | **Private key** — ความลับ ห้ามส่งให้ใคร | เครื่องเราเท่านั้น |
  | `id_ed25519_vps.pub` | **Public key** — แจกได้ | ไปวางบน VPS |

> นี่คือหลักการ **PKI** ตรงตามที่อาจารย์สอน: public key เหมือนตู้รับจดหมาย
> ใครก็หย่อนได้ / private key คือกุญแจไขตู้ มีเจ้าของคนเดียว

---

## 2. ดู public key เพื่อเอาไปใส่ config.env

```powershell
Get-Content $env:USERPROFILE\.ssh\id_ed25519_vps.pub
```

ได้ข้อความ 1 บรรทัดหน้าตาแบบนี้ → คัดลอกไปใส่ `SSH_PUBLIC_KEYS` ใน `config.env`

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... pooh@laptop
```

---

## 3. ตั้งสิทธิไฟล์ private key

บน Linux/macOS คือ:
```bash
chmod 600 ~/.ssh/id_ed25519_vps
```

ความหมายของเลข (ตามที่เรียน `chmod` = change mode):

```
600 = rw- --- ---      644 = rw- r-- r--      777 = rwx rwx rwx
      110 000 000            110 100 100            u   g   o
       6   0   0              6   4   4           (owner/group/other)
```

`600` = เจ้าของอ่านเขียนได้ คนอื่นแตะไม่ได้เลย — ssh จะ **ปฏิเสธ** private key
ที่สิทธิเปิดกว้างกว่านี้

บน Windows ไฟล์ใน `%USERPROFILE%\.ssh` ได้สิทธิที่เหมาะสมอยู่แล้ว แต่ถ้าเจอ
error `UNPROTECTED PRIVATE KEY FILE` ให้รัน:

```powershell
icacls $env:USERPROFILE\.ssh\id_ed25519_vps /inheritance:r /grant:r "$($env:USERNAME):(R)"
```

---

## 4. ทดสอบเข้า VPS

```powershell
ssh -i $env:USERPROFILE\.ssh\id_ed25519_vps sysadmin@<public-ip-ของ-vps>
```

### ตั้ง alias ให้พิมพ์สั้นลง
สร้าง/แก้ไฟล์ `%USERPROFILE%\.ssh\config`:

```
Host csvps
    HostName cs-buu.duckdns.org
    User sysadmin
    IdentityFile ~/.ssh/id_ed25519_vps
    IdentitiesOnly yes
```

จากนั้นเข้าได้ด้วย `ssh csvps`

---

## ⚠️ เช็คลิสต์ก่อนไปขั้นถัดไป

- [ ] `ssh -i <private key> <user>@<ip>` เข้าได้โดย **ไม่ถูกถามรหัสผ่านของ user**
      (ถ้าถาม passphrase ของ key ถือว่าปกติ)
- [ ] สมาชิกทุกคนที่ต้องเข้า server ใส่ public key ไว้แล้ว

**ต้องผ่านทั้ง 2 ข้อก่อนรัน `01-harden-ssh.sh`** ไม่งั้นจะล็อกตัวเองออกจาก
server และต้องไปงม console ของผู้ให้บริการ VPS เพื่อแก้
