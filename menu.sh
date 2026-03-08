#!/bin/bash
set -euo pipefail

# =========================
# ZiVPN VPS Menu
# YinnStore Edition
# =========================

API_KEY_FILE="/etc/zivpn/apikey"
API_PORT_FILE="/etc/zivpn/api_port"
DOMAIN_FILE="/etc/zivpn/domain"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
BOLD='\033[1m'
GRAY='\033[1;30m'
NC='\033[0m'

TRIAL_DAYS=1
BASE_URL=""

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo -e "${RED}Run as root!${NC}"
    exit 1
  fi
}

load_env() {
  [[ -f "$API_KEY_FILE" ]] || { echo -e "${RED}API key file not found: $API_KEY_FILE${NC}"; exit 1; }
  [[ -f "$API_PORT_FILE" ]] || { echo -e "${RED}API port file not found: $API_PORT_FILE${NC}"; exit 1; }

  API_KEY="$(tr -d '\r\n' < "$API_KEY_FILE")"
  API_PORT="$(tr -d '\r\n' < "$API_PORT_FILE")"
  DOMAIN="-"
  [[ -f "$DOMAIN_FILE" ]] && DOMAIN="$(tr -d '\r\n' < "$DOMAIN_FILE")"

  BASE_URL="http://127.0.0.1:${API_PORT}"
}

header() {
  clear
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║         ZiVPN VPS MENU PANEL        ║${NC}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════╝${NC}"
  echo -e "${GRAY}Domain :${NC} ${DOMAIN}"
  echo -e "${GRAY}API    :${NC} ${BASE_URL}"
  echo ""
}

pause() {
  echo ""
  read -rp "Press Enter to continue..."
}

json_value() {
  local key="$1"
  sed -n "s/.*\"${key}\":[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1
}

api_post() {
  local endpoint="$1"
  local payload="$2"

  curl -sS -X POST "${BASE_URL}${endpoint}" \
    -H "Content-Type: application/json" \
    -H "X-API-Key: ${API_KEY}" \
    -d "${payload}"
}

api_get() {
  local endpoint="$1"

  curl -sS "${BASE_URL}${endpoint}" \
    -H "X-API-Key: ${API_KEY}"
}

print_result() {
  local body="$1"
  local success
  local message

  success="$(echo "$body" | sed -n 's/.*"success":[[:space:]]*\(true\|false\).*/\1/p' | head -n1)"
  message="$(echo "$body" | json_value "message")"

  if [[ "$success" == "true" ]]; then
    echo -e "${GREEN}✔ ${message:-Success}${NC}"
  else
    echo -e "${RED}✘ ${message:-Request failed}${NC}"
  fi
}

create_account() {
  header
  echo -e "${BOLD}CREATE ACCOUNT${NC}"
  echo ""

  read -rp "Username/password account: " username
  read -rp "Masa aktif (hari): " days

  [[ -n "${username:-}" ]] || { echo -e "${RED}Username tidak boleh kosong${NC}"; pause; return; }
  [[ "${days:-}" =~ ^[0-9]+$ ]] || { echo -e "${RED}Days harus angka${NC}"; pause; return; }
  (( days > 0 )) || { echo -e "${RED}Days minimal 1${NC}"; pause; return; }

  body="$(api_post "/api/user/create" "{\"password\":\"${username}\",\"days\":${days}}")"
  print_result "$body"

  domain="$(echo "$body" | json_value "domain")"
  expired="$(echo "$body" | json_value "expired")"

  if echo "$body" | grep -q '"success":[[:space:]]*true'; then
    echo ""
    echo -e "${CYAN}Username :${NC} ${username}"
    echo -e "${CYAN}Expired  :${NC} ${expired:--}"
    echo -e "${CYAN}Domain   :${NC} ${domain:-$DOMAIN}"
    echo -e "${CYAN}Port UDP :${NC} 5667"
  fi

  pause
}

create_trial() {
  header
  echo -e "${BOLD}CREATE TRIAL ACCOUNT${NC}"
  echo ""

  default_user="trial$(tr -dc a-z0-9 </dev/urandom | head -c 6)"
  read -rp "Username trial [${default_user}]: " username
  username="${username:-$default_user}"

  body="$(api_post "/api/user/create" "{\"password\":\"${username}\",\"days\":${TRIAL_DAYS}}")"
  print_result "$body"

  domain="$(echo "$body" | json_value "domain")"
  expired="$(echo "$body" | json_value "expired")"

  if echo "$body" | grep -q '"success":[[:space:]]*true'; then
    echo ""
    echo -e "${CYAN}Trial User :${NC} ${username}"
    echo -e "${CYAN}Expired    :${NC} ${expired:--}"
    echo -e "${CYAN}Domain     :${NC} ${domain:-$DOMAIN}"
    echo -e "${CYAN}Port UDP   :${NC} 5667"
    echo -e "${YELLOW}Catatan    :${NC} Trial memakai ${TRIAL_DAYS} hari"
  fi

  pause
}

