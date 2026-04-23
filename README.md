# proxy-wrapper

**SOCKS5 proxy server trung gian** – nhận kết nối SOCKS5 từ client, forward qua upstream SOCKS5 proxy đã thuê, đồng thời tune TCP/IP stack của VPS để giả lập OS fingerprint Windows 10 ở lớp mạng.

```
Client (browser/app)
       │  SOCKS5
       ▼
  proxy-wrapper  ← TCP stack: TTL=128, no timestamps, MSS=1460 …
  (VPS của bạn)
       │  SOCKS5 + user/pass
       ▼
Upstream proxy (proxy thuê)
       │
       ▼
  Internet
```

---

## Cấu trúc project

```
proxy-wrapper/
├── src/
│   └── index.js       # SOCKS5 proxy server (Node.js)
├── setup-tcp.sh       # Tune TCP/IP stack (TTL, timestamps, TCPMSS …)
├── install.sh         # Cài đặt tự động
├── verify.sh          # Kiểm tra thông số sau khi setup
├── proxy.service      # Systemd unit file
├── .env.example       # Template cấu hình
└── README.md
```

---

## Deploy lên VPS Ubuntu 22.04 (từng bước)

### Bước 1 – SSH vào VPS

```bash
ssh root@<VPS_IP>
```

### Bước 2 – Tải project

```bash
cd /tmp
git clone https://github.com/yourrepo/proxy-wrapper.git
# hoặc upload bằng scp:
# scp -r proxy-wrapper/ root@<VPS_IP>:/tmp/
```

### Bước 3 – Cài đặt tự động

```bash
cd /tmp/proxy-wrapper
chmod +x install.sh setup-tcp.sh verify.sh
sudo bash install.sh
```

Script `install.sh` sẽ tự động:
- Cài Node.js 20 LTS (nếu chưa có)
- Copy project vào `/opt/proxy-wrapper/`
- Chạy `npm install`
- Tạo system user `proxywrapper`
- Chạy `setup-tcp.sh` (tune TCP stack)
- Cài và enable systemd service

### Bước 4 – Cấu hình upstream proxy

```bash
nano /opt/proxy-wrapper/.env
```

Điền thông tin proxy bạn đã thuê:

```dotenv
UPSTREAM_HOST=proxy.example.com
UPSTREAM_PORT=1080
UPSTREAM_USER=your_username
UPSTREAM_PASS=your_password

LISTEN_HOST=0.0.0.0
LISTEN_PORT=1080
CONN_TIMEOUT=30000
```

> **Lưu ý bảo mật:** file `.env` được chmod 600, chỉ user `proxywrapper` đọc được.

### Bước 5 – Khởi động service

```bash
systemctl start proxy-wrapper
systemctl status proxy-wrapper
```

### Bước 6 – Verify

```bash
bash /opt/proxy-wrapper/verify.sh
```

Output mẫu:

```
══════════════════════════════════════════════
  TTL
══════════════════════════════════════════════
  ✔  net.ipv4.ip_default_ttl = 128  (Windows 10 default)

══════════════════════════════════════════════
  TCP Timestamps
══════════════════════════════════════════════
  ✔  net.ipv4.tcp_timestamps = 0  (disabled)

  ...

══════════════════════════════════════════════
  Proxy Connectivity Test
══════════════════════════════════════════════
  ✔  Proxy is working. Exit IP = 1.2.3.4
```

---

## Mở firewall (nếu cần)

```bash
# ufw
ufw allow 1080/tcp
ufw reload

# hoặc iptables
iptables -A INPUT -p tcp --dport 1080 -j ACCEPT
```

---

## Verify OS fingerprint sau khi setup

### Dùng nmap từ máy khác để scan VPS

```bash
# Chạy từ máy local / máy khác, scan vào IP VPS
nmap -O <VPS_IP>
```

Kết quả mong muốn – OS detection sẽ hiện Windows hoặc unknown thay vì Linux:

```
OS details: Microsoft Windows 10 1709 - 1909
```

> nmap đoán OS dựa trên TTL và TCP options, nên TTL=128 + no timestamps + MSS=1460 sẽ khiến nó ngả về Windows.

### Dùng p0f (passive fingerprinting)

```bash
# Cài p0f trên máy cần monitor
sudo apt install p0f
sudo p0f -i eth0 -p

# Sau đó truy cập web qua proxy, xem p0f report
```

### Kiểm tra TTL của packet thực tế

