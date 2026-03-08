#!/bin/bash
set -u

API_KEY_FILE="/etc/zivpn/apikey"
API_PORT_FILE="/etc/zivpn/api_port"
DOMAIN_FILE="/etc/zivpn/domain"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
MAGENTA='\033[1;35m'
BOLD='\033[1m'
GRAY='\033[1;30m'
WHITE='\033[1;37m'
NC='\033[0m'

BASE_URL=""
API_KEY=""
API_PORT=""
DOMAIN="-"
TOTAL_USERS="0"
ACTIVE_USERS="0"
EXPIRED_USERS="0"

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo -e "${RED}Run as root!${NC}"
    exit 1
  fi
}

load_env() {
  [[ -f "$API_KEY_FILE" ]] || { echo -e "${RED}API key file not found: $API_KEY_FILE${NC}"; exit 1; }
  [[ -f "$API_PORT_FILE" ]] || { echo -e "${RED}API port file not found: $API_PORT_FILE${NC}"; exit 1; }

  API_KEY="$(tr -d '\r\n' < "$API_KEY_FILE" 2>/dev/null)"
  API_PORT="$(tr -d '\r\n' < "$API_PORT_FILE" 2>/dev/null)"

  if [[ -f "$DOMAIN_FILE" ]]; then
    DOMAIN="$(tr -d '\r\n' < "$DOMAIN_FILE" 2>/dev/null)"
  fi

  BASE_URL="http://127.0.0.1:${API_PORT}"
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
    -d "${payload}" 2>/dev/null || true
}

api_get() {
  local endpoint="$1"

  curl -sS "${BASE_URL}${endpoint}" \
    -H "X-API-Key: ${API_KEY}" 2>/dev/null || true
}

service_state() {
  local svc="$1"
  systemctl is-active "$svc" 2>/dev/null || echo "inactive"
}

count_users() {
  local body users active expired
  body="$(api_get "/api/users")"

  users="$(echo "$body" | grep -o '"password"' 2>/dev/null | wc -l)"
  active="$(echo "$body" | grep -oi '"status"[[:space:]]*:[[:space:]]*"active"' 2>/dev/null | wc -l)"
  expired="$(echo "$body" | grep -oi '"status"[[:space:]]*:[[:space:]]*"expired"' 2>/dev/null | wc -l)"

  TOTAL_USERS="${users:-0}"
  ACTIVE_USERS="${active:-0}"
  EXPIRED_USERS="${expired:-0}"
}

header() {
  count_users
  clear

  echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║                 YINNSTORE ZIVPN                   ║${NC}"
  echo -e "${BOLD}${CYAN}║               PREMIUM VPS MENU PANEL              ║${NC}"
  echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════════════╝${NC}"
  echo ""
  printf "${BOLD}${WHITE} %-14s ${NC}: %s\n" "Domain" "${DOMAIN}"
  printf "${BOLD}${WHITE} %-14s ${NC}: %s\n" "API" "${BASE_URL}"
  printf "${BOLD}${WHITE} %-14s ${NC}: %s\n" "Core Service" "$(service_state zivpn.service)"
  printf "${BOLD}${WHITE} %-14s ${NC}: %s\n" "API Service" "$(service_state zivpn-api.service)"
  printf "${BOLD}${WHITE} %-14s ${NC}: %s\n" "Bot Service" "$(service_state zivpn-bot.service)"
  echo ""
  printf "${BOLD}${GREEN} Active${NC}: %s   ${BOLD}${YELLOW}Expired${NC}: %s   ${BOLD}${CYAN}Total${NC}: %s\n" \
    "${ACTIVE_USERS}" "${EXPIRED_USERS}" "${TOTAL_USERS}"
  echo ""
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
  echo -e "${BOLD}${CYAN}CREATE PREMIUM ACCOUNT${NC}"
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
    printf "${BOLD} Username ${NC}: %s\n" "${username}"
    printf "${BOLD} Expired  ${NC}: %s\n" "${expired:--}"
    printf "${BOLD} Domain   ${NC}: %s\n" "${domain:-$DOMAIN}"
    printf "${BOLD} UDP Port ${NC}: %s\n" "5667"
  fi

  pause
}

create_trial() {
  header
  echo -e "${BOLD}${YELLOW}CREATE TRIAL ACCOUNT${NC}"
  echo ""

  default_user="trial$(tr -dc a-z0-9 </dev/urandom | head -c 6)"
  read -rp "Username trial [${default_user}]: " username
  username="${username:-$default_user}"

  read -rp "Masa aktif menit: " minutes
  [[ "${minutes:-}" =~ ^[0-9]+$ ]] || { echo -e "${RED}Menit harus angka${NC}"; pause; return; }
  (( minutes > 0 )) || { echo -e "${RED}Menit minimal 1${NC}"; pause; return; }

  # API cuma support days, jadi trial menit disiasati:
  # 1-1440 menit = 1 hari
  # >1440 dibulatkan ke atas per hari
  days=$(( (minutes + 1439) / 1440 ))
  (( days < 1 )) && days=1

  body="$(api_post "/api/user/create" "{\"password\":\"${username}\",\"days\":${days}}")"
  print_result "$body"

  domain="$(echo "$body" | json_value "domain")"
  expired="$(echo "$body" | json_value "expired")"

  if echo "$body" | grep -q '"success":[[:space:]]*true'; then
    echo ""
    printf "${BOLD} Trial User  ${NC}: %s\n" "${username}"
    printf "${BOLD} Input Menit ${NC}: %s\n" "${minutes}"
    printf "${BOLD} Hitung API  ${NC}: %s hari\n" "${days}"
    printf "${BOLD} Expired     ${NC}: %s\n" "${expired:--}"
    printf "${BOLD} Domain      ${NC}: %s\n" "${domain:-$DOMAIN}"
    printf "${BOLD} UDP Port    ${NC}: %s\n" "5667"
    printf "${YELLOW}Catatan${NC}: API bawaan cuma support hari, jadi menit dibulatkan ke hari terdekat.\n"
  fi

  pause
}

