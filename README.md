# 🚀 YINNSTORE ZiVPN UDP Tunnel

> **YINNSTORE ZiVPN UDP Tunnel** adalah solusi tunneling UDP premium yang ringan, cepat, dan mudah dikelola.  
> Dilengkapi dengan **API Server**, **Telegram Bot**, **VPS Menu Panel**, serta sistem **Backup & Restore** untuk mempermudah pengelolaan akun di VPS.

---

## ✨ Fitur Utama

### ⚡ Core & Performa
- **ZiVPN UDP Core** yang ringan dan stabil
- Optimasi performa untuk penggunaan jangka panjang
- Support manajemen akun via **API**, **Bot**, dan **Menu VPS**

### 🔐 Security
- **API Key** dibuat otomatis saat instalasi
- Sertifikat SSL digenerate otomatis
- Validasi akses API menggunakan header `X-API-Key`

### 👤 User Management
- Create akun premium
- Create akun trial berbasis **menit**
- Renew akun
- Delete akun
- List semua akun
- Auto revoke akun expired

### 🤖 Telegram Bot Integration
- Pembuatan akun via bot
- Trial akun via bot
- Notifikasi akun dibuat / trial / renew / delete
- Panel admin untuk pengelolaan data
- Support pengelolaan server ZiVPN

### 🖥️ VPS Menu Panel
- Create akun langsung dari VPS
- Create trial dari VPS
- Renew akun
- Delete akun
- Backup & Restore data
- Cek running system
- Speedtest VPS
- Monitoring informasi server

### 💾 Backup & Restore
- Backup data server ke file ZIP
- Restore data dari file ZIP
- Cocok untuk migrasi data antar VPS yang **sudah diinstal script ZiVPN**

---

## 📦 Isi Project

Project ini umumnya terdiri dari beberapa komponen utama:

- **Core ZiVPN**
- **API Server**
- **Telegram Bot**
- **Menu VPS**
- **Installer**
- **Uninstaller**
- **Konfigurasi systemd & config.json**

---

## 📥 Instalasi

Jalankan perintah berikut di VPS sebagai **root**:

```bash
wget -q https://raw.githubusercontent.com/Ntungwa/ZIVPN/refs/heads/main/install.sh && chmod +x install.sh && ./install.sh