```bash
# Ping từ máy khác vào VPS, xem TTL trong reply
ping <VPS_IP>
# Linux trả về TTL=64 → sau khi tune sẽ trả về TTL=128
```

### Test fingerprint online

Truy cập qua proxy vào các site fingerprint:
- https://browserleaks.com/ip
- https://ipleak.net
- https://whoer.net

---

## Quản lý service

```bash
# Start / stop / restart
systemctl start   proxy-wrapper
systemctl stop    proxy-wrapper
systemctl restart proxy-wrapper

# Xem log realtime
journalctl -u proxy-wrapper -f

# Xem 50 dòng log gần nhất
journalctl -u proxy-wrapper -n 50

# Reload sau khi sửa .env
systemctl restart proxy-wrapper
```

---

## Cập nhật TCP tuning thủ công

```bash
# Apply lại sau khi reboot hoặc thay đổi
sudo bash /opt/proxy-wrapper/setup-tcp.sh

# Kiểm tra
sudo bash /opt/proxy-wrapper/verify.sh
```

---

## Troubleshooting

### Service không start

```bash
journalctl -u proxy-wrapper -n 30 --no-pager
```

Lỗi thường gặp:
| Lỗi | Nguyên nhân | Cách sửa |
|-----|-------------|----------|
| `UPSTREAM_HOST and UPSTREAM_PORT must be set` | `.env` chưa cấu hình | Điền `UPSTREAM_HOST` và `UPSTREAM_PORT` vào `.env` |
| `EADDRINUSE` | Port 1080 đang bị chiếm | `ss -tlnp \| grep 1080` để tìm process, hoặc đổi `LISTEN_PORT` |
| `EACCES` | Không có quyền bind port < 1024 | Dùng port ≥ 1024 hoặc bật `AmbientCapabilities` trong `.service` |

### Proxy không forward được

```bash
# Test upstream proxy trực tiếp (không qua wrapper)
curl --proxy socks5h://<USER>:<PASS>@<UPSTREAM_HOST>:<UPSTREAM_PORT> https://ifconfig.me

# Test wrapper
curl --proxy socks5h://127.0.0.1:1080 https://ifconfig.me
```

Nếu upstream test OK nhưng wrapper fail → kiểm tra log service.

### TTL không thay đổi sau reboot

Kiểm tra file sysctl có được load:

```bash
sysctl --system
sysctl net.ipv4.ip_default_ttl
```

Nếu vẫn không đúng:

```bash
echo "net.ipv4.ip_default_ttl = 128" >> /etc/sysctl.conf
sysctl -p
```

### iptables rules mất sau reboot

```bash
# Lưu rules
iptables-save > /etc/iptables/rules.v4

# Đảm bảo iptables-persistent chạy
apt install iptables-persistent -y
systemctl enable netfilter-persistent
```

### Kiểm tra MTU thực tế

```bash
ip link show eth0 | grep mtu
# Hoặc
ping -M do -s 1472 <gateway_IP>  # 1472 + 28 header = 1500 bytes
```

### Log proxy xem traffic

```bash
# Xem tunnel logs realtime
journalctl -u proxy-wrapper -f | grep "tunnel"
```

---

## Lưu ý bảo mật

- Proxy wrapper **không yêu cầu auth** từ client (thiết kế cho trusted local network / VPS cá nhân). Không mở port ra internet public nếu không cần.
- File `.env` chứa credentials upstream – **không commit vào git**.
- Service chạy dưới user `proxywrapper` với privilege tối thiểu (`NoNewPrivileges`, `PrivateTmp`).
- Nếu muốn thêm SOCKS5 auth phía client, mở issue hoặc chỉnh `src/index.js` để thêm `METHOD_USERNAME_PASSWORD (0x02)`.

---

## Giải thích kỹ thuật TCP fingerprint

| Tham số | Linux mặc định | Windows 10 | Sau khi tune |
|---------|---------------|------------|--------------|
| TTL | 64 | **128** | **128** |
| TCP Timestamps | ON | **OFF** | **OFF** |
| SACK | ON | ON | ON |
| Window Scaling | ON | ON | ON |
| ECN | varies | **OFF** | **OFF** |
| MSS | 1460 (1500 MTU) | 1460 | **1460** |
| Initial Window | ~29200 | 65535 | 65535 |

Các công cụ như `p0f`, `nmap -O`, và hệ thống fraud detection phân tích các thông số này để đoán OS. Sau khi tune, VPS của bạn sẽ trả về fingerprint gần giống Windows 10 hơn Linux.
