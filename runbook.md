# Runbook — WordPress บน VPS แบบปลอดภัย

บันทึกคำสั่งทุกขั้นที่รันจริง + ผลลัพธ์ สำหรับใช้ทำรายงาน
ส่ง Stage 1: สัปดาห์สุดท้ายของ ต.ค. 2026

| รายการ | ค่า |
|---|---|
| VPS | Azure for Students · Ubuntu 24.04 LTS · Malaysia West (Kuala Lumpur) — subscription นักศึกษาถูก policy จำกัดให้ใช้ได้แค่ malaysiawest, japaneast, japanwest, indonesiacentral, uaenorth |
| VM size | Standard_B2als_v2 (2 vCPU, 4 GiB RAM) — เลือกแทน B2ats_v2 (1 GiB) เพราะ MySQL 8 + PHP-FPM + Stage 2 ไม่พอ ปรับลดได้หลังส่งงาน |
| Public IP | `172.197.162.225` |
| โดเมน | `freexduk.duckdns.org` |
| Admin user | `sysadmin` (ไม่ใช่ root) |
| Stack | Nginx + PHP-FPM + MySQL 8 + WordPress |

> ตัวที่อยู่ใน `<...>` ให้แทนด้วยค่าจริงตอนรัน · **ห้ามจดรหัสผ่าน/token ลงไฟล์นี้**
> สัญลักษณ์: 💻 = รันบนเครื่องตัวเอง (Windows) · 🖥️ = รันบน VPS

---

## ด่านที่ 0 — เตรียมเครื่องตัวเอง

### 0.1 💻 ตั้ง SSH config (เข้าเครื่องได้ด้วยคำสั่ง `ssh wp-vps`)
ไฟล์ `C:\Users\<you>\.ssh\config`
```
Host wp-vps
    HostName <VPS_IP>
    User <ADMIN_USER>
    IdentityFile ~/.ssh/id_ed25519_vps
    IdentitiesOnly yes
```
`IdentitiesOnly yes` จำเป็น เพราะสคริปต์ตั้ง `MaxAuthTries 3` ไว้ ถ้า ssh ลองหลาย key จะโดนตัดก่อนถึง key ที่ถูก

### 0.2 💻 อัปโหลดโปรเจคขึ้น VPS
private key มี passphrase → ใส่เข้า ssh-agent ครั้งเดียว (PowerShell)
```powershell
# (Admin) เปิด service ครั้งแรก
Get-Service ssh-agent | Set-Service -StartupType Automatic; Start-Service ssh-agent
# (ปกติ) ใส่ key — พิมพ์ passphrase เอง
ssh-add $env:USERPROFILE\.ssh\id_ed25519_vps
ssh wp-vps
```
```bash
scp -r E:/wordpress-vps-project wp-vps:~/
ssh wp-vps 'chmod -R go-rwx ~/wordpress-vps-project && chmod 600 ~/wordpress-vps-project/config.env && chmod +x ~/wordpress-vps-project/scripts/*.sh'
```
⚠️ scp จาก Windows ตั้งสิทธิ์โฟลเดอร์เป็น `drwx---rwx` (user อื่นแก้สคริปต์ที่รันด้วย sudo ได้) → ต้อง `chmod -R go-rwx`

**ผลลัพธ์ (10 ต.ค. 2026):** เข้า `sysadmin@wp-vps` ได้ด้วย key · สภาพเครื่องตอนสร้างเสร็จ:
```
Ubuntu 24.04.4 LTS · kernel 6.17.0-1022-azure · 2 vCPU · RAM 3.8Gi · disk 29G
groups=sysadmin,adm,cdrom,sudo,dip,lxd   (sudo NOPASSWD จาก cloud-init: /etc/sudoers.d/90-cloud-init-users)
/etc/ssh/sshd_config.d/: 50-cloud-init.conf, 50-cloudimg-settings.conf, 60-cloudimg-settings.conf
sshd -T: permitrootlogin without-password | passwordauthentication no | kbdinteractiveauthentication no | pubkeyauthentication yes
authorized_keys: 1 key · ~/.ssh 700 · authorized_keys 600
IPv6 global: ไม่มี · swap: ไม่มี (waagent ResourceDisk.EnableSwap=n)
```

---

## ด่านที่ 1 — เซิร์ฟเวอร์ + HTTPS + SSH ปลอดภัย

### 1.1 🖥️ อัปเดตระบบ + swap 2 GB — `00a-update-swap.sh`
```bash
cd ~/wordpress-vps-project/scripts
sudo ./00a-update-swap.sh
# ถ้าขึ้นว่าต้อง reboot:
sudo reboot
```
คำสั่งหลักในสคริปต์:
```bash
sudo apt-get update && sudo apt-get -y full-upgrade
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
echo 'vm.swappiness = 10' | sudo tee /etc/sysctl.d/99-swap.conf
```
ตรวจ: `free -h` · `swapon --show`

**ผลลัพธ์ (10 ต.ค. 2026):** full-upgrade ลง kernel ใหม่ → reboot แล้ว
```
$ uname -r
7.0.0-1017-azure
$ free -h
               total        used        free      shared  buff/cache   available
Mem:           3.8Gi       528Mi       3.2Gi       3.9Mi       255Mi       3.3Gi
Swap:          2.0Gi          0B       2.0Gi
$ swapon --show
NAME      TYPE SIZE USED PRIO
/swapfile file   2G   0B   -1
$ cat /proc/sys/vm/swappiness
10
$ grep swapfile /etc/fstab
/swapfile none swap sw 0 0
```

### 1.2 🖥️ user + sudo + public key ของสมาชิก — `00b-create-admin-user.sh`
บน Azure: `<ADMIN_USER>` ถูกสร้างตอนสร้าง VM พร้อม key ของคนสร้าง (และ sudo) แล้ว
สคริปต์นี้จะเพิ่ม key ของสมาชิกที่เหลือจาก `SSH_PUBLIC_KEYS` ใน config.env
```bash
sudo ./00b-create-admin-user.sh
```
คำสั่งหลัก:
```bash
sudo usermod -aG sudo <ADMIN_USER>
sudo install -d -m 700 -o <ADMIN_USER> -g <ADMIN_USER> /home/<ADMIN_USER>/.ssh
# เพิ่ม key ทีละบรรทัดลง authorized_keys
sudo chmod 600 /home/<ADMIN_USER>/.ssh/authorized_keys
```
ตรวจ: `ls -la ~/.ssh` · `wc -l ~/.ssh/authorized_keys` · `sudo whoami` → `root`
⚠️ ให้สมาชิกทุกคนลอง ssh ด้วย key ตัวเองให้ผ่านก่อนไปข้อ 1.3

**ผลลัพธ์:**
```
(วางผลลัพธ์)
```

### 1.3 🖥️ SSH hardening — `01-harden-ssh.sh`  ⚠️ ต้องถามก่อนรัน
```bash
sudo ./01-harden-ssh.sh
```
สิ่งที่สคริปต์ทำ:
1. comment ค่าที่ชนกันใน `/etc/ssh/sshd_config.d/*.conf` (เช่น `50-cloudimg-settings.conf` ของ Azure)
2. แก้ `/etc/ssh/sshd_config`: `PermitRootLogin no`, `PasswordAuthentication no`,
   `KbdInteractiveAuthentication no`, `PubkeyAuthentication yes`
3. เขียน `/etc/ssh/sshd_config.d/00-hardening.conf` (ชื่อขึ้นต้น `00-` เพราะ sshd ใช้ค่าแรกที่เจอ)
4. `sshd -t` ตรวจไวยากรณ์ → `systemctl reload ssh`

ตรวจก่อน/หลัง:
```bash
grep -rnE 'PermitRoot|Password|KbdInteractive|Pubkey' /etc/ssh/sshd_config.d/
sudo sshd -T | grep -E 'permitroot|password|pubkey'
```
💻 ทดสอบจาก **หน้าต่างใหม่** (ห้ามปิดหน้าต่างเดิมจนกว่าข้อ 1 จะผ่าน):
```bash
ssh wp-vps                                          # 1) ต้องเข้าได้
ssh -o PubkeyAuthentication=no <ADMIN_USER>@<VPS_IP>  # 2) ต้องขึ้น Permission denied (publickey)
ssh root@<VPS_IP>                                    # 3) ต้องถูกปฏิเสธ
```
ถ้าพลาด: Azure Portal → VM → Serial console → `sudo ./01-harden-ssh.sh --rollback`

**ผลลัพธ์ (10 ต.ค. 2026):** ✅ ผ่าน · สคริปต์ comment `PasswordAuthentication` ใน `50-cloud-init.conf` และ `60-cloudimg-settings.conf` (สำรองเป็น `.bak.20261010-163127`)
```
$ sudo sshd -T | grep -E 'permitroot|password|pubkey'
permitrootlogin no                    ← ก่อนแก้: without-password
pubkeyauthentication yes
passwordauthentication no
permitemptypasswords no
$ sudo sshd -T | grep -E '^(allowusers|maxauthtries|authenticationmethods)'
maxauthtries 3
allowusers sysadmin
authenticationmethods publickey

# 💻 ทดสอบจาก session ใหม่
$ ssh wp-vps 'whoami'                                   → sysadmin            ✅ เข้าได้
$ ssh -o PubkeyAuthentication=no sysadmin@172.197.162.225 → Permission denied (publickey).  ✅ ไม่มีช่องให้ใส่รหัสผ่าน
$ ssh root@172.197.162.225                               → Permission denied (publickey).  ✅

# log ฝั่ง server
sshd: User root from 202.28.78.39 not allowed because not listed in AllowUsers
```