renew_account() {
  header
  echo -e "${BOLD}${GREEN}RENEW ACCOUNT${NC}"
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
    printf "${BOLD} Expired baru ${NC}: %s\n" "${expired:--}"
  fi

  pause
}

delete_account() {
  header
  echo -e "${BOLD}${RED}DELETE ACCOUNT${NC}"
  echo ""

  body="$(api_get "/api/users")"

  if ! echo "$body" | grep -q '"success":[[:space:]]*true'; then
    print_result "$body"
    pause
    return
  fi

  mapfile -t user_list < <(
    echo "$body" | tr '{' '\n' | grep '"password"' | sed -n 's/.*"password":[[:space:]]*"\([^"]*\)".*/\1/p'
  )

  if [[ "${#user_list[@]}" -eq 0 ]]; then
    echo -e "${YELLOW}Tidak ada akun untuk dihapus${NC}"
    pause
    return
  fi

  echo "List Akun:"
  for i in "${!user_list[@]}"; do
    printf "[%02d] %s\n" "$((i+1))" "${user_list[$i]}"
  done
  echo ""

  read -rp "Pilih nomor akun yang mau dihapus: " pick
  [[ "${pick:-}" =~ ^[0-9]+$ ]] || { echo -e "${RED}Input harus angka${NC}"; pause; return; }
  (( pick >= 1 && pick <= ${#user_list[@]} )) || { echo -e "${RED}Nomor tidak valid${NC}"; pause; return; }

  username="${user_list[$((pick-1))]}"

  read -rp "Yakin hapus ${username}? (y/N): " confirm
  [[ "${confirm,,}" == "y" ]] || { echo -e "${YELLOW}Dibatalkan${NC}"; pause; return; }

  body="$(api_post "/api/user/delete" "{\"password\":\"${username}\"}")"
  print_result "$body"
  pause
}

list_accounts() {
  header
  echo -e "${BOLD}${MAGENTA}LIST ACCOUNTS${NC}"
  echo ""

  body="$(api_get "/api/users")"

  if ! echo "$body" | grep -q '"success":[[:space:]]*true'; then
    print_result "$body"
    pause
    return
  fi

  printf "${BOLD}%-5s %-20s %-18s %-12s${NC}\n" "NO" "USERNAME" "EXPIRED" "STATUS"
  echo "-------------------------------------------------------------------"

  no=1
  echo "$body" | tr '{' '\n' | grep '"password"' | while read -r row; do
    user="$(echo "$row" | sed -n 's/.*"password":[[:space:]]*"\([^"]*\)".*/\1/p')"
    exp="$(echo "$row" | sed -n 's/.*"expired":[[:space:]]*"\([^"]*\)".*/\1/p')"
    status="$(echo "$row" | sed -n 's/.*"status":[[:space:]]*"\([^"]*\)".*/\1/p')"
    printf "%-5s %-20s %-18s %-12s\n" "[$(printf "%02d" "$no")]" "${user:--}" "${exp:--}" "${status:--}"
    no=$((no+1))
  done

  pause
}

system_info() {
  header
  echo -e "${BOLD}${BLUE}SYSTEM INFO${NC}"
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

  printf "${BOLD} %-12s ${NC}: %s\n" "Domain" "${domain:--}"
  printf "${BOLD} %-12s ${NC}: %s\n" "Public IP" "${public_ip:--}"
  printf "${BOLD} %-12s ${NC}: %s\n" "Private IP" "${private_ip:--}"
  printf "${BOLD} %-12s ${NC}: %s\n" "Port" "${port:-5667}"
  printf "${BOLD} %-12s ${NC}: %s\n" "Service" "${service:-zivpn}"
  echo ""
  printf "${BOLD} %-12s ${NC}: %s\n" "zivpn" "$(service_state zivpn.service)"
  printf "${BOLD} %-12s ${NC}: %s\n" "api" "$(service_state zivpn-api.service)"
  printf "${BOLD} %-12s ${NC}: %s\n" "bot" "$(service_state zivpn-bot.service)"

  pause
}

restart_services() {
  header
  echo -e "${BOLD}${YELLOW}RESTART SERVICES${NC}"
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
  echo -e "${BOLD}${CYAN}BACKUP DATA${NC}"
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
  echo -e "${BOLD}${CYAN}RESTORE DATA${NC}"
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

    printf "${BOLD}${CYAN}[%s]${NC} Create Account        ${BOLD}${CYAN}[%s]${NC} System Info\n" "1" "6"
    printf "${BOLD}${CYAN}[%s]${NC} Create Trial          ${BOLD}${CYAN}[%s]${NC} Restart Services\n" "2" "7"
    printf "${BOLD}${CYAN}[%s]${NC} Renew Account         ${BOLD}${CYAN}[%s]${NC} Backup Data\n" "3" "8"
    printf "${BOLD}${CYAN}[%s]${NC} Delete Account        ${BOLD}${CYAN}[%s]${NC} Restore Data\n" "4" "9"
    printf "${BOLD}${CYAN}[%s]${NC} List Accounts         ${BOLD}${RED}[%s]${NC} Exit\n" "5" "0"

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