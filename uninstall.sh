#!/bin/bash
set -euo pipefail

# =========================
# ZiVPN UDP Uninstaller (Ntungwa Edition)
# =========================

# Colors
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
CYAN="\033[1;36m"
RED="\033[1;31m"
RESET="\033[0m"
BOLD="\033[1m"
GRAY="\033[1;30m"

# 1 = purge deps, 0 = keep deps
: "${PURGE_DEPS:=1}"

print_task(){ echo -ne "${GRAY}•${RESET} $1..."; }
print_done(){ echo -e "\r${GREEN}✓${RESET} $1      "; }
print_warn(){ echo -e "\r${YELLOW}!${RESET} $1      "; }

run_silent() {
  local msg="$1"; shift
  print_task "$msg"
  if bash -c "$*" &>/tmp/zivpn_uninstall.log; then
    print_done "$msg"
  else
    print_warn "$msg (lihat /tmp/zivpn_uninstall.log)"
  fi
}

get_iface() {
  ip -4 route ls 2>/dev/null | awk '/default/ {print $5; exit}' || true
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo -e "${RED}Run as root!${RESET}"
    exit 1
  fi
}

clear
echo -e "${BOLD}ZiVPN UDP Uninstaller${RESET}"
echo -e "${GRAY}Ntungwa Edition${RESET}"
echo ""

need_root

API_PORT_FILE="/etc/zivpn/api_port"
API_PORT="8080"
if [[ -f "$API_PORT_FILE" ]]; then
  API_PORT="$(tr -cd '0-9' <"$API_PORT_FILE" | head -c 5)"
  [[ -z "$API_PORT" ]] && API_PORT="8080"
fi

IFACE="$(get_iface)"
[[ -z "$IFACE" ]] && IFACE="eth0"

# =========================
# Stop/Disable services (including badvpn)
# =========================
run_silent "Stopping services" "
systemctl stop zivpn.service zivpn-api.service zivpn-bot.service zivpn_backfill.service badvpn-udpgw.service 2>/dev/null || true
systemctl disable zivpn.service zivpn-api.service zivpn-bot.service zivpn_backfill.service badvpn-udpgw.service 2>/dev/null || true
# stop kemungkinan nama lain
systemctl stop zivpn zivpn-api zivpn-bot badvpn-udpgw 2>/dev/null || true
systemctl disable zivpn zivpn-api zivpn-bot badvpn-udpgw 2>/dev/null || true
"

run_silent "Killing processes" "
pkill -f '/usr/local/bin/zivpn' 2>/dev/null || true
pkill -f '/etc/zivpn/api/zivpn-api' 2>/dev/null || true
pkill -f '/etc/zivpn/api/zivpn-bot' 2>/dev/null || true
pkill -f 'zivpn-bot' 2>/dev/null || true
pkill -f 'zivpn-api' 2>/dev/null || true
pkill -f 'badvpn-udpgw' 2>/dev/null || true
"

# =========================
# Remove cron (auto-expire)
# =========================
run_silent "Removing cron auto-expire" "
crontab -l 2>/dev/null | grep -v '/api/cron/expire' | crontab - 2>/dev/null || true
rm -f /var/log/zivpn-cron.log 2>/dev/null || true
"

# =========================
# Clean network rules (iptables + ufw)
# =========================
run_silent "Cleaning iptables rules" "
# hapus semua rule yang match range UDP 6000:19999 ke :5667 (loop sampai habis)
for i in {1..20}; do
  iptables -t nat -D PREROUTING -i '${IFACE}' -p udp --dport 6000:19999 -j DNAT --to-destination :5667 2>/dev/null || break
done
"

run_silent "Cleaning UFW rules" "
if command -v ufw >/dev/null 2>&1; then
  ufw --force delete allow 6000:19999/udp 2>/dev/null || true
  ufw --force delete allow 5667/udp 2>/dev/null || true
  ufw --force delete allow ${API_PORT}/tcp 2>/dev/null || true
fi
"

# =========================
# Remove files (including badvpn binary and service file)
# =========================
run_silent "Removing ZiVPN files" "
rm -rf /etc/zivpn /usr/local/bin/zivpn /usr/local/sbin/menu /usr/local/bin/menu /usr/local/bin/menu-zivpn 2>/dev/null || true
rm -f /usr/local/bin/badvpn-udpgw /etc/systemd/system/badvpn-udpgw.service 2>/dev/null || true
rm -f /etc/systemd/system/zivpn.service /etc/systemd/system/zivpn-api.service /etc/systemd/system/zivpn-bot.service /etc/systemd/system/zivpn_backfill.service /etc/systemd/system/zivpn-firewall.service 2>/dev/null || true
rm -f /etc/zivpn-iptables-fix-applied 2>/dev/null || true
"

# =========================
# systemd reload
# =========================
run_silent "Reloading systemd" "
systemctl daemon-reload 2>/dev/null || true
systemctl reset-failed 2>/dev/null || true
systemctl daemon-reexec 2>/dev/null || true
"

# =========================
# Purge deps (optional, now prompts)
# =========================
if [[ "${PURGE_DEPS}" == "1" ]]; then
  echo ""
  echo -e "${YELLOW}Apakah Anda yakin ingin menghapus paket bawaan (golang, git, net-tools, ufw)?${NC}"
  read -rp "  (y/N) " confirm
  if [[ "${confirm,,}" == "y" ]]; then
    run_silent "Purging dependencies (optional)" "
export DEBIAN_FRONTEND=noninteractive
apt-get remove --purge -y golang git net-tools 2>/dev/null || true
# ufw cuma dipurge kalau kamu gak butuh
apt-get remove --purge -y ufw 2>/dev/null || true
apt-get autoremove --purge -y 2>/dev/null || true
apt-get autoclean -y 2>/dev/null || true
"
  else
    print_warn "Skipping dependency purge (user declined)"
  fi
else
  print_warn "Skipping dependency purge (PURGE_DEPS=0)"
fi

# =========================
# Finish
# =========================
echo ""
echo -e "${BOLD}Uninstallation Complete${RESET}"
echo -e "${GRAY}ZiVPN (Ntungwa Edition) telah dihapus dari sistem.${RESET}"
echo -e "${GRAY}Log: /tmp/zivpn_uninstall.log${RESET}"
echo ""