renew_account() {
  header
  echo -e "${BOLD}RENEW ACCOUNT${NC}"
  echo ""

  read -rp "Username: " username
  read -rp "Tambah masa aktif (hari): " days

  [[ -n "${username:-}" ]] || { echo -e "${RED}Username tidak boleh kosong${NC}"; pause; return; }
  [[ "${days:-}" =~ ^[0-9]+$ ]] || { echo -e "${RED}Days harus angka${NC}"; pause; return; }
  (( days > 0 )) || { echo -e "${RED}Days minimal 1${NC}"; pause; return; }

  body="$(api_post "/api/user/renew" "{\"password\":\"${username}\",\"days\":${days}}")"
  print_result "$body"

  expired="$(echo "$body" | json_value "expired")"
  if echo "$body" | grep -q '"success":[[:space:]]*true'; then
    echo -e "${CYAN}Expired baru:${NC} ${expired:--}"
  fi

  pause
}

delete_account() {
  header
  echo -e "${BOLD}DELETE ACCOUNT${NC}"
  echo ""

  read -rp "Username yang mau dihapus: " username
  [[ -n "${username:-}" ]] || { echo -e "${RED}Username tidak boleh kosong${NC}"; pause; return; }

  read -rp "Yakin hapus ${username}? (y/N): " confirm
  [[ "${confirm,,}" == "y" ]] || { echo -e "${YELLOW}Dibatalkan${NC}"; pause; return; }

  body="$(api_post "/api/user/delete" "{\"password\":\"${username}\"}")"
  print_result "$body"
  pause
}

