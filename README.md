# 🚀 Ntungwa ZiVPN UDP Tunnel

> **Ntungwa ZiVPN UDP Tunnel** is a lightweight, fast, and easy-to-manage premium UDP tunneling solution.  
> Equipped with an **API Server**, **Telegram Bot**, **VPS Menu Panel**, and a **Backup & Restore** system to simplify account management on your VPS.

---

## ✨ Key Features

### ⚡ Core & Performance
- **ZiVPN UDP Core** that is lightweight and stable
- Performance optimised for long-term usage
- Account management support via **API**, **Bot**, and **VPS Menu**

### 🔐 Security
- **API Key** automatically generated during installation
- SSL certificate auto-generated
- API access validated using the `X-API-Key` header

### 👤 User Management
- Create premium accounts
- Create trial accounts based on **minutes**
- Renew accounts
- Delete accounts
- List all accounts
- Auto-revoke expired accounts

### 🤖 Telegram Bot Integration
- Account creation via bot
- Trial account creation via bot
- Notifications for account creation / trial / renewal / deletion
- Admin panel for data management
- Support for managing ZiVPN servers

### 🖥️ VPS Menu Panel
- Create accounts directly from the VPS
- Create trial accounts from the VPS
- Renew accounts
- Delete accounts
- Backup & Restore data
- Check running system
- VPS speedtest
- Server information monitoring

### 💾 Backup & Restore
- Backup server data to a ZIP file
- Restore data from a ZIP file
- Ideal for migrating data between VPS instances that already have the ZiVPN script installed

---

## 📦 Project Contents

This project generally consists of the following main components:

- **ZiVPN Core**
- **API Server**
- **Telegram Bot**
- **VPS Menu**
- **Installer**
- **Uninstaller**
- **Systemd** & **config.json** configuration

---

## 📥 Installation

Run the following command on your VPS as **root**:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Ntungwa/ZiVPN/main/install.sh)
```

---

## 🗑️ Uninstall

To completely remove ZiVPN and all its components from your system, run:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Ntungwa/ZiVPN/main/uninstall.sh)
```

**This will remove:**

· All ZiVPN services (`zivpn.service`, `zivpn-api.service`, `zivpn-bot.service`, `zivpn-firewall.service`)  
· `badvpn-udpgw` service and binary  
· Configuration files (`/etc/zivpn/*`)  
· API binaries and sources  
· Cron jobs (auto-expiry)  
· iptables NAT rules and UFW rules

---

### 🧹 Purge Dependencies (optional)

The uninstall script can also remove build dependencies (`golang`, `git`, `net-tools`, `ufw`). It will **ask for confirmation** before purging.

If you want to skip the dependency purge, set `PURGE_DEPS=0`:

```bash
PURGE_DEPS=0 bash <(curl -fsSL https://raw.githubusercontent.com/Ntungwa/ZiVPN/main/uninstall.sh)
```

---

### 🧼 Manual Cleanup

If the uninstall script fails or you want to clean up manually:

```bash
systemctl stop zivpn.service zivpn-api.service zivpn-bot.service badvpn-udpgw.service 2>/dev/null || true
systemctl disable zivpn.service zivpn-api.service zivpn-bot.service badvpn-udpgw.service 2>/dev/null || true
rm -rf /etc/zivpn /usr/local/bin/zivpn /usr/local/bin/menu-zivpn /usr/local/bin/badvpn-udpgw
rm -f /etc/systemd/system/zivpn*.service /etc/systemd/system/badvpn-udpgw.service
systemctl daemon-reload
iptables -t nat -D PREROUTING -i $(ip -4 route ls | awk '/default/ {print $5; exit}') -p udp --dport 6000:19999 -j DNAT --to-destination :5667 2>/dev/null || true
```

---

## 📝 Logs

· Installation log: `/tmp/zivpn_install.log`  
· Uninstallation log: `/tmp/zivpn_uninstall.log`

---

## 📁 Repository Structure

```
ZiVPN/
├── install.sh      # Main installer (Ntungwa Edition)
├── uninstall.sh    # Complete removal script
├── menu.sh         # VPS management menu
├── config.json     # Default VPN configuration
├── zivpn-api.go    # Go API server source
├── go.mod          # Go module dependencies
└── README.md       # This file
```

---

## 📞 Support

For issues or questions, contact our Telegram channel: [@Ntungwa](https://t.me/Ntungwa)

---

## ⚠️ Disclaimer

This project is provided as-is for educational and personal use. The developer is not responsible for any misuse or damages caused by this software.
