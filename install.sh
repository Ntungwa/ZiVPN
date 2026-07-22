#!/bin/bash
set -euo pipefail

# =========================
# CONFIG
# =========================
REPO_RAW="https://raw.githubusercontent.com/Ntungwa/ZiVPN/main"
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

detect_iface() {
  local iface
  iface="$(ip -4 route ls 2>/dev/null | awk '/default/ {print $5; exit}')"
  iface="${iface:-eth0}"
  echo "$iface"
}

iptables_add_safe() {
  local iface="$1"
  local dports="$2"
  if iptables -t nat -C PREROUTING -i "$iface" -p udp --dport "$dports" -j DNAT --to-destination :5667 &>>"$LOG_FILE"; then
    return 0
  fi
  iptables -t nat -A PREROUTING -i "$iface" -p udp --dport "$dports" -j DNAT --to-destination :5667 &>>"$LOG_FILE"
}

save_iptables_rules() {
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4 2>>"$LOG_FILE"
}

setup_firewall_persistence() {
  local iface="$1"

  print_task "Configuring firewall NAT"
  iptables_add_safe "$iface" "6000:19999"
  save_iptables_rules
  systemctl enable netfilter-persistent &>>"$LOG_FILE" || true
  systemctl restart netfilter-persistent &>>"$LOG_FILE" || true
  print_done "Configuring firewall NAT"
}

clear
: >"$LOG_FILE"

echo -e "${BOLD}ZiVPN UDP Installer${RESET}"
echo -e "${GRAY}Ntungwa Edition${RESET}"
echo ""

need_root

# =========================
# ARCHITECTURE DETECTION
# =========================
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)
    BIN_ARCH="amd64"
    ;;
  aarch64|arm64)
    BIN_ARCH="arm64"
    ;;
  armv7l|armv8l|armv7*|armv8*)
    BIN_ARCH="arm"
    ;;
  *)
    echo -e "${RED}✗${RESET} Unsupported architecture: $ARCH (only x86_64, arm64, armv7 are supported)"
    exit 1
    ;;
esac
echo -e "${GRAY}•${RESET} Detected architecture: ${CYAN}$ARCH${RESET} (using binary: ${CYAN}$BIN_ARCH${RESET})"

export DEBIAN_FRONTEND=noninteractive

# =========================
# CLEAN OLD (hard reinstall)
# =========================
if [[ -f /usr/local/bin/zivpn || -d /etc/zivpn ]]; then
  echo -e "${YELLOW}! ZiVPN detected. Reinstalling (hard reset)...${RESET}"

  svc_stop_disable_rm "zivpn-bot.service"
  svc_stop_disable_rm "zivpn-api.service"
  svc_stop_disable_rm "zivpn-firewall.service"
  svc_stop_disable_rm "zivpn.service"
  svc_stop_disable_rm "badvpn-udpgw.service"

  rm -f /etc/systemd/system/zivpn-firewall.service &>>"$LOG_FILE" || true
  systemctl daemon-reload &>>"$LOG_FILE" || true

  rm -f /usr/local/bin/zivpn &>>"$LOG_FILE" || true
  rm -f /usr/local/bin/menu-zivpn &>>"$LOG_FILE" || true
  rm -f /usr/local/bin/menu &>>"$LOG_FILE" || true
  rm -f /etc/profile.d/zivpn-menu.sh &>>"$LOG_FILE" || true
  rm -f /etc/profile.d/zivpn-welcome.sh &>>"$LOG_FILE" || true
  rm -f /etc/zivpn/api/zivpn-api /etc/zivpn/api/zivpn-bot &>>"$LOG_FILE" || true
fi

# =========================
# BASE DEPENDENCIES
# =========================
run_silent "Updating system" "apt-get update -y"
run_silent "Installing base deps" "apt-get install -y curl wget openssl ca-certificates net-tools iptables iptables-persistent netfilter-persistent zip unzip cron"

# =========================
# INSTALL BADVPN-UDPGW (build from source)
# =========================
print_task "Installing build dependencies for badvpn"
apt-get install -y cmake build-essential git &>>"$LOG_FILE" || print_fail "Installing build deps"
print_done "Build dependencies installed"

print_task "Cloning badvpn source"
git clone --depth 1 https://github.com/ambrop72/badvpn.git /tmp/badvpn &>>"$LOG_FILE" || print_fail "Cloning badvpn"
print_done "Source cloned"

print_task "Building badvpn-udpgw"
cd /tmp/badvpn
mkdir -p build
cd build
cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 &>>"$LOG_FILE" || print_fail "CMake configuration"
make -j$(nproc) &>>"$LOG_FILE" || print_fail "Make build"
cp udpgw/badvpn-udpgw /usr/local/bin/ &>>"$LOG_FILE" || print_fail "Installing binary"
chmod +x /usr/local/bin/badvpn-udpgw
cd /
rm -rf /tmp/badvpn
print_done "badvpn-udpgw built and installed to /usr/local/bin"

print_task "Detecting timezone from server location"
TZ_IP="$(curl -s --fail https://ipapi.co/timezone 2>/dev/null || echo "UTC")"
timedatectl set-timezone "$TZ_IP" &>>"$LOG_FILE" || true
print_done "Timezone set to $TZ_IP"

run_silent "Enabling cron service" "systemctl enable --now cron || true"

if ! command -v go &>/dev/null; then
  run_silent "Installing Golang" "apt-get install -y golang git"
else
  print_done "Golang ready"
fi

# =========================
# INPUT DOMAIN ONLY
# =========================
echo ""
echo -ne "${BOLD}Domain Configuration${RESET}\n"
while true; do
  read -rp "Enter Domain: " domain
  [[ -n "${domain:-}" ]] && break
done
echo ""

