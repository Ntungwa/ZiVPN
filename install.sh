#!/bin/bash
set -euo pipefail

# =========================
# CONFIG
# =========================
REPO_RAW="https://raw.githubusercontent.com/YINNSTORE/ZIVPN/main"
TS="$(date +%s)"

# Colors
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
CYAN="\033[1;36m"
RED="\033[1;31m"
BLUE="\033[1;34m"
RESET="\033[0m"
BOLD="\033[1m"
GRAY="\033[1;30m"

LOG_FILE="/tmp/zivpn_install.log"

print_task() { echo -ne "${GRAY}•${RESET} $1..."; }
print_done() { echo -e "\r${GREEN}✓${RESET} $1      "; }
print_fail() { echo -e "\r${RED}✗${RESET} $1      "; echo -e "${RED}Log:${RESET} $LOG_FILE"; exit 1; }

run_silent() {
  local msg="$1"
  local cmd="$2"
  print_task "$msg"
  bash -c "$cmd" &>>"$LOG_FILE" || print_fail "$msg"
  print_done "$msg"
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo -e "${RED}✗ Run as root!${RESET}"
    exit 1
  fi
}

raw_get() {
  local url="$1"
  local out="$2"
  curl -fsSL "${url}?ts=${TS}" -o "$out" &>>"$LOG_FILE"
}

raw_wget() {
  local url="$1"
  local out="$2"
  wget -q "${url}?ts=${TS}" -O "$out" &>>"$LOG_FILE"
}

svc_stop_disable_rm() {
  local s="$1"
  systemctl stop "$s" &>>"$LOG_FILE" || true
  systemctl disable "$s" &>>"$LOG_FILE" || true
  rm -f "/etc/systemd/system/$s" &>>"$LOG_FILE" || true
}

ufw_allow_safe() {
  local rule="$1"
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "$rule" &>>"$LOG_FILE" || true
  fi
}

iptables_add_safe() {
  local iface="$1"
  local dports="$2"
  if iptables -t nat -C PREROUTING -i "$iface" -p udp --dport "$dports" -j DNAT --to-destination :5667 &>>"$LOG_FILE"; then
    return 0
  fi
  iptables -t nat -A PREROUTING -i "$iface" -p udp --dport "$dports" -j DNAT --to-destination :5667 &>>"$LOG_FILE" || true
}

clear
echo -e "${BOLD}ZiVPN UDP Installer${RESET}"
echo -e "${GRAY}YinnStore Edition${RESET}"
echo ""

need_root

if [[ "$(uname -s)" != "Linux" ]] || [[ "$(uname -m)" != "x86_64" ]]; then
  echo -e "${RED}✗${RESET} System not supported (Linux AMD64 only)"
  exit 1
fi

# =========================
# CLEAN OLD (hard reinstall)
# =========================
if [[ -f /usr/local/bin/zivpn || -d /etc/zivpn ]]; then
  echo -e "${YELLOW}! ZiVPN detected. Reinstalling (hard reset)...${RESET}"

  svc_stop_disable_rm "zivpn-bot.service"
  svc_stop_disable_rm "zivpn-api.service"
  svc_stop_disable_rm "zivpn.service"

  systemctl daemon-reload &>>"$LOG_FILE" || true

  rm -f /usr/local/bin/zivpn &>>"$LOG_FILE" || true
  rm -f /usr/local/bin/menu-zivpn &>>"$LOG_FILE" || true
  rm -f /usr/local/bin/menu &>>"$LOG_FILE" || true
  rm -f /etc/profile.d/zivpn-menu.sh &>>"$LOG_FILE" || true
  rm -f /etc/zivpn/api/zivpn-api /etc/zivpn/api/zivpn-bot &>>"$LOG_FILE" || true
fi

# =========================
# BASE DEPENDENCIES
# =========================
run_silent "Updating system" "apt-get update -y"
run_silent "Installing base deps" "apt-get install -y curl wget openssl ca-certificates net-tools iptables zip unzip"
run_silent "Setting Timezone" "timedatectl set-timezone Asia/Jakarta || true"

if ! command -v go &>/dev/null; then
  run_silent "Installing Golang" "apt-get install -y golang git"
else
  print_done "Golang ready"
fi

# =========================
# INPUT DOMAIN + API KEY
# =========================
echo ""
echo -ne "${BOLD}Domain Configuration${RESET}\n"
while true; do
  read -rp "Enter Domain: " domain
  [[ -n "${domain:-}" ]] && break
done
echo ""

echo -ne "${BOLD}API Key Configuration${RESET}\n"
generated_key="$(openssl rand -hex 16)"
echo -e "Generated Key: ${CYAN}$generated_key${RESET}"
read -rp "Enter API Key (Press Enter to use generated): " input_key
api_key="${input_key:-$generated_key}"
echo -e "Using Key: ${GREEN}$api_key${RESET}"
echo ""