### 1.4 🖥️ Nginx + PHP-FPM + MySQL 8 — `02-install-lemp.sh`
```bash
sudo ./02-install-lemp.sh
```
คำสั่งหลัก:
```bash
sudo apt-get install -y nginx
sudo apt-get install -y php-fpm php-cli php-mysql php-curl php-gd php-mbstring \
     php-xml php-zip php-intl php-bcmath php-imagick
sudo apt-get install -y mysql-server mysql-client
echo 'server_tokens off;' | sudo tee /etc/nginx/conf.d/00-hardening.conf
sudo sed -i 's/^;*expose_php *=.*/expose_php = Off/' /etc/php/8.3/fpm/php.ini
sudo mysql_secure_installation      # ตอบ y ทุกข้อ (root ใช้ auth_socket จึงข้ามการตั้งรหัส root)
```
ตรวจ:
```bash
nginx -v; php -v; mysql --version
sudo ss -tlnp | grep -E ':(80|443|3306)\s'     # 3306 ต้องผูกกับ 127.0.0.1
curl -sI http://localhost | grep -i '^server'  # ต้องเป็น "Server: nginx" ไม่มีเลขเวอร์ชัน (ทำได้หลังขั้น 1.5 มี vhost)
```

**ผลลัพธ์ (10 ต.ค. 2026):** ✅
```
$ nginx -v
nginx version: nginx/1.24.0 (Ubuntu)
$ php -v
PHP 8.3.6 (cli) (built: Sep  2 2026 12:56:02) (NTS)
$ mysql --version
mysql  Ver 8.0.46-0ubuntu0.24.04.4 for Linux on x86_64 ((Ubuntu))

nginx / php8.3-fpm / mysql : active + enabled
$ sudo ss -tlnp
LISTEN 127.0.0.1:3306   mysqld      ← ฐานข้อมูลไม่เปิดออกเน็ต
LISTEN 127.0.0.1:33060  mysqld (X protocol)
(nginx ยังไม่ฟัง port 80 เพราะลบ default site แล้ว และยังไม่มี vhost — ได้ในขั้น 1.5)

/etc/nginx/conf.d/00-hardening.conf : server_tokens off;
/etc/php/8.3/fpm/php.ini            : expose_php = Off
php -m : bcmath curl gd imagick intl mbstring mysqli xml zip

# mysql_secure_installation
root@localhost plugin=auth_socket   ← root ของ MySQL เข้าได้เฉพาะ root ของเครื่อง
anonymous users: ไม่มี · test db: removed · root remote: ไม่มี
validate_password component: ไม่ได้ติดตั้ง (ตอบ n) — รหัส DB ของ WordPress เป็นรหัสสุ่ม 28 ตัว
performance_schema OFF · innodb_buffer_pool_size 512M · bind_address 127.0.0.1
```

### 1.5 🖥️ WordPress + database — `03-install-wordpress.sh`
ต้องกรอก `DUCKDNS_SUBDOMAIN` และ `WP_DB_PASS` ใน config.env ก่อน
```bash
sudo ./03-install-wordpress.sh
```
คำสั่งหลัก:
```sql
-- sudo mysql
CREATE DATABASE wordpress DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'wpuser'@'localhost' IDENTIFIED BY '********';
GRANT ALL PRIVILEGES ON wordpress.* TO 'wpuser'@'localhost';
```
```bash
curl -fsSL https://wordpress.org/latest.tar.gz | tar -xz   # → /var/www/<SUBDOMAIN>
sudo chown -R www-data:www-data /var/www/<SUBDOMAIN>
# nginx: /etc/nginx/sites-available/<SUBDOMAIN>.duckdns.org (+ symlink ใน sites-enabled)
sudo nginx -t && sudo systemctl reload nginx
```
ตรวจ:
```bash
sudo mysql -e "SELECT user,host,plugin FROM mysql.user;"
sudo mysql -e "SHOW GRANTS FOR 'wpuser'@'localhost';"
ls -la /var/www/<SUBDOMAIN> | head
sudo -u www-data wp core version --path=/var/www/<SUBDOMAIN>
```

**ผลลัพธ์ (10 ต.ค. 2026):** ✅
```
WordPress 7.1.3 → /var/www/freexduk · wp-config.php สิทธิ 640 · WP-CLI 2.12.0
$ sudo mysql -e "SHOW GRANTS FOR 'wpuser'@'localhost';"
GRANT USAGE ON *.* TO `wpuser`@`localhost`
GRANT ALL PRIVILEGES ON `wordpress`.* TO `wpuser`@`localhost`     ← แตะได้แค่ DB ของตัวเอง
$ sudo -u www-data wp db check --path=/var/www/freexduk
Success: Database checked.
```
🐞 **บั๊กที่เจอและแก้:** ใน nginx กฎ `location ~ \.php$` อยู่ก่อนกฎห้ามรัน PHP ใน uploads
→ nginx เลือก regex location ข้อแรกที่ตรง → `uploads/x.php` ถูกส่งไปให้ PHP รัน (ได้ 404 แทน 403)
แก้: ย้ายกฎความปลอดภัยทั้งหมดไปไว้ก่อน `location ~ \.php$` + เพิ่มกัน `/?rest_route=/wp/v2/users`
```
# ทดสอบด้วยไฟล์ PHP จริงใน uploads
uploads/test-shell.php       → 403 (not executed)
/?rest_route=/wp/v2/users    → 403
/wp-json/wp/v2/users         → 403
/xmlrpc.php                  → 403
/wp-config.php               → 403
/.env                        → 403
```

### 1.6 🖥️ DuckDNS + cron ทุก 5 นาที — `04-duckdns.sh`
```bash
sudo ./04-duckdns.sh
```
ไฟล์ที่ได้:
```
/etc/duckdns.env                  token (สิทธิ 600)
/usr/local/bin/duckdns-update.sh  เรียก https://www.duckdns.org/update?domains=...&token=...&ip=
/etc/cron.d/duckdns               */5 * * * * root /usr/local/bin/duckdns-update.sh
```
ตรวจ:
```bash
cat /etc/cron.d/duckdns
dig +short <SUBDOMAIN>.duckdns.org @1.1.1.1    # ต้องได้ <VPS_IP>
journalctl -t duckdns -n 5
```

**ผลลัพธ์ (10 ต.ค. 2026):** ✅
```
public IP ของ VPS:      172.197.162.225
freexduk.duckdns.org →  172.197.162.225
$ cat /etc/cron.d/duckdns
*/5 * * * * root /usr/local/bin/duckdns-update.sh >/dev/null 2>&1
600 root /etc/duckdns.env · 700 root /usr/local/bin/duckdns-update.sh
$ journalctl -t duckdns -n 1
wp-vps duckdns[20332]: updated freexduk.duckdns.org -> OK
```

### 1.7 🖥️ HTTPS ด้วย acme.sh (DNS-01) — `05-https-acme.sh`
ต้องกรอก `ADMIN_EMAIL` ใน config.env ก่อน
```bash
sudo ./05-https-acme.sh --staging   # ทดสอบก่อน (ไม่กิน rate limit ของ Let's Encrypt)
sudo ./05-https-acme.sh --force     # ผ่านแล้วค่อยขอใบจริงทับ
```
คำสั่งหลัก:
```bash
curl https://get.acme.sh | sh -s email=<ADMIN_EMAIL>
acme.sh --set-default-ca --server letsencrypt          # default ของ acme.sh คือ ZeroSSL
DuckDNS_Token=... acme.sh --issue --dns dns_duckdns -d <SUBDOMAIN>.duckdns.org \
    --server letsencrypt --keylength ec-256 --dnssleep 60
acme.sh --install-cert -d <SUBDOMAIN>.duckdns.org --ecc \
    --key-file /etc/nginx/ssl/<SUBDOMAIN>.duckdns.org/privkey.pem \
    --fullchain-file /etc/nginx/ssl/<SUBDOMAIN>.duckdns.org/fullchain.pem \
    --reloadcmd "systemctl reload nginx"
```
ตรวจ:
```bash
sudo /root/.acme.sh/acme.sh --list
sudo crontab -l | grep acme
curl -sI http://<SUBDOMAIN>.duckdns.org | grep -iE '^(HTTP|location)'   # 301 → https
echo | openssl s_client -connect <SUBDOMAIN>.duckdns.org:443 -servername <SUBDOMAIN>.duckdns.org 2>/dev/null \
  | openssl x509 -noout -issuer -dates
```
➡️ **ทันทีหลังขั้นนี้**: เปิด `https://<SUBDOMAIN>.duckdns.org` → ทำ setup wizard (username ห้ามเป็น `admin`)