# API key otomatis
api_key="$(openssl rand -hex 16)"

# =========================
# INSTALL CORE + CONFIG
# =========================
# Download the binary for the detected architecture
BINARY_URL="https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-${BIN_ARCH}"
run_silent "Downloading Core (${BIN_ARCH})" "wget -q ${BINARY_URL} -O /usr/local/bin/zivpn && chmod +x /usr/local/bin/zivpn"

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

print_task "Configuring welcome text"
cat >/etc/profile.d/zivpn-welcome.sh <<'EOF'
#!/bin/bash
case "$-" in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac

[ -t 0 ] || return 0 2>/dev/null || exit 0

if [ "$(id -u)" = "0" ]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " Welcome To Ntungwa ZiVPN"
  echo " Type 'menu' to open the panel"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
fi
EOF
chmod +x /etc/profile.d/zivpn-welcome.sh &>>"$LOG_FILE" || true
rm -f /etc/profile.d/zivpn-menu.sh &>>"$LOG_FILE" || true
print_done "Configuring welcome text"

run_silent "Generating SSL" "openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 -subj '/C=US/ST=California/L=San Francisco/O=Ntungwa/OU=IT Department/CN=$domain' -keyout /etc/zivpn/zivpn.key -out /etc/zivpn/zivpn.crt"

# =========================
# API PORT
# =========================
print_task "Finding available API Port"
API_PORT=8080
while netstat -tuln 2>/dev/null | grep -q ":$API_PORT "; do
  ((API_PORT++))
done
echo "$API_PORT" > /etc/zivpn/api_port
print_done "API Port selected: ${CYAN}$API_PORT${RESET}"

# =========================
# SYSCTL
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
# FIREWALL + NAT (SETUP FIRST)
# =========================
iface="$(detect_iface)"
setup_firewall_persistence "$iface"

ufw_allow_safe "6000:19999/udp"
ufw_allow_safe "5667/udp"
ufw_allow_safe "${API_PORT}/tcp"

# =========================
# SYSTEMD: FIREWALL RESTORE SERVICE
# =========================
cat >/etc/systemd/system/zivpn-firewall.service <<EOF
[Unit]
Description=ZiVPN Firewall Restore
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# =========================
# SYSTEMD: CORE SERVICE
# =========================
cat >/etc/systemd/system/zivpn.service <<EOF
[Unit]
Description=ZiVPN UDP VPN Server (Ntungwa)
Wants=network-online.target
After=network-online.target netfilter-persistent.service zivpn-firewall.service
Requires=zivpn-firewall.service

[Service]
Type=simple
User=root
WorkingDirectory=/etc/zivpn
ExecStart=/usr/local/bin/zivpn server -c /etc/zivpn/config.json
Restart=always
RestartSec=3
StartLimitIntervalSec=0
LimitNOFILE=65535
Environment=ZIVPN_LOG_LEVEL=info
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

# =========================
# SYSTEMD: BADVPN-UDPGW SERVICE
# =========================
cat >/etc/systemd/system/badvpn-udpgw.service <<EOF
[Unit]
Description=BadVPN UDP Gateway
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 1000 --max-connections-for-client 10
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

# =========================
# DOWNLOAD + BUILD API
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
Description=ZiVPN Golang API Service (Ntungwa)
Wants=network-online.target
After=network-online.target zivpn.service

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
# ENABLE + START SERVICES
# =========================
run_silent "Reloading systemd" "systemctl daemon-reload"
run_silent "Enabling firewall restore" "systemctl enable --now netfilter-persistent zivpn-firewall.service"
run_silent "Starting core" "systemctl enable --now zivpn.service"
run_silent "Starting API" "systemctl enable --now zivpn-api.service"
run_silent "Starting badvpn-udpgw" "systemctl enable --now badvpn-udpgw.service"

# =========================
# CRON AUTO-EXPIRE
# =========================
print_task "Configuring Cron Auto-Expire"
if ! command -v crontab >/dev/null 2>&1; then
  print_fail "Configuring Cron Auto-Expire"
fi

run_silent "Ensuring cron is running" "systemctl enable --now cron || true"

cron_cmd='0 0 * * * /usr/bin/curl -s -X POST -H "X-API-Key: $(cat /etc/zivpn/apikey)" http://127.0.0.1:$(cat /etc/zivpn/api_port)/api/cron/expire >> /var/log/zivpn-cron.log 2>&1'
(crontab -l 2>/dev/null | grep -v "/api/cron/expire" || true; echo "$cron_cmd") | crontab - &>>"$LOG_FILE" || print_fail "Configuring Cron Auto-Expire"
print_done "Configuring Cron Auto-Expire"

# =========================
# FINAL SAVE IPTABLES AGAIN
# =========================
print_task "Saving iptables rules"
save_iptables_rules
print_done "Saving iptables rules"

# =========================
# FINISH
# =========================
hash -r || true

echo ""
echo -e "${BOLD}Installation Complete${RESET}"
echo -e "Arch    : ${CYAN}$ARCH (binary: $BIN_ARCH)${RESET}"
echo -e "Domain  : ${CYAN}$domain${RESET}"
echo -e "API     : ${CYAN}$API_PORT${RESET}"
echo -e "API Key : ${CYAN}$api_key${RESET}"
echo -e "Iface   : ${CYAN}$iface${RESET}"
echo -e "Menu    : ${CYAN}menu-zivpn / menu${RESET}"
echo -e "Bot     : ${CYAN}not installed${RESET}"
echo -e "Login   : ${CYAN}normal, does not auto-open menu${RESET}"
echo -e "Timezone: ${CYAN}$TZ_IP${RESET}"
echo ""
echo -e "${GRAY}Log: $LOG_FILE${RESET}"