list_accounts() {
  header
  echo -e "${BOLD}LIST ACCOUNTS${NC}"
  echo ""

  body="$(api_get "/api/users")"

  if ! echo "$body" | grep -q '"success":[[:space:]]*true'; then
    print_result "$body"
    pause
    return
  fi

  echo -e "${BOLD}User                Expired         Status${NC}"
  echo "------------------------------------------------------"

  echo "$body" | tr '{' '\n' | grep '"password"' | while read -r row; do
    user="$(echo "$row" | sed -n 's/.*"password":[[:space:]]*"\([^"]*\)".*/\1/p')"
    exp="$(echo "$row" | sed -n 's/.*"expired":[[:space:]]*"\([^"]*\)".*/\1/p')"
    status="$(echo "$row" | sed -n 's/.*"status":[[:space:]]*"\([^"]*\)".*/\1/p')"
    printf "%-18s %-15s %s\n" "${user:--}" "${exp:--}" "${status:--}"
  done

  pause
}

system_info() {
  header
  echo -e "${BOLD}SYSTEM INFO${NC}"
  echo ""

  body="$(api_get "/api/info")"

  if ! echo "$body" | grep -q '"success":[[:space:]]*true'; then
    print_result "$body"
    pause
    return
  fi

  domain="$(echo "$body" | json_value "domain")"
  public_ip="$(echo "$body" | json_value "public_ip")"
  private_ip="$(echo "$body" | json_value "private_ip")"
  port="$(echo "$body" | json_value "port")"
  service="$(echo "$body" | json_value "service")"

  echo -e "${CYAN}Domain    :${NC} ${domain:--}"
  echo -e "${CYAN}Public IP :${NC} ${public_ip:--}"
  echo -e "${CYAN}Private IP:${NC} ${private_ip:--}"
  echo -e "${CYAN}Port      :${NC} ${port:-5667}"
  echo -e "${CYAN}Service   :${NC} ${service:-zivpn}"

  echo ""
  echo -e "${BOLD}Service Status${NC}"
  systemctl is-active zivpn.service 2>/dev/null || true
  systemctl is-active zivpn-api.service 2>/dev/null || true
  systemctl is-active zivpn-bot.service 2>/dev/null || true

  pause
}

restart_services() {
  header
  echo -e "${BOLD}RESTART SERVICES${NC}"
  echo ""

  for svc in zivpn.service zivpn-api.service zivpn-bot.service; do
    if systemctl list-unit-files | grep -q "^${svc}"; then
      if systemctl restart "$svc" 2>/dev/null; then
        echo -e "${GREEN}✔ Restarted ${svc}${NC}"
      else
        echo -e "${YELLOW}! Failed restart ${svc}${NC}"
      fi
    fi
  done

  pause
}

backup_data() {
  header
  echo -e "${BOLD}BACKUP DATA${NC}"
  echo ""

  backup_dir="/root/zivpn-backup"
  mkdir -p "$backup_dir"
  backup_file="${backup_dir}/zivpn-backup-$(date +%Y%m%d-%H%M%S).zip"

  tmpdir="$(mktemp -d)"
  mkdir -p "${tmpdir}/etc-zivpn"

  cp -a /etc/zivpn/. "${tmpdir}/etc-zivpn/" 2>/dev/null || true
  [[ -f /etc/systemd/system/zivpn.service ]] && cp /etc/systemd/system/zivpn.service "${tmpdir}/" || true
  [[ -f /etc/systemd/system/zivpn-api.service ]] && cp /etc/systemd/system/zivpn-api.service "${tmpdir}/" || true
  [[ -f /etc/systemd/system/zivpn-bot.service ]] && cp /etc/systemd/system/zivpn-bot.service "${tmpdir}/" || true

  if command -v zip >/dev/null 2>&1; then
    (
      cd "$tmpdir"
      zip -qr "$backup_file" .
    )
    echo -e "${GREEN}✔ Backup dibuat${NC}"
    echo -e "${CYAN}${backup_file}${NC}"
  else
    echo -e "${YELLOW}! zip belum terinstall. install dulu: apt-get install -y zip${NC}"
  fi

  rm -rf "$tmpdir"
  pause
}

restore_data() {
  header
  echo -e "${BOLD}RESTORE DATA${NC}"
  echo ""

  read -rp "Masukkan path file backup .zip: " zipfile
  [[ -f "${zipfile:-}" ]] || { echo -e "${RED}File tidak ditemukan${NC}"; pause; return; }

  if ! command -v unzip >/dev/null 2>&1; then
    echo -e "${YELLOW}! unzip belum terinstall. install dulu: apt-get install -y unzip${NC}"
    pause
    return
  fi

  tmpdir="$(mktemp -d)"
  unzip -oq "$zipfile" -d "$tmpdir"

  [[ -d "${tmpdir}/etc-zivpn" ]] && mkdir -p /etc/zivpn && cp -a "${tmpdir}/etc-zivpn/." /etc/zivpn/
  [[ -f "${tmpdir}/zivpn.service" ]] && cp -f "${tmpdir}/zivpn.service" /etc/systemd/system/zivpn.service
  [[ -f "${tmpdir}/zivpn-api.service" ]] && cp -f "${tmpdir}/zivpn-api.service" /etc/systemd/system/zivpn-api.service
  [[ -f "${tmpdir}/zivpn-bot.service" ]] && cp -f "${tmpdir}/zivpn-bot.service" /etc/systemd/system/zivpn-bot.service

  systemctl daemon-reload
  systemctl restart zivpn.service 2>/dev/null || true
  systemctl restart zivpn-api.service 2>/dev/null || true
  systemctl restart zivpn-bot.service 2>/dev/null || true

  rm -rf "$tmpdir"

  echo -e "${GREEN}✔ Restore selesai${NC}"
  pause
}

main_menu() {
  while true; do
    header
    cat <<EOF
${BOLD}1.${NC} Create Account
${BOLD}2.${NC} Create Trial
${BOLD}3.${NC} Renew Account
${BOLD}4.${NC} Delete Account
${BOLD}5.${NC} List Accounts
${BOLD}6.${NC} System Info
${BOLD}7.${NC} Restart Services
${BOLD}8.${NC} Backup Data
${BOLD}9.${NC} Restore Data
${BOLD}0.${NC} Exit
EOF
    echo ""
    read -rp "Select menu: " opt

    case "${opt:-}" in
      1) create_account ;;
      2) create_trial ;;
      3) renew_account ;;
      4) delete_account ;;
      5) list_accounts ;;
      6) system_info ;;
      7) restart_services ;;
      8) backup_data ;;
      9) restore_data ;;
      0) exit 0 ;;
      *) echo -e "${RED}Menu tidak valid${NC}"; sleep 1 ;;
    esac
  done
}

need_root
load_env
main_menu