# =========================
# INSTALL CORE + CONFIG
# =========================
run_silent "Downloading Core" "wget -q https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64 -O /usr/local/bin/zivpn && chmod +x /usr/local/bin/zivpn"

mkdir -p /etc/zivpn /etc/zivpn/api
echo "$domain" > /etc/zivpn/domain
echo "$api_key" > /etc/zivpn/apikey

print_task "Downloading config.json (anti-cache)"
raw_wget "${REPO_RAW}/config.json" "/etc/zivpn/config.json" || print_fail "Downloading config.json"
sed -i 's/\r$//' /etc/zivpn/config.json &>>"$LOG_FILE" || true
print_done "Downloading config.json (anti-cache)"

print_task "Downloading VPS menu"
raw_wget "${REPO_RAW}/menu.sh" "/usr/local/bin/menu-zivpn" || print_fail "Downloading VPS menu"
sed -i 's/\r$//' /usr/local/bin/menu-zivpn &>>"$LOG_FILE" || true
chmod +x /usr/local/bin/menu-zivpn &>>"$LOG_FILE" || true

cat >/usr/local/bin/menu <<'EOF'
#!/bin/bash
exec /usr/local/bin/menu-zivpn "$@"
EOF
chmod +x /usr/local/bin/menu &>>"$LOG_FILE" || true
print_done "Downloading VPS menu"

print_task "Configuring auto menu on login"
cat >/etc/profile.d/zivpn-menu.sh <<'EOF'
#!/bin/bash

case "$-" in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac

[ -t 0 ] || return 0 2>/dev/null || exit 0

[[ "${ZIVPN_MENU_ACTIVE:-0}" == "1" ]] && return 0 2>/dev/null || exit 0

if [ "$(id -u)" != "0" ]; then
  return 0 2>/dev/null || exit 0
fi

export ZIVPN_MENU_ACTIVE=1
/usr/local/bin/menu-zivpn
EOF
chmod +x /etc/profile.d/zivpn-menu.sh &>>"$LOG_FILE" || true
print_done "Configuring auto menu on login"

run_silent "Generating SSL" "openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 -subj '/C=ID/ST=Jawa Barat/L=Bandung/O=YINNSTORE/OU=IT Department/CN=$domain' -keyout /etc/zivpn/zivpn.key -out /etc/zivpn/zivpn.crt"

# =========================
# API PORT (FREE)
# =========================
print_task "Finding available API Port"
API_PORT=8080
while netstat -tuln 2>/dev/null | grep -q ":$API_PORT "; do
  ((API_PORT++))
done
echo "$API_PORT" > /etc/zivpn/api_port
print_done "API Port selected: ${CYAN}$API_PORT${RESET}"

# =========================
# SYSCTL (NO DUPLICATE)
# =========================
print_task "Applying sysctl tunings"
cat >/etc/sysctl.d/99-zivpn.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward=1
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=16777216
net.core.wmem_default=16777216
net.core.optmem_max=65536
net.core.somaxconn=65535
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.tcp_fastopen=3
fs.file-max=1000000
net.core.netdev_max_backlog=16384
net.ipv4.udp_mem=65536 131072 262144
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
EOF
sysctl --system &>>"$LOG_FILE" || true
print_done "Applying sysctl tunings"

# =========================
# SYSTEMD: CORE SERVICE
# =========================
cat >/etc/systemd/system/zivpn.service <<EOF
[Unit]
Description=ZIVPN UDP VPN Server (YinnStore)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/zivpn
ExecStart=/usr/local/bin/zivpn server -c /etc/zivpn/config.json
Restart=always
RestartSec=3
LimitNOFILE=65535
Environment=ZIVPN_LOG_LEVEL=info
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

# =========================
# DOWNLOAD + BUILD API (ANTI-CACHE)
# =========================
print_task "Downloading API sources (anti-cache)"
raw_wget "${REPO_RAW}/zivpn-api.go" "/etc/zivpn/api/zivpn-api.go" || print_fail "Downloading zivpn-api.go"
raw_wget "${REPO_RAW}/go.mod" "/etc/zivpn/api/go.mod" || print_fail "Downloading go.mod"
sed -i 's/\r$//' /etc/zivpn/api/zivpn-api.go &>>"$LOG_FILE" || true
sed -i 's/\r$//' /etc/zivpn/api/go.mod &>>"$LOG_FILE" || true
print_done "Downloading API sources (anti-cache)"