**ผลลัพธ์ (10 ต.ค. 2026):** ✅ ขอใบจริงตรง ๆ (ไม่ได้ใช้ --staging) ผ่านในรอบแรก
```
acme.sh v3.1.6 · default CA: Let's Encrypt
subject=CN = freexduk.duckdns.org
issuer=C = US, O = Let's Encrypt, CN = YE1
notBefore=Oct 10 15:41:35 2026 GMT · notAfter=Jan  8 15:41:34 2027 GMT
Renew (ARI): 2026-12-09
crontab root: 47 2,8,14,20 * * * "/root/.acme.sh"/acme.sh --cron --home "/root/.acme.sh"
http://freexduk.duckdns.org → 301 → https://freexduk.duckdns.org/
TLSv1.3 · Verify return code: 0 (ok)
```
⚠️ DuckDNS ตอบ 502 ตอน acme.sh ลบ TXT record → ลบเองด้วย `update?...&txt=removed&clear=true` → `OK` (ไม่กระทบใบรับรอง)
✅ setup wizard: ภาษาไทย · username ไม่ใช่ `admin` · ติ๊ก "ปิดกั้นเครื่องมือค้นหา" ไว้ระหว่างพัฒนา

### 1.8 ✅ เกณฑ์ผ่านด่านที่ 1
- [x] `https://freexduk.duckdns.org` เห็น WordPress + กุญแจล็อก (TLS 1.3, Let's Encrypt)
- [x] `ssh root@172.197.162.225` ไม่ได้ → `Permission denied (publickey)`
- [x] `ssh -o PubkeyAuthentication=no sysadmin@172.197.162.225` ไม่ได้ → `Permission denied (publickey)`
- [x] `curl -sI https://freexduk.duckdns.org` → `Server: nginx` ไม่มีเวอร์ชัน · ไม่มี `X-Powered-By`
- [ ] screenshot กุญแจใน browser + หน้าจอ ssh ทั้ง 3 แบบ (สมาชิกเก็บเอง)

### 1.9 🖥️ เก็บหลักฐาน
```bash
sudo ./99-collect-evidence.sh ~/report-stage1.md
```
💻 ดึงกลับมาที่เครื่อง: `scp wp-vps:~/report-stage1.md E:/wordpress-vps-project/`

---

## ด่านที่ 2 — Firewall + Geo-block

### 2.0 เตรียมทางกู้เครื่องก่อนเปิด firewall
🖥️ ตั้งรหัสผ่านให้ sysadmin — Serial Console ต้อง login ด้วยรหัสผ่าน (SSH ยังปิด password auth เหมือนเดิม)
```bash
sudo passwd sysadmin      # สมาชิกพิมพ์เอง
sudo passwd -S sysadmin   # ก่อน: "sysadmin L ..." (locked) → หลัง: "sysadmin P ..." ✅
```
ทางกู้ถ้าล็อกตัวเองออก:
1. รอ auto-rollback (5 นาที) ของสคริปต์ 06
2. Azure Portal → VM → Help → **Serial console** → login `sysadmin` → `sudo ~/wordpress-vps-project/scripts/06-firewall-th-only.sh --rollback`
3. Azure Portal → VM → Help → **Reset password** (ใช้ VM agent ผ่าน 168.63.129.16 ซึ่ง firewall อนุญาตไว้)

### 2.1 Azure NSG — firewall ชั้นนอก (ระดับ cloud)
💻 Azure Cloud Shell
```bash
az network nsg rule list -g rg-wordpress --nsg-name wp-vps-nsg \
  --query "[].{name:name, port:destinationPortRange, access:access, priority:priority}" -o table
```
**ผลลัพธ์ (11 ต.ค. 2026):** ✅ เปิดเฉพาะ 22/80/443 (rule อื่น ๆ ตกไปที่ default `DenyAllInBound`)
```
Name    Port    Access    Priority
------  ------  --------  ----------
HTTP    80      Allow     300
HTTPS   443     Allow     320
SSH     22      Allow     340
```

### 2.2 🖥️ iptables + ipset เฉพาะ IP ไทย — `06-firewall-th-only.sh`  ⚠️ ถามก่อนรัน (อนุญาตแล้ว 11 ต.ค.)
```bash
sudo ./06-firewall-th-only.sh            # ตั้ง rule + auto-rollback 5 นาที
ssh wp-vps                               # 💻 หน้าต่างใหม่ ต้องเข้าได้
sudo ./06-firewall-th-only.sh --confirm  # ยกเลิก rollback + บันทึกถาวร
```
คำสั่งหลักในสคริปต์:
```bash
sudo apt-get install -y ipset iptables-persistent netfilter-persistent ipset-persistent   # (ufw ถูกถอดออกอัตโนมัติ — ไม่ได้เปิดใช้อยู่แล้ว)
# /usr/local/sbin/th-ipset-refresh.sh : โหลด th-aggregated.zone (IPv4+IPv6) ลง set ชั่วคราว แล้ว ipset swap
ipset create th-net  hash:net family inet  maxelem 262144
ipset create th-net6 hash:net family inet6 maxelem 262144
iptables -N GEO-CHECK
iptables -A GEO-CHECK -m set --match-set th-net src -j ACCEPT
iptables -A GEO-CHECK -j LOGDROP                                  # LOG "GEOBLOCK-DROP " แล้ว DROP
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -s 168.63.129.16 -j ACCEPT                      # แพลตฟอร์ม Azure ห้ามบล็อก
iptables -A INPUT -p tcp --dport 22 -j GEO-CHECK
iptables -A INPUT -p tcp -m multiport --dports 80,443 -j GEO-CHECK
iptables -A INPUT -j LOGDROP
iptables -P INPUT DROP; iptables -P FORWARD DROP
# IPv6 ทำเหมือนกันด้วย set th-net6
# auto-rollback: systemd-run --on-active=300s → iptables -P INPUT ACCEPT + iptables-restore < backup
#   (ไม่ใช้แค่ "sleep 300 && iptables -F" เพราะ policy DROP ยังอยู่ = ล็อกตัวเองออก)
# --confirm: iptables-save | grep -v f2b- > /etc/iptables/rules.v4 ; ipset save > /etc/iptables/ipsets
```
**ผลลัพธ์ (11 ต.ค. 2026):** ✅
```
th-net: 666 รายการ · th-net6: 219 รายการ
IP 202.28.78.39 อยู่ในรายการประเทศไทย
ssh session ใหม่ → SSH OK · https จากเครื่องสมาชิก → 200 → --confirm
/etc/cron.d/th-ipset-refresh : 30 4 * * 0 root /usr/local/sbin/th-ipset-refresh.sh   (ทุกวันอาทิตย์ 04:30)
```

### 2.3 🖥️ fail2ban — `07-fail2ban.sh`
```bash
sudo ./07-fail2ban.sh
sudo fail2ban-client status
```
jail: `sshd` (journald) · `wordpress-login` (POST /wp-login.php → 200 = รหัสผิด) · `nginx-botsearch`
bantime 1h เพิ่มขึ้นเรื่อย ๆ ถ้าโดนซ้ำ (สูงสุด 1 สัปดาห์) · maxretry 5 ใน 10 นาที · ignoreip 127.0.0.1, 168.63.129.16

**ผลลัพธ์ (11 ต.ค. 2026):** ✅
```
$ fail2ban-regex sample.log wordpress-login.conf
Failregex: 1 total · Lines: 3 lines, 1 matched, 2 missed   ← จับเฉพาะ POST ที่ได้ 200
$ sudo fail2ban-client status
Jail list:	nginx-botsearch, sshd, wordpress-login
```

### 2.4 🖥️ ทดสอบว่ากฎอยู่รอดหลัง reboot
```bash
sudo reboot
sudo ipset list -t ; sudo iptables -S ; sudo ip6tables -S INPUT ; sudo fail2ban-client status
```
**ผลลัพธ์ (11 ต.ค. 2026):** ✅ uptime 0 min → ทุก service active, rule กลับมาครบ
```
netfilter-persistent active · fail2ban active · nginx active · php8.3-fpm active · mysql active
th-net 666 entries · th-net6 219 entries
-P INPUT DROP · -P FORWARD DROP
-A GEO-CHECK -m set --match-set th-net src -j ACCEPT
-A GEO-CHECK -j LOGDROP
ip6tables: -P INPUT DROP · ... --dports 22,80,443 -m set --match-set th-net6 src -j ACCEPT
https จากเครื่องสมาชิก (ไทย) → 200
```

### 2.5 ✅ ทดสอบจากต่างประเทศ (check-host.net)
💻 HTTP check จาก 40 node ทั่วโลก: https://check-host.net/check-report/5021648bk7f8
```
US ×3, Iran ×7, India ×2, Italy, Japan, France, Israel ×2, Russia ×3, Sweden, Turkey ×2,
Austria, Germany ×2, Hungary, Moldova, Ukraine, Vietnam, Portugal, Indonesia ×2,
Australia, Singapore, Kazakhstan, Switzerland, Netherlands ×2, Hong Kong
→ 40/40 FAIL (ส่วนใหญ่ "Connection timed out" = DROP เงียบ ไม่ตอบกลับ)
จากเน็ตไทย (202.28.78.39) → 200 ✅
```
🔍 **ข้อสังเกต:** รอบแรกใช้ TCP check แล้ว node `ua3` (Ukraine, AS13335 Cloudflare WARP) รายงาน "OK"
แต่ `ipset test th-net 104.28.192.94` → NOT in set และ log ฝั่ง server มี `GEOBLOCK-DROP SRC=104.28.156.61 DPT=443` ×3
→ WARP ตอบ TCP handshake แทนปลายทางเอง (false positive ของวิธีทดสอบ) ยืนยันด้วย HTTP check ที่ต้องได้หน้าเว็บจริง → fail ทั้งหมด

log ฝั่ง server (ตัวอย่าง):
```bash
sudo journalctl -k --grep 'GEOBLOCK-DROP' -n 20
# SRC=93.123.16.89 DPT=443 (Bulgaria) · SRC=185.83.213.25 DPT=443 · SRC=104.28.156.61 DPT=443 ...
```

### 2.6 ✅ เกณฑ์ผ่านด่านที่ 2
- [x] เข้าเว็บจากเน็ตไทยได้ (200)
- [x] เข้าจากต่างประเทศไม่ได้ (check-host 40/40 fail)
- [x] กฎอยู่รอดหลัง reboot · cron อัปเดต IP ไทยรายสัปดาห์ · fail2ban (sshd + nginx) · NSG เปิดแค่ 22/80/443
- [ ] screenshot: เปิดเว็บจากเน็ตไทยได้ / เปิดผ่าน VPN ต่างประเทศไม่ได้ (สมาชิกเก็บเอง)
- [ ] output `sudo iptables -L -n -v` และ `sudo ipset list -t` สำหรับแนบรายงาน (รัน 99-collect-evidence.sh)

## ด่านที่ 3 — เว็บแนะนำหลักสูตร

### 3.1 🖥️ theme + plugin + หน้าเว็บ + เมนู — `08-site-content.sh`
เนื้อหาแต่ละหน้าอยู่ใน `site/pages/*.html` และ `site/posts/*.html` (Gutenberg block markup)
```bash
scp -r E:/wordpress-vps-project/site wp-vps:wordpress-vps-project/
sudo ./08-site-content.sh       # รันซ้ำได้ — แต่จะทับเนื้อหาที่แก้ใน wp-admin
```
คำสั่งหลัก (รันเป็น www-data ผ่าน WP-CLI):
```bash
wp option update timezone_string Asia/Bangkok
wp rewrite structure '/%postname%/'
wp theme install kadence --activate
wp plugin install --activate cache-enabler ewww-image-optimizer contact-form-7 flamingo limit-login-attempts-reloaded
# mu-plugin: add_filter('xmlrpc_enabled', '__return_false') + ลบ X-Pingback header
wp post create - --post_type=page --post_name=<slug> --post_title=<ชื่อ> < site/pages/<slug>.html
wp option update show_on_front page ; page_on_front=<home> ; page_for_posts=<news>
wp menu create "เมนูหลัก" ; wp menu item add-post ... ; wp menu location assign "เมนูหลัก" primary
```

**ผลลัพธ์ (11 ต.ค. 2026):** ✅
```
theme: kadence 1.5.2
plugins: cache-enabler 1.8.17 · contact-form-7 6.2.1 · ewww-image-optimizer 8.8.0 · flamingo 2.6.4
         limit-login-attempts-reloaded 3.3.10
เมนู: หน้าแรก · เกี่ยวกับหลักสูตร · วิชาที่เรียน / แผนการเรียน · อาชีพหลังจบ ·
      ผลงานและกิจกรรมนักศึกษา · ข่าวสาร · การรับสมัคร · ติดต่อเรา

# 💻 ทดสอบจากเครื่องสมาชิก
/            200 0.36s     /about/      200 0.24s     /curriculum/ 200 0.24s
/careers/    200 0.25s     /showcase/   200 0.26s     /news/       200 0.61s
/admission/  200 0.24s     /contact/    200 0.23s     /xmlrpc.php  403
headers: Server: nginx (ไม่มีเวอร์ชัน) · ไม่มี X-Powered-By · ไม่มี X-Pingback
```
ฟอร์มติดต่อ: Azure บล็อก port 25 ขาออก → ตั้ง CF7 `skip_mail: on` + Flamingo เก็บข้อความใน wp-admin → Flamingo → Inbound Messages

🐞 **บั๊กที่เจอและแก้:**
| ปัญหา | สาเหตุ | วิธีแก้ |
|---|---|---|
| `wp rewrite structure` → `posix_spawn() failed: Permission denied` | wp spawn ตัวเองใหม่ใน cwd = home ของ sysadmin (700) ที่ www-data เข้าไม่ได้ | `cd $WP_ROOT` ก่อนเรียก wp |
| เมนูไม่ขึ้นที่ header (ธีมแสดงรายชื่อหน้าเรียงตามตัวอักษรแทน) | `wp ... \| grep -q` → grep ปิด pipe ก่อน → wp โดน SIGPIPE → `pipefail` ทำให้เงื่อนไขเป็น false | เก็บผลใส่ตัวแปรก่อนแล้วค่อย grep |
| หัวข้อสีเข้มบนพื้นน้ำเงิน / ปุ่ม outline มองไม่เห็น | ธีมกำหนดสี heading ทับสีของ group | ใส่สีขาวที่ block heading/button โดยตรง |
| เนื้อหาชิดขอบจอ | ตั้ง layout `fullwidth` ทุกหน้า | หน้าแรก fullwidth (มี padding เอง) · หน้าอื่น `normal` |
| ตรวจ URL จากในเครื่องได้ 000 | curl ไปที่ public IP ของตัวเอง → ไม่ใช่ IP ไทย → firewall ทิ้ง | `curl --resolve domain:443:127.0.0.1` |

### 3.2 ✅ เกณฑ์ด่านที่ 3
- [x] หน้าครบ 8 หน้า: หน้าแรก, เกี่ยวกับหลักสูตร, วิชาที่เรียน/แผนการเรียน, อาชีพหลังจบ, ผลงาน/กิจกรรม, ข่าวสาร, การรับสมัคร, ติดต่อ
- [x] theme เร็ว (Kadence) · แคช · บีบอัดรูป · ฟอร์มติดต่อ · จำกัดการ login
- [x] ปิด XML-RPC (nginx 403 + mu-plugin) · username ไม่ใช่ `admin`
- [x] แสดงผลดีทั้ง desktop และมือถือ
- [ ] กลุ่มแก้ข้อความ 【แก้ไข: …】 เป็นข้อมูลจริง + ใส่โลโก้/รูปจริง
- [ ] ก่อนส่ง: ตั้งค่า → การอ่าน → เอาติ๊ก "ปิดกั้นเครื่องมือค้นหา" ออก

### 3.3 ส่งต่อให้กลุ่มออกแบบเอง (11 ต.ค. 2026)
สมาชิก 6 คนมีบัญชี WordPress ของตัวเอง (role: administrator, ไม่มี username `admin`)
🖥️ สำรองก่อนเริ่มแก้:
```bash
install -d -m 700 ~/backups
wp db export - | gzip > ~/backups/wp-db-20261010-1803.sql.gz           # 262K
sudo tar -czf ~/backups/wp-content-20261010-1803.tar.gz -C /var/www/freexduk wp-content   # 31M
```
กู้คืน (ถ้าพัง): `gunzip -c ~/backups/wp-db-*.sql.gz | sudo -u www-data wp db import -` + แตก wp-content กลับ
🔒 `08-site-content.sh` เพิ่มตัวกัน: ถ้ามีหน้าเว็บอยู่แล้วจะไม่ยอมรันถ้าไม่ใส่ `--force` (และสำรอง DB ให้ก่อนทับ)

---

# STAGE 2 (แผน: `docs/06-stage2-plan.md` · ส่งพร้อม Stage 1 วันที่ 28 ต.ค.)

## Phase 0 — เตรียม log + วัดตัวเลข "ก่อน" (15 ต.ค. 2026)

### 0.1 🖥️ เพิ่มเวลาประมวลผลใน access log + เก็บ log 30 วัน
```bash
# /etc/nginx/conf.d/10-logformat.conf
log_format timed '$remote_addr - $remote_user [$time_local] "$request" '
                 '$status $body_bytes_sent "$http_referer" "$http_user_agent" '
                 'rt=$request_time urt=$upstream_response_time';
access_log /var/log/nginx/access.log timed;
# nginx.conf: comment access_log เดิมทิ้ง (ไม่งั้นเขียน log ซ้ำ 2 บรรทัด)
sudo nginx -t && sudo systemctl reload nginx
sudo sed -i 's/rotate 14/rotate 30/' /etc/logrotate.d/nginx
```
**ผลลัพธ์:** ✅ log มี `rt=0.042 urt=0.043` ต่อท้าย · fail2ban regex ยังจับได้ (`Failregex: 1 total`) · เว็บ 200 ตลอด
🐞 ครั้งแรกใส่ `access_log ... timed` ใน nginx.conf บรรทัด 40 แต่ `include conf.d/*.conf` (ที่ประกาศ log_format) อยู่บรรทัด 59
→ `unknown log format "timed"` → reload ล้ม (nginx ทำงานต่อด้วย config เดิม เว็บไม่ล่ม) → แก้: ย้าย access_log ไปไว้ไฟล์เดียวกับ log_format

### 0.2 💻 ตัวเลข "ก่อน" (baseline) — วัดจากเครื่องสมาชิกในไทย 15 ต.ค. 22:56 (+07)
TTFB = เวลาจนได้ไบต์แรก (รวม DNS + TCP + TLS handshake) · 5 ครั้ง/หน้า
```
หน้าแรก   TTFB p50 0.293s · p95 0.447s · ขนาด 289 KB
/curriculum/ TTFB p50 0.331s · /admission/ TTFB p50 0.237s

Load test หน้าแรก (curl ขนานกัน):
  N=200 c=10              → 15.1 req/s · p50 0.361s · p95 1.013s · ok 200/200
  N=100 c=5 (บังคับผ่าน PHP) →  9.7 req/s · p50 0.341s · p95 0.555s · ok 100/100

ฝั่งเซิร์ฟเวอร์ (จาก log ช่วงทดสอบ):
  PHP ใช้เวลา (urt) เฉลี่ย 0.045s · nginx ตอบทั้งหมด (rt รวมส่ง 289 KB) p50 0.12s
```
📌 **ข้อสังเกตสำหรับรายงาน:**
1. เซิร์ฟเวอร์ใช้เวลาสร้างหน้าแค่ ~0.05s แต่ผู้ใช้รอ ~0.3s → **เวลาส่วนใหญ่หมดไปกับเครือข่ายไทย→มาเลเซีย + TLS handshake**
   → นี่คือเหตุผลที่ CDN (Cloudflare มี edge ในกรุงเทพฯ) จะช่วยได้มากกว่าการเร่ง PHP
2. **Cache Enabler ยังไม่ทำงานจริง** — ไม่มี `WP_CACHE` ใน wp-config, ไม่มีโฟลเดอร์ cache, ไม่มี footer ของ Cache Enabler
   → ทุก request ยังผ่าน PHP (ตัวเลข "cached" ≈ "uncached") — baseline นี้จึงเป็น "ไม่มี cache เลย"

### 0.3 🖥️ เปิด Cache Enabler ให้ทำงานจริง (15 ต.ค.)
```bash
sudo cp -a wp-config.php /root/wp-config.php.bak.<ts>
sudo -u www-data wp config set WP_CACHE true --raw
```
**ผลลัพธ์:** ✅ request แรกสร้างแคช (`urt=0.066s`) → request ถัดไปตอบจากแคช **`urt=0.001s`**
· มี `<!-- Cache Enabler by KeyCDN ... -->` ท้ายหน้า · คนที่ login (cookie `wordpress_logged_in_*`) ข้ามแคชถูกต้อง
🐞 Cache Enabler cache เฉพาะ request ที่มี `Accept: text/html` (เหมือน browser) — `curl` ส่ง `Accept: */*` จึงไม่เคยโดนแคช
→ ทดสอบต้องใส่ `-H 'Accept: text/html'` · baseline ข้อ 0.2 จึงเป็นตัวเลขแบบ "ไม่มีแคช" ถูกต้องแล้ว

---

## Phase 1 — AI สแกน log → Dashboard

### 1.1 🖥️ ติดตั้ง Docker แบบไม่แตะ firewall (15 ต.ค.)
ปัญหา: Docker ค่าเริ่มต้นเขียน iptables เอง → port ของ container **ข้าม geo-block** ได้ และสคริปต์ 06 ที่ flush กฎจะทำให้ Docker พัง
```bash
# เขียน config ก่อนติดตั้ง (Docker start ทันทีหลัง apt install)
sudo install -d /etc/docker
cat /etc/docker/daemon.json
{ "iptables": false, "ip6tables": false, "bridge": "none",
  "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" } }
sudo apt-get install -y docker.io docker-compose-v2
# container ใช้ --network host (ไม่มี bridge/NAT) + --read-only --cap-drop ALL --security-opt no-new-privileges
```
**ผลลัพธ์:** ✅
```
Docker 29.1.3 · Compose 2.40.3
iptables -S v4/v6 ก่อน vs หลังติดตั้ง → เหมือนเดิมทุกบรรทัด · ipset เหมือนเดิม · ไม่มี docker0 bridge
container (read-only, cap-drop ALL) → https://api.anthropic.com → HTTP 401 (ออกเน็ตได้ รอใส่ API key)
RAM ว่าง 2.8 GB · เว็บ 200 ตลอด
```

### 1.2 🖥️ logwatch: เก็บสถิติ log + Claude วิเคราะห์ — `09-logwatch.sh` (15 ต.ค.)
โค้ดอยู่ใน `logwatch/` → ติดตั้งไปที่ `/opt/logwatch` (เจ้าของ root ไม่รันโค้ดจาก home ด้วยสิทธิ root)
```
systemd timer (ทุก 6 ชม.) → logwatch.service
  ① /opt/logwatch/prepare.sh  (host, root)
       คัดลอกเฉพาะ log ช่วง 26 ชม. → /var/lib/logwatch/in  (640 root:nogroup)
       nginx access · journalctl -k GEOBLOCK · journalctl -u ssh · fail2ban.log · สถานะ fail2ban/บริการ/ใบรับรอง
       ฐานข้อมูลประเทศ ipdeny all-zones (241 ประเทศ, 264,376 ช่วง) อัปเดตเดือนละครั้ง
  ② docker compose run --rm analyzer  (container: user nobody · read-only · cap_drop ALL · no-new-privileges)
       /in, /geo อ่านอย่างเดียว · เขียนได้แค่ /out
       สรุปสถิติด้วยโค้ด → ส่ง "สรุป" (~4K token) ให้ Claude → JSON ตาม schema (structured outputs)
       → /var/lib/logwatch/out/{latest.json, history.json, usage.json}
dashboard container (nginx-unprivileged) ฟัง 127.0.0.1:8081 · CSP ห้าม inline script (กัน XSS จากข้อความใน log)
```
```bash
sudo ./09-logwatch.sh          # ติดตั้ง + ทดสอบแบบไม่เรียก AI
sudo ./09-logwatch.sh --run    # วิเคราะห์ด้วย AI ทันที
```
**ผลรอบแรก (15 ต.ค. 23:42):** ✅ `claude-opus-5-5` · effort medium · input 3,914 + output 3,055 token · **$0.077** · 31.7 วินาที
```
threat_level: low
- [misconfiguration] กฎ nginx บล็อก /wp-json/wp/v2/users/me ของทีมงานเอง (313 ครั้ง)  ← AI หาเจอเอง
- [misconfiguration] หน้า /contact/ /about/ ... ตอบ 404 (ทีมกำลังสร้างหน้าใหม่)
- [geoblock_pressure] IP ต่างประเทศ 80 IP ถูก DROP ≥225 ครั้ง (443:139, 22:63, 80:23) — ไม่มีรายการใดผ่านถึง nginx/SSH
ips_to_review: 172.197.162.225 (DROP 99 ครั้ง) ← คือ IP ของเซิร์ฟเวอร์เราเอง → นำไปสู่บั๊ก WP-Cron ด้านล่าง
ประเทศที่ถูกบล็อก: GB 98 · US 45 · SC 16 · CN 7 · BG 6 · ... | traffic ที่ถึง nginx: TH 100%
```

🐞 **บั๊กที่เจอระหว่างทำ Phase 1**
| ปัญหา | สาเหตุ | วิธีแก้ |
|---|---|---|
| dashboard container start ไม่ขึ้น | mount `/out` ซ้อนเข้าไปในโฟลเดอร์ html ที่ mount แบบ read-only → สร้าง mountpoint ไม่ได้ | mount ไปที่ `/data` แยก + `alias` ใน nginx |
| ระบุประเทศไม่ได้ | URL `aggregated/all-zones.tar.gz` ไม่มีจริง (404) | ใช้ `countries/all-zones.tar.gz` (ไฟล์ `xx.zone`) |
| เรียก API ได้ 400 | API key ไม่ได้ผูกกับ workspace | สร้าง key ใหม่ในหน้า workspace (+ รองรับ `ANTHROPIC_WORKSPACE_ID`) |
| **block editor ของทีมถูกบล็อก 291 ครั้ง** | กฎ nginx `location ~ ^/wp-json/wp/v2/users { deny all; }` (ด่าน 1) บล็อก `/users/me` ที่ editor ใช้ — nginx แยกไม่ออกว่าใคร login | ลบกฎ nginx · ย้ายไป mu-plugin `block-user-enum.php` ซ่อน endpoint เฉพาะคนที่ไม่ได้ login → ไม่ login: 404 · login: 200 |
| **WP-Cron ตายตั้งแต่เปิด firewall (11 ต.ค.)** — งานค้าง 12 งาน | เครื่องเรียก `https://freexduk.duckdns.org` → public IP → วนออกนอกแล้วกลับเข้ามาด้วย IP Azure (ไม่ใช่ไทย) → geo-block DROP | `/etc/hosts`: `127.0.0.1 freexduk.duckdns.org` → `wp cron test`: Success · รันงานค้าง 12 งาน |

### 1.3 Dashboard (`logwatch/dashboard/` → container ฟัง 127.0.0.1:8081)
หน้าเว็บ static (HTML + CSS + JS แยกไฟล์) อ่าน `data/latest.json`, `history.json`, `usage.json`
- ไฟสถานะระดับภัย (สี + ไอคอน + คำเสมอ) · ตัวเลขหลัก · สรุป/เหตุการณ์/IP ที่ควรตรวจจาก AI
- กราฟรายชั่วโมง 24 ชม. แยกกราฟละ 1 ชุดข้อมูล (ไม่ใช้สองแกน) · กราฟประเทศที่ถูกบล็อก · hover tooltip · ดูเป็นตารางได้ทุกกราฟ
- ตาราง: รูปแบบการโจมตี · IP ที่ใช้งานมากสุด · SSH/fail2ban/WP login · สถานะบริการ · ประวัติการสแกน + ค่า AI
- **ความปลอดภัย:** ข้อความจาก log ใส่ผ่าน `textContent` เท่านั้น (ไม่มี innerHTML) + CSP `script-src 'self'` (ห้าม inline)
  · ซ่อน IP 2 octet ท้ายเป็นค่าเริ่มต้น (PDPA ตอนนำเสนอ) · `/data/history/` และ `nginx.conf` → 403
- รองรับ dark/light mode · auto refresh ทุก 5 นาที
**ผลทดสอบ:** ทุก path 200 · CSP header มี · console ไม่มี error · tooltip `22:00 น. · 93 ครั้งที่ถูกบล็อก` · ไม่มี script/img ถูกฉีดในส่วนเหตุการณ์
ยังเปิดได้เฉพาะในเครื่อง (127.0.0.1) → เปิดออกเน็ตผ่าน reverse proxy + รหัสผ่าน ใน Phase 2

### 1.4 เปลี่ยนรุ่นเป็น Claude Sonnet 5.5 (15 ต.ค.)
`config.env`: `CLAUDE_MODEL=claude-sonnet-5-5` → `sudo ./09-logwatch.sh`
| รุ่น | input | output | ค่าใช้จ่าย/รอบ | เวลา |
|---|---|---|---|---|
| claude-opus-5-5 | 3,914 | 3,055 | $0.077 | 31.7 s |
| **claude-sonnet-5-5** | 3,987 | 1,402 | **$0.022** | 13.3 s |
วันละ 4 รอบ ≈ $0.09/วัน → เครดิต $5 ใช้ได้ ~2 เดือน

---

## Phase 2 — Reverse proxy (15 ต.ค. 2026) — `10-reverse-proxy.sh`
```
ผู้ใช้ ─443─► Nginx หน้าบ้าน (TLS · rate limit · micro-cache 10 วินาที · X-Cache-Status · client_max_body_size 32m)
               ├─► 127.0.0.1:8080  Nginx origin (real_ip จาก X-Forwarded-For) → PHP-FPM → MySQL
               └─► 127.0.0.1:8081  /security-dashboard/  (auth_basic)
```
```bash
sudo ./10-reverse-proxy.sh             # 1) เปิด origin :8080 → ทดสอบได้ 200  2) สลับ 443 → proxy (reload แบบ atomic)
sudo ./10-reverse-proxy.sh --rollback  # คืน vhost เดิม (สำรองที่ /root/nginx-backup-phase2)
```
ไฟล์: `conf.d/20-proxy.conf` (rate limit zone · cache zone · map cookie · upstream) · `snippets/proxy-params.conf` · `sites-available/wp-origin` · `sites-available/freexduk.duckdns.org` (หน้าบ้าน)
- rate limit: ทั่วไป 10 req/s/IP (burst 100 — editor เรียกถี่ + ทีมแชร์ IP มหาลัย) · `/wp-login.php` 10 req/min (burst 5) · ตอบ **429**
- ไม่ cache: cookie `wordpress_logged_in_*` / `wp-postpass_*` / `comment_author_*` · method ไม่ใช่ GET/HEAD · มี query string · `/wp-admin` `/wp-login.php` `/wp-json` `/xmlrpc.php` `/wp-cron.php` `/feed`
- log หลักอยู่ที่หน้าบ้าน (`access.log` — fail2ban/logwatch อ่านเหมือนเดิม) · origin แยก `origin-access.log`

**ผลทดสอบ:** ✅
```
/ 200 · /wp-login.php 200 · /wp-admin/ 302 · /wp-json/ 200 · /xmlrpc.php 403 · /security-dashboard/ 401
X-Cache-Status: MISS → HIT → HIT  (หน้าแรก 3 ครั้ง)
cookie wordpress_logged_in_* → BYPASS · ?s=test → BYPASS
real IP: front 202.28.x.x /curriculum/ 200 = origin 202.28.x.x /curriculum/ 200
GET /wp-login.php ×20 จาก 127.0.0.1 → 200×6 แล้ว 429×14
POST 5 MB → 400 จาก WordPress (ผ่าน nginx — ก่อนหน้านี้ค่า default 1 MB จะได้ 413)
wp cron test: Success · fail2ban-regex บน access.log หน้าบ้าน: Failregex 1 · jails ครบ 3
```

### ตัวเลข ก่อน vs หลัง (วัดจากเครื่องสมาชิกในไทย วิธีเดียวกัน) — `docs/stage2-perf-after-phase2.txt`
| ตัวชี้วัด | ก่อน (15 ต.ค. 22:56) | หลัง Phase 2 (15 ต.ค. 23:56) | เปลี่ยนแปลง |
|---|---|---|---|
| TTFB หน้าแรก p50 | 0.293 s | **0.156 s** | **−47%** |
| TTFB /curriculum/ p50 | 0.331 s | **0.155 s** | **−53%** |
| TTFB /admission/ p50 | 0.237 s | **0.154 s** | **−35%** |
| Load หน้าแรก (N=200, c=10) | 15.1 req/s · p95 1.013 s | **22.3 req/s · p95 0.469 s** | **+48% · p95 −54%** |
| ตอบจาก cache (ไม่แตะ PHP) | 0% | **199/200** (`urt=-`) | |
หมายเหตุ: load test หลัง Phase 2 ได้ 429 อยู่ 15/200 — rate limit 10 req/s ทำงาน (ยิงเกิน burst 100 จาก IP เดียว)

### 2.1 Security Dashboard ออนไลน์ (16 ต.ค.)
🖥️ สมาชิกตั้ง user เอง: `sudo htpasswd /etc/nginx/.htpasswd-dashboard <ชื่อ>` (ไฟล์ 640 root:www-data, 1 user)
**ผลลัพธ์:** ✅ https://freexduk.duckdns.org/security-dashboard/
```
ไม่ใส่รหัส → 401 · รหัสผิด → 401 · ใส่ถูก → 200 (index, app.js, style.css, data/latest.json, history.json, usage.json)
/security-dashboard → 301 → /security-dashboard/
```
ชั้นป้องกันของ dashboard: geo-block (ไทยเท่านั้น) → rate limit → Basic Auth → container read-only (127.0.0.1:8081) → CSP + textContent

### 2.2 ปรับธีม Dashboard ให้เหมือนหน้าเว็บหลัก (24 ต.ค.)
เนื้อหา/โค้ด JS เหมือนเดิม — แก้แค่ `logwatch/dashboard/style.css` (สี/ฟอนต์จาก `.cs-site` ของเว็บหลัก: navy `#051B33`, พื้น `#F4F7FC`, น้ำเงิน `#1D5BD8`, ฟอนต์ Anuphan · IBM Plex Sans Thai · Sora)
และ CSP ใน `logwatch/dashboard/nginx.conf` เพิ่ม `style-src https://fonts.googleapis.com` + `font-src https://fonts.gstatic.com` (สคริปต์ยังเป็น `'self'` เท่านั้น)
```bash
sudo install -d -m 700 /root/dashboard-backup-20261024
sudo cp -a /opt/logwatch/dashboard/{style.css,nginx.conf} /root/dashboard-backup-20261024/
# ส่งไฟล์ใหม่จากเครื่อง local
ssh wp-vps 'sudo tee /opt/logwatch/dashboard/style.css >/dev/null' < logwatch/dashboard/style.css
ssh wp-vps 'sudo tee /opt/logwatch/dashboard/nginx.conf >/dev/null' < logwatch/dashboard/nginx.conf
cd /opt/logwatch && sudo docker compose up -d --force-recreate dashboard
```
**ผลลัพธ์:** ✅ CSP ใหม่มีผล · `/` `/style.css` `/app.js` `/data/latest.json` → 200 · หน้าสาธารณะไม่ใส่รหัส → 401 · เว็บหลัก 200 · ฟอนต์โหลดได้ ไม่มี console error (ทดสอบด้วยข้อมูลจริงบน preview ในเครื่อง ทั้งโหมดสว่าง/มืด)
🐞 `nginx -s reload` ใน container ไม่เห็น nginx.conf ใหม่ — container ผูก bind mount กับไฟล์ inode เดิม → ต้อง `--force-recreate`
กู้คืน: `sudo cp /root/dashboard-backup-20261024/* /opt/logwatch/dashboard/ && cd /opt/logwatch && sudo docker compose up -d --force-recreate dashboard`

### 2.3 เปิดรอบสแกน AI กลับมา (24 ต.ค.)
ก่อนหน้านี้ปิด `logwatch.timer` ไว้ชั่วคราวเพื่อประหยัดเครดิต API — เปิดกลับก่อนวันนำเสนอ
```bash
sudo systemctl enable --now logwatch.timer
sudo systemctl start logwatch.service          # สแกนทันที 1 รอบ
systemctl list-timers logwatch.timer --no-pager
```
**ผลลัพธ์:** ✅ `claude-sonnet-5-5` · input 3,397 + output 771 token · **$0.0145** · 9.3 วินาที · threat_level: low · incidents: 0
```
requests 1,076 (IP ไทยทั้งหมด) · geo-block DROP 290 (104 IP ต่างประเทศ) · SSH publickey สำเร็จ 17 · WordPress login ผิด 0
รอบถัดไป: ทุก 6 ชม. · ค่า AI สะสม 3 รอบ $0.113
```
ปิดอีกครั้งได้ด้วย `sudo systemctl disable --now logwatch.timer`

### 2.4 ปิดการสืบชื่อ login ของผู้ใช้ให้ครบทุกช่องทาง (28 ต.ค.)
พบจากการตรวจความปลอดภัย: `/?author=1..8` → 301 ไป `/author/<ชื่อ login>/` ครบทั้ง 8 บัญชี (ทุกบัญชี user_nicename = user_login)
**สาเหตุ:** mu-plugin `block-user-enum.php` กัน `?author=` ที่ `template_redirect` priority 10 แต่ `redirect_canonical` ของ WordPress อยู่ priority เดียวกันและได้คิวก่อน
นอกจากนี้ยังหลุดผ่านลิงก์ผู้เขียนในหน้าข่าว, oEmbed (`author_url`) และชื่อผู้เขียนที่ตรงกับ login (1 บัญชี)
**แก้ (เฉพาะคนที่ไม่ได้ login):** `?author=N` → หน้าแรก (priority 1) · `/author/<ชื่อ>/` → 404 · `author_link` → หน้าแรก · oEmbed ตัด `author_url` · ชื่อที่ตรงกับ login → ชื่อเว็บ
โค้ดเดียวกันอยู่ใน `scripts/08-site-content.sh`
```bash
sudo install -d -m 700 /root/a1-backup-20261028 && sudo cp -a /var/www/freexduk/wp-content/mu-plugins/block-user-enum.php /root/a1-backup-20261028/
php -l /tmp/bue.php
sudo install -m 644 -o www-data -g www-data /tmp/bue.php /var/www/freexduk/wp-content/mu-plugins/block-user-enum.php
cd /var/www/freexduk && sudo -u www-data wp cache-enabler clear
sudo find /var/cache/nginx/micro -type f -delete      # ล้าง micro-cache (หน้าเก่ามีลิงก์ /author/ ค้าง)
```
**ผลลัพธ์:** ✅
```
คนนอก: ?author=1..8 → 301 ไปหน้าแรก · /author/<ชื่อ>/ → 404 · ลิงก์ /author/ ในหน้าข่าวและ feed: 0
       oEmbed author_url: 0 · ชื่อ login ปรากฏใน feed/หน้าข่าว: 0 · /wp-json/wp/v2/users → 404
ทีม (login): /wp/v2/users/me → 200 · ลิงก์ author ปกติ
หน้า / /curriculum/ /admission/ /wp-login.php → 200 · ไม่มี PHP error
```
กู้คืน: `sudo cp /root/a1-backup-20261028/block-user-enum.php /var/www/freexduk/wp-content/mu-plugins/`
หมายเหตุ: `/news/` ได้ 404 อยู่ก่อนแล้ว (ไม่มีหน้า news ใน WordPress — ไม่เกี่ยวกับการแก้นี้)

### 2.5 ปิดจุดอ่อนจากการตรวจความปลอดภัย ระยะ B (28 ต.ค.)
สำรองก่อนแก้ทั้งหมดที่ `/root/phaseB-backup-20261028/` (wp-db.sql.gz · plugins-themes.tar.gz · front vhost · wp-origin · wordpress-common.conf · duckdns-update.sh)
```bash
B=/root/phaseB-backup-20261028; sudo install -d -m 700 $B
cd /var/www/freexduk && sudo -u www-data wp db export - | gzip | sudo tee $B/wp-db.sql.gz >/dev/null
sudo tar -czf $B/plugins-themes.tar.gz -C /var/www/freexduk/wp-content plugins themes mu-plugins
```
| # | แก้อะไร | คำสั่ง / ไฟล์ | ผล |
|---|---|---|---|
| B1 | อัปเดตปลั๊กอิน | `wp plugin update contact-form-7 ewww-image-optimizer` | CF7 6.2.1 → 6.2.3 · EWWW 8.8.0 → 8.9.0 · CF7 REST ตอบ `validation_failed` (ทำงานปกติ) |
| B3 | ลบของที่ไม่ใช้ | `wp plugin delete akismet hello` · `wp theme delete twentytwentythree twentytwentyfour` | เหลือธีม kadence (ใช้) + twentytwentyfive (สำรอง) |
| B4 | ซ่อนเลขเวอร์ชัน | `snippets/wordpress-common.conf`: readme.html / license.txt → 404 · mu-plugin `hide-wp-version.php` | 404 ทั้งสองไฟล์ · `generator` ในหน้าเว็บและ feed: 0 |
| B5 | header เพิ่ม (หน้าบ้าน ระดับ server) | `Permissions-Policy` + `Content-Security-Policy-Report-Only` (มี `worker-src 'self' blob:` สำหรับภาพเคลื่อนไหวหน้าแรก) | เปิด 5 หน้าในเบราว์เซอร์: ไม่มี CSP violation ไม่มี console error |
| B6 | ซ่อน token DuckDNS จาก `ps` | `/usr/local/bin/duckdns-update.sh`: ส่ง URL ให้ `curl -K -` ทาง stdin | DuckDNS ตอบ `OK` · ไม่มี token ใน argument ของคำสั่งใด |

```bash
sudo nginx -t && sudo systemctl reload nginx
sudo -u www-data wp cache-enabler clear && sudo find /var/cache/nginx/micro -type f -delete
```
**ตรวจรอบสุดท้าย:** ✅ บริการครบ · `/` `/curriculum/` `/admission/` `/coop/` `/contact/` `/wp-login.php` → 200 · Dashboard 401 · xmlrpc 403 · readme 404 · `?author=1` → หน้าแรก · `wp cron test` Success
หมายเหตุ: หน้า `/contact/` ที่ทีมออกแบบใหม่ไม่ได้ใส่ฟอร์ม CF7 (shortcode เหลือเฉพาะใน revision เก่า) — ไม่เกี่ยวกับการอัปเดต
**ยังไม่ทำ:** B2 ลดสิทธิ์ administrator (8 บัญชี) — รอทีมตกลงว่าใครคงเป็น admin · เปลี่ยน CSP จาก Report-Only เป็นบังคับใช้ หลังดูผล 1–2 วัน
กู้คืน: config ใน `$B/` copy กลับแล้ว `nginx -t && systemctl reload nginx` · ปลั๊กอิน/ธีม: แตก `plugins-themes.tar.gz` กลับ · DB: `gunzip -c $B/wp-db.sql.gz | sudo -u www-data wp db import -`

### 2.6 ระยะ C1: ตัวตรวจในสคริปต์อัปเดตรายชื่อ IP ไทย (28 ต.ค.) ⚠️ แตะ firewall — ได้รับอนุญาตแล้ว
**ปัญหาเดิม:** `/usr/local/sbin/th-ipset-refresh.sh` (cron อาทิตย์ 04:30) เช็คแค่จำนวนขั้นต่ำ — ถ้า ipdeny ถูกแก้ให้มี `0.0.0.0/0` geo-block จะเปิดทั้งโลกโดยไม่รู้ตัว
**แก้:** เพิ่ม `validate()` — ปฏิเสธทั้งชุดและ**คงรายการเดิม**ถ้า: ช่วงกว้างกว่า /8 (v4) หรือ /16 (v6) · มี IP ภายใน/พิเศษ (0.x 10.x 127.x 169.254.x 172.16–31.x 192.168.x 224+ ::/0 ::1 fc00::/7 fe80::) · จำนวนเพิ่มเกิน 2 เท่าหรือหดเกินครึ่ง
บันทึกเตือนที่ `journalctl -t th-ipset` (priority warning) · เพิ่มโหมด `--selftest` ที่ไม่แตะ ipset · สร้างจาก `scripts/06-firewall-th-only.sh` (write_refresh_script)
**กฎ iptables ไม่เปลี่ยน** (แก้เฉพาะตัวตรวจก่อนโหลดรายการ)
```bash
B=/root/c1-backup-20261028; sudo install -d -m 700 $B
sudo cp -a /usr/local/sbin/th-ipset-refresh.sh $B/ && sudo cp -a /etc/iptables/ipsets $B/ipsets.before
sudo install -m 750 -o root -g root /tmp/th-new.sh /usr/local/sbin/th-ipset-refresh.sh
sudo /usr/local/sbin/th-ipset-refresh.sh --selftest
sudo /usr/local/sbin/th-ipset-refresh.sh
```
**ผลลัพธ์:** ✅
```
selftest 7/7 PASS: รายการจริง v4/v6 → ผ่าน · 0.0.0.0/0, ::/0, 10.0.0.0/8, พุ่ง 3 เท่า, หดเหลือ 1/3 → ปฏิเสธ
รันจริง: th-net 667 · th-net6 221 (เท่าเดิม) · iptables-save (ไม่รวม counter) md5 ก่อน = หลัง · เว็บ 200
```
🐞 ระหว่างทดสอบ SSH ใหม่ค้าง: ต่อ SSH ถี่เกิน 10 ครั้ง/นาที → โดนกฎ SSHBRUTE ของเราเอง (ทำงานตามออกแบบ) ปลดเองเมื่อหยุดต่อ ~1 นาที
กู้คืน: `sudo cp /root/c1-backup-20261028/th-ipset-refresh.sh /usr/local/sbin/`
**C2 (sudo ต้องใส่รหัสผ่าน):** ตกลงทำตอนจบโปรเจกต์

### 2.7 ลด admin + 2FA + CSP แบบ hash (28 ต.ค.)
สำรองที่ `/root/phaseD-backup-20261028/` (wp-db.sql.gz · roles-before.csv · front vhost · 20-proxy.conf)

**ลดสิทธิ์ administrator** (เจ้าของงานเลือก: เหลือ ID 1 คนเดียว)
```bash
for id in 2 3 4 5 6 7 8; do sudo -u www-data wp user set-role $id editor; done
sudo -u www-data wp plugin install two-factor --activate      # 0.17.0 — ยังไม่บังคับ แต่ละคนเปิดเองในโปรไฟล์
```
ผล: administrator 1 · editor 7 — Editor เข้า "ปรับแต่ง (Customize)" ของธีมไม่ได้ ต้องให้ ID 1 ทำแทน

**CSP แบบ hash** — `scripts/11-csp-strict.sh` (ติดตั้ง `/usr/local/sbin/csp-update-hashes.sh`)
คำนวณ sha256 ของสคริปต์ inline ทุกตัวใน 12 หน้าสาธารณะ (หน้า/โพสต์ที่เผยแพร่ + หมวดหมู่ + ค้นหา + 404 ทั้งแบบ cache และสด)
→ `/etc/nginx/conf.d/21-csp.conf` (map ตาม cookie login + path) · vhost หน้าบ้านส่ง `$csp_enforce` / `$csp_report`
| ผู้เข้าชม | header |
|---|---|
| คนทั่วไป (หน้าสาธารณะ) | `Content-Security-Policy` แบบ hash 16 ตัว (บังคับใช้) |
| คนที่ login / wp-admin / wp-login | นโยบายเดิมแบบ Report-Only (กัน block editor พัง) |
| /security-dashboard/ | CSP ของ container เอง |
```bash
sudo ./11-csp-strict.sh             # โหมดทดสอบ: บังคับนโยบายเดิม + รายงานนโยบาย hash
sudo ./11-csp-strict.sh --enforce   # บังคับใช้
```
**ผลลัพธ์:** ✅
```
โหมดทดสอบ รอบ 1: แจ้งเตือน "inline speculation rules" ทุกหน้า → เพิ่ม type speculationrules ในตัวคำนวณ hash (15 → 16 ตัว)
โหมดทดสอบ รอบ 2: เปิด 10 หน้าในเบราว์เซอร์ → ไม่มีแจ้งเตือน CSP
บังคับใช้: ไม่มีสคริปต์ถูกบล็อก · ไม่มี console error · ภาพเคลื่อนไหว (canvas) และเมนูทำงาน · ทุกหน้า 200
ลองฝังสคริปต์ inline ใหม่ผ่าน DevTools → ไม่ถูกรัน (CSP บล็อก)
```
⚠️ **แก้สคริปต์ในหน้าเว็บเมื่อไหร่ ต้องรัน `sudo csp-update-hashes.sh --enforce`** ไม่งั้นสคริปต์ที่แก้จะถูกบล็อก · ห้ามตั้ง cron ให้รันเอง
🐞 ทดสอบ header ทันทีหลัง `systemctl reload nginx` ได้ค่าเก่า — worker เดิมยังตอบอยู่ชั่วขณะ รอ 1–2 วินาทีแล้วทดสอบใหม่
กู้คืน: `sudo rm /etc/nginx/conf.d/21-csp.conf && sudo cp /root/phaseD-backup-20261028/freexduk.duckdns.org /etc/nginx/sites-available/ && sudo nginx -t && sudo systemctl reload nginx`

### 2.8 ตรวจ PHP2Shell (28 ต.ค.)
ประกาศฉุกเฉิน 21 ต.ค.: CVE-2026-109618 / 109619 (RCE ไม่ต้อง login, CVSS 9.2, มีการโจมตีจริง) — Ubuntu แก้ใน USN-8948-1 → `8.3.6-0ubuntu0.24.04.13`
```bash
dpkg-query -W php8.3-fpm                               # 8.3.6-0ubuntu0.24.04.13 ✅ (= candidate ล่าสุด)
zcat /usr/share/doc/php8.3-common/changelog.Debian.gz | head   # มี CVE-2026-109618_109619.patch
grep "upgrade php8.3" /var/log/dpkg.log | tail -1      # unattended-upgrades ติดตั้งเอง 22 ต.ค. 06:13
systemctl show php8.3-fpm -p ActiveEnterTimestamp      # รีสตาร์ท 27 ต.ค. (หลังอัปเดต) ✅
```
CVE-2026-115560 (23 ต.ค. ยังไม่มีแพตช์): ต้องมีโค้ดเปลี่ยน `session.serialize_handler` ด้วย `ini_set()` + `session_start()` — ค้นทั้งเว็บไม่พบ → ไม่เข้าเงื่อนไข
ทางลดเสี่ยงที่ PHP แนะนำ (`session.upload_progress.enabled=0`) — เจ้าของงานเลือกยังไม่ทำ

### 2.9 ระบบแจ้งเตือนทาง Discord (28 ต.ค.) — `scripts/12-alerts.sh`
`/usr/local/sbin/alert-check` (python3, root) · `alert-check.timer` ทุก 5 นาที · webhook ใน `/etc/alert.env` (600 root) · state `/var/lib/alert/state.json`
| ประเภท | เงื่อนไข |
|---|---|
| สถานะ (แจ้งครั้งแรก · เตือนซ้ำทุก 6 ชม. · แจ้งตอนหาย) | `/` หรือ `/wp-login.php` ไม่ใช่ 200 · nginx/php8.3-fpm/mysql/fail2ban/docker ไม่ active · container dashboard หยุด · INPUT ไม่ใช่ DROP · th-net < 100 ช่วง · ใบรับรอง < 14 วัน · ดิสก์ > 90% · AI ไม่ได้สแกน > 13 ชม. |
| เหตุการณ์ (แจ้งครั้งเดียว) | `journalctl -t th-ipset -p warning` ใหม่ · AI สแกนล้มเหลว · ผล AI ระดับ medium ขึ้นไป (ทั้ง threat_level หรือ incident) |
ข้อความจาก AI ผ่าน `mask()`: IPv4 → `a.b.x.x` · IPv6 → `xxxx:xxxx:…` · `@` → `＠` · ส่งด้วย `allowed_mentions: {parse: []}`
```bash
sudo ./12-alerts.sh                 # ติดตั้ง
sudo alert-check --dry-run          # ตรวจแต่ไม่ส่ง
```
**ผลลัพธ์:** ✅ timer ทำงาน · dry-run ตอนนี้: ไม่มีปัญหา
จำลองปัญหา (ไม่ส่งจริง): บริการชื่อไม่มีจริง + เว็บตอบ 502 → ตรวจพบทั้งคู่ · ผล AI medium ปลอม → ส่ง 1 ข้อความ IP ถูกซ่อน `@everyone` ถูกปิด incident low ไม่ส่ง · run เดิมซ้ำ → ไม่แจ้งซ้ำ
**เจ้าของงานใส่ webhook เอง** (ห้ามส่งในแชท):
```bash
read -rsp "Webhook URL: " U; echo; echo "DISCORD_WEBHOOK_URL=$U" | sudo tee /etc/alert.env >/dev/null; sudo chmod 600 /etc/alert.env; unset U
sudo alert-check --test
```
ปิด: `sudo systemctl disable --now alert-check.timer`

### 2.10 ชื่อบนแท็บ + ไอคอนเว็บ (29 ต.ค.) — `scripts/13-site-identity.sh`
แท็บหน้าแรกเดิมขึ้น "ComSci Burapha – เรียนรู้ สร้างสรรค์ เปลี่ยนโลกด้วยโค้ด" และไม่มีไอคอน (`/favicon.ico` → 404)
ไอคอน: ตรามหาวิทยาลัยบูรพา สีทอง `cropped-logo-if-1.png` (512×512 พื้นโปร่งใส) จากเว็บคณะวิทยาการสารสนเทศ → `site/assets/buu-seal-512.png`
```bash
scp site/assets/buu-seal-512.png wp-vps:~/wordpress-vps-project/site/assets/
scp scripts/13-site-identity.sh wp-vps:~/wordpress-vps-project/scripts/
sudo ./13-site-identity.sh
# ภายใน: wp option update blogname 'ComSci Burapha' · wp option update blogdescription ''
#        wp media import buu-seal-512.png · wp option update site_icon <ID> · wp cache-enabler clear
curl -s https://<SUBDOMAIN>.duckdns.org/ | grep -oiE '<title>[^<]*</title>|<link rel="icon"[^>]*>'
```
**ผลลัพธ์:** ✅ `<title>ComSci Burapha</title>` · หน้าอื่นเป็น "ชื่อหน้า – ComSci Burapha" · `<link rel="icon">` 32×32 และ 192×192 ตอบ 200 · CSP ไม่ต้องแก้ (เป็นรูปจาก `'self'`)
🐞 รอบแรกสคริปต์หารูปเดิมจาก slug ไม่เจอ (slug มาจากชื่อภาษาไทย) → import ซ้ำ · แก้ให้หาจากชื่อรูปแทน
เปลี่ยนจากโลโก้ตัวอักษร BUU (attachment 201, 202) เป็นตราสีทอง (attachment 203) ตามที่กลุ่มเลือก · รูป 201/202 ไม่ได้ใช้แล้ว ลบได้ใน Media
หลังเปลี่ยนไอคอน บางหน้ายังขึ้นรูปเก่าจาก micro-cache ของ nginx ไม่กี่วินาที → เปิดหน้าซ้ำแล้วหายเอง (ตรวจครบ 8 หน้า)

---

## บันทึกปัญหาที่เจอ
| วันที่ | ปัญหา | สาเหตุ | วิธีแก้ |
|---|---|---|---|
| | | | |