print_task "Compiling API"
cd /etc/zivpn/api
rm -f /etc/zivpn/api/zivpn-api &>>"$LOG_FILE" || true
go env -w GOPROXY=https://proxy.golang.org,direct &>>"$LOG_FILE" || true
go mod tidy &>>"$LOG_FILE" || true
go build -o zivpn-api zivpn-api.go &>>"$LOG_FILE" || print_fail "Compiling API"
print_done "Compiling API"

cat >/etc/systemd/system/zivpn-api.service <<EOF
[Unit]
Description=ZiVPN Golang API Service (YinnStore)
After=network.target zivpn.service

[Service]
Type=simple
User=root
WorkingDirectory=/etc/zivpn/api
ExecStart=/etc/zivpn/api/zivpn-api
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# =========================
# BOT SETUP (PAID ONLY)
# =========================
echo ""
echo -ne "${BOLD}Telegram Bot Configuration${RESET}\n"
echo -ne "${GRAY}(Leave empty to skip)${RESET}\n"
read -rp "Bot Token: " bot_token
read -rp "Admin ID : " admin_id

if [[ -n "${bot_token:-}" && -n "${admin_id:-}" ]]; then
  cat >/etc/zivpn/bot-config.json <<EOF
{"bot_token":"$bot_token","admin_id":$admin_id,"mode":"public","domain":"$domain","pakasir_slug":"","pakasir_api_key":"","daily_price":0}
EOF

  bot_file="zivpn-paid-bot.go"

  print_task "Downloading Bot source (anti-cache)"
  raw_wget "${REPO_RAW}/${bot_file}" "/etc/zivpn/api/${bot_file}" || print_fail "Downloading bot source"
  sed -i 's/\r$//' "/etc/zivpn/api/${bot_file}" &>>"$LOG_FILE" || true
  print_done "Downloading Bot source (anti-cache)"

  print_task "Compiling Bot"
  cd /etc/zivpn/api
  rm -f /etc/zivpn/api/zivpn-bot &>>"$LOG_FILE" || true
  go mod tidy &>>"$LOG_FILE" || true
  go get github.com/go-telegram-bot-api/telegram-bot-api/v5 &>>"$LOG_FILE" || true
  go build -o zivpn-bot "${bot_file}" &>>"$LOG_FILE" || print_fail "Compiling Bot"
  print_done "Compiling Bot"

  cat >/etc/systemd/system/zivpn-bot.service <<EOF
[Unit]
Description=ZiVPN Telegram Bot Paid (YinnStore)
After=network.target zivpn-api.service

[Service]
Type=simple
User=root
WorkingDirectory=/etc/zivpn/api
ExecStart=/etc/zivpn/api/zivpn-bot
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
else
  print_done "Skipping Bot Setup"
fi

# =========================
# ENABLE + START SERVICES
# =========================
run_silent "Reloading systemd" "systemctl daemon-reload"
run_silent "Starting core" "systemctl enable --now zivpn.service"
run_silent "Starting API" "systemctl enable --now zivpn-api.service"

if [[ -f /etc/systemd/system/zivpn-bot.service ]]; then
  run_silent "Starting Bot" "systemctl enable --now zivpn-bot.service"
fi

# =========================
# CRON AUTO-EXPIRE (SAFE)
# =========================
print_task "Configuring Cron Auto-Expire"
cron_cmd='0 0 * * * /usr/bin/curl -s -X POST -H "X-API-Key: $(cat /etc/zivpn/apikey)" http://127.0.0.1:$(cat /etc/zivpn/api_port)/api/cron/expire >> /var/log/zivpn-cron.log 2>&1'
(crontab -l 2>/dev/null | grep -v "/api/cron/expire" || true; echo "$cron_cmd") | crontab -
print_done "Configuring Cron Auto-Expire"

# =========================
# FIREWALL + NAT (SAFE)
# =========================
iface="$(ip -4 route ls 2>/dev/null | awk '/default/ {print $5; exit}')"
iface="${iface:-eth0}"

iptables_add_safe "$iface" "6000:19999"

ufw_allow_safe "6000:19999/udp"
ufw_allow_safe "5667/udp"
ufw_allow_safe "${API_PORT}/tcp"

# =========================
# FINISH
# =========================
hash -r || true

echo ""
echo -e "${BOLD}Installation Complete${RESET}"
echo -e "Domain  : ${CYAN}$domain${RESET}"
echo -e "API     : ${CYAN}$API_PORT${RESET}"
echo -e "Token   : ${CYAN}$api_key${RESET}"
echo -e "Menu    : ${CYAN}menu-zivpn / menu${RESET}"
echo -e "Auto    : ${CYAN}menu tampil otomatis saat login root${RESET}"
echo -e "Dev     : ${CYAN}https://t.me/yinnprovpn${RESET}"
echo ""
echo -e "${GRAY}Log: $LOG_FILE${RESET}"