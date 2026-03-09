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

CURRENT_PUBLIC_IP="-"
CURRENT_PRIVATE_IP="-"
CURRENT_SERVICE="-"

CONTENT_W=52

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
  read -rp "Press Enter to continue..." _
}

json_value() {
  local key="$1"
  sed -n "s/.*\"${key}\":[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1
}

json_success() {
  grep -q '"success":[[:space:]]*true'
}

api_post() {
  local endpoint="$1"
  local payload="$2"

  curl -m 25 -sS -X POST "${BASE_URL}${endpoint}" \
    -H "Content-Type: application/json" \
    -H "X-API-Key: ${API_KEY}" \
    -d "${payload}" 2>/dev/null || true
}

api_get() {
  local endpoint="$1"

  curl -m 20 -sS "${BASE_URL}${endpoint}" \
    -H "X-API-Key: ${API_KEY}" 2>/dev/null || true
}

service_state() {
  local svc="$1"
  systemctl is-active "$svc" 2>/dev/null || echo "inactive"
}

mask_api_key() {
  local k="$1"
  local len=${#k}
  if (( len <= 8 )); then
    echo "$k"
    return
  fi
  echo "${k:0:4}******${k: -4}"
}

get_os_name() {
  grep -w PRETTY_NAME /etc/os-release 2>/dev/null | head -n1 | sed 's/PRETTY_NAME=//;s/"//g'
}

get_ram_info() {
  free -m | awk 'NR==2 {print $3 " MB / " $2 " MB"}'
}

get_uptime_info() {
  uptime -p 2>/dev/null | sed 's/^up //'
}

get_server_info() {
  local api_info
  api_info="$(api_get "/api/info")"
  CURRENT_PUBLIC_IP="$(echo "$api_info" | json_value "public_ip")"
  CURRENT_PRIVATE_IP="$(echo "$api_info" | json_value "private_ip")"
  CURRENT_SERVICE="$(echo "$api_info" | json_value "service")"

  [[ -z "${CURRENT_PUBLIC_IP:-}" ]] && CURRENT_PUBLIC_IP="-"
  [[ -z "${CURRENT_PRIVATE_IP:-}" ]] && CURRENT_PRIVATE_IP="-"
  [[ -z "${CURRENT_SERVICE:-}" ]] && CURRENT_SERVICE="-"
}

get_isp_info() {
  local ip="$1"
  local isp="-"

  [[ -z "${ip:-}" || "$ip" == "-" ]] && { echo "-"; return; }

  isp="$(curl -m 6 -fsSL "https://ipinfo.io/${ip}/org" 2>/dev/null | tr -d '\r' || true)"
  [[ -z "${isp:-}" ]] && isp="-"

  echo "$isp"
}

format_expiry_human() {
  local exp="$1"
  local f=""
  f="$(LC_TIME=C date -d "$exp" '+%d %B %Y %H:%M' 2>/dev/null || true)"
  [[ -n "$f" ]] && echo "$f" || echo "$exp"
}

count_users() {
  local body users active expired
  body="$(api_get "/api/users")"

  users="$(echo "$body" | grep -o '"password"' 2>/dev/null | wc -l | tr -d ' ')"
  active="$(echo "$body" | grep -oi '"status"[[:space:]]*:[[:space:]]*"active"' 2>/dev/null | wc -l | tr -d ' ')"
  expired="$(echo "$body" | grep -oi '"status"[[:space:]]*:[[:space:]]*"expired"' 2>/dev/null | wc -l | tr -d ' ')"

  TOTAL_USERS="${users:-0}"
  ACTIVE_USERS="${active:-0}"
  EXPIRED_USERS="${expired:-0}"
}

repeat_char() {
  local char="$1"
  local count="$2"
  printf "%*s" "$count" "" | tr ' ' "$char"
}

fit_text() {
  local width="$1"
  shift
  local text="$*"
  text="${text//$'\n'/ }"
  text="$(echo -n "$text" | tr -s ' ')"

  if (( ${#text} > width )); then
    printf "%s" "${text:0:width}"
  else
    printf "%-${width}s" "$text"
  fi
}

center_text() {
  local width="$1"
  shift
  local text="$*"
  local len=${#text}
  local left=0
  local right=0

  if (( len >= width )); then
    printf "%s" "${text:0:width}"
    return
  fi

  left=$(( (width - len) / 2 ))
  right=$(( width - len - left ))
  printf "%*s%s%*s" "$left" "" "$text" "$right" ""
}

box_top() {
  echo -e "${CYAN}┌$(repeat_char "─" $((CONTENT_W + 2)))┐${NC}"
}

box_mid() {
  echo -e "${CYAN}├$(repeat_char "─" $((CONTENT_W + 2)))┤${NC}"
}

box_bottom() {
  echo -e "${CYAN}└$(repeat_char "─" $((CONTENT_W + 2)))┘${NC}"
}

box_row() {
  local text="$1"
  printf "${CYAN}│${NC} %s ${CYAN}│${NC}\n" "$(fit_text "$CONTENT_W" "$text")"
}

print_top_banner() {
  box_top
  box_row "$(center_text "$CONTENT_W" "SCRIPT PREMIUM YINNSTORE ZIVPN")"
  box_bottom
  echo ""
}

print_server_box() {
  local core api bot os_name ram_info uptime_info
  get_server_info

  os_name="$(get_os_name)"
  ram_info="$(get_ram_info)"
  uptime_info="$(get_uptime_info)"
  core="$(service_state zivpn.service)"
  api="$(service_state zivpn-api.service)"
  bot="$(service_state zivpn-bot.service)"

  box_top
  box_row "$(center_text "$CONTENT_W" "SERVER INFORMATION")"
  box_mid
  box_row "DOMAIN      = ${DOMAIN}"
  box_row "API         = 127.0.0.1:${API_PORT}"
  box_row "PUBLIC IP   = ${CURRENT_PUBLIC_IP}"
  box_row "PRIVATE IP  = ${CURRENT_PRIVATE_IP}"
  box_row "OS          = ${os_name}"
  box_row "RAM         = ${ram_info}"
  box_row "UPTIME      = ${uptime_info}"
  box_row "CORE        = ${core}"
  box_row "API STATUS  = ${api}"
  box_row "BOT STATUS  = ${bot}"
  box_bottom
  echo ""
}

print_account_box() {
  box_top
  box_row "$(center_text "$CONTENT_W" "TOTAL ACCOUNT SUMMARY")"
  box_mid
  box_row "TOTAL USER  = ${TOTAL_USERS}"
  box_row "ACTIVE      = ${ACTIVE_USERS}"
  box_row "EXPIRED     = ${EXPIRED_USERS}"
  box_row "API KEY     = $(mask_api_key "$API_KEY")"
  box_bottom
  echo ""
}

menu_row() {
  local left="$1"
  local right="$2"
  local line
  printf -v line "%-24s %-24s" "$left" "$right"
  box_row "$line"
}

print_menu_box() {
  box_top
  menu_row "[01] CREATE ACCOUNT"  "[06] SYSTEM INFO"
  menu_row "[02] CREATE TRIAL"    "[07] BACKUP/RESTORE"
  menu_row "[03] RENEW ACCOUNT"   "[08] VIEW API KEY"
  menu_row "[04] DELETE ACCOUNT"  "[09] RESTART SERVICE"
  menu_row "[05] LIST ACCOUNTS"   "[00] EXIT"
  box_bottom
  echo ""
}

header() {
  count_users
  clear
  print_top_banner
  print_server_box
  print_account_box
  print_menu_box
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

sub_header() {
  header
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}${WHITE}$1${NC}"
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
}

show_account_result_box() {
  local title="$1"
  local password="$2"
  local expired="$3"
  local ip isp exp_fmt

  get_server_info
  ip="${CURRENT_PUBLIC_IP:-$CURRENT_PRIVATE_IP}"
  [[ -z "${ip:-}" ]] && ip="-"
  isp="$(get_isp_info "$ip")"
  exp_fmt="$(format_expiry_human "$expired")"

  echo ""
  echo -e "${GREEN}${title}${NC}"
  box_top
  box_row "Host   : ${DOMAIN} (domain)"
  box_row "IP     : ${ip} (ip vps)"
  box_row "ISP    : ${isp} (nama isp)"
  box_row "Pass   : ${password} (password)"
  box_row "Expire : ${exp_fmt} (exp)"
  box_bottom
}

create_account() {
  sub_header "CREATE PREMIUM ACCOUNT"

  read -rp "Username/password account : " username
  read -rp "Masa aktif (hari)         : " days

  [[ -n "${username:-}" ]] || { echo -e "${RED}Username tidak boleh kosong${NC}"; pause; return; }
  [[ "${days:-}" =~ ^[0-9]+$ ]] || { echo -e "${RED}Days harus angka${NC}"; pause; return; }
  (( days > 0 )) || { echo -e "${RED}Days minimal 1${NC}"; pause; return; }

  body="$(api_post "/api/user/create" "{\"password\":\"${username}\",\"days\":${days}}")"
  print_result "$body"

  expired="$(echo "$body" | json_value "expired")"

  if echo "$body" | json_success; then
    show_account_result_box "CREATE AKUN ZIVPN PREMIUM" "$username" "$expired"
  fi

  pause
}

create_trial() {
  sub_header "CREATE TRIAL ACCOUNT"

  default_user="trial$(tr -dc a-z0-9 </dev/urandom | head -c 6)"
  read -rp "Username trial [${default_user}] : " username
  username="${username:-$default_user}"

  read -rp "Masa aktif menit [60]           : " minutes
  minutes="${minutes:-60}"

  [[ "${minutes:-}" =~ ^[0-9]+$ ]] || { echo -e "${RED}Menit harus angka${NC}"; pause; return; }
  (( minutes > 0 )) || { echo -e "${RED}Menit minimal 1${NC}"; pause; return; }

  body="$(api_post "/api/user/create" "{\"password\":\"${username}\",\"minutes\":${minutes}}")"
  print_result "$body"

  expired="$(echo "$body" | json_value "expired")"

  if echo "$body" | json_success; then
    show_account_result_box "TRIAL AKUN ZIVPN PREMIUM" "$username" "$expired"
  fi

  pause
}

renew_account() {
  sub_header "RENEW ACCOUNT"

  read -rp "Username                  : " username
  read -rp "Tambah masa aktif (hari)  : " days

  [[ -n "${username:-}" ]] || { echo -e "${RED}Username tidak boleh kosong${NC}"; pause; return; }
  [[ "${days:-}" =~ ^[0-9]+$ ]] || { echo -e "${RED}Days harus angka${NC}"; pause; return; }
  (( days > 0 )) || { echo -e "${RED}Days minimal 1${NC}"; pause; return; }

  body="$(api_post "/api/user/renew" "{\"password\":\"${username}\",\"days\":${days}}")"
  print_result "$body"

  expired="$(echo "$body" | json_value "expired")"
  if echo "$body" | json_success; then
    echo ""
    echo -e "${GREEN}RENEW BERHASIL${NC}"
    box_top
    box_row "User   : ${username}"
    box_row "Expire : $(format_expiry_human "$expired")"
    box_bottom
  fi

  pause
}

delete_account() {
  sub_header "DELETE ACCOUNT"

  body="$(api_get "/api/users")"

  if ! echo "$body" | json_success; then
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

  echo -e "${WHITE}List Akun:${NC}"
  for i in "${!user_list[@]}"; do
    printf "${GREEN}[%02d]${NC} %s\n" "$((i+1))" "${user_list[$i]}"
  done
  echo ""

  read -rp "Pilih nomor akun yang mau dihapus : " pick
  [[ "${pick:-}" =~ ^[0-9]+$ ]] || { echo -e "${RED}Input harus angka${NC}"; pause; return; }
  (( pick >= 1 && pick <= ${#user_list[@]} )) || { echo -e "${RED}Nomor tidak valid${NC}"; pause; return; }

  username="${user_list[$((pick-1))]}"

  read -rp "Yakin hapus ${username}? (y/N)     : " confirm
  [[ "${confirm,,}" == "y" ]] || { echo -e "${YELLOW}Dibatalkan${NC}"; pause; return; }

  body="$(api_post "/api/user/delete" "{\"password\":\"${username}\"}")"
  print_result "$body"
  pause
}

list_accounts() {
  sub_header "LIST ACCOUNTS"

  body="$(api_get "/api/users")"

  if ! echo "$body" | json_success; then
    print_result "$body"
    pause
    return
  fi

  printf "${WHITE}%-6s %-20s %-20s %-12s${NC}\n" "NO" "USERNAME" "EXPIRED" "STATUS"
  echo "------------------------------------------------------------------"

  no=1
  echo "$body" | tr '{' '\n' | grep '"password"' | while read -r row; do
    user="$(echo "$row" | sed -n 's/.*"password":[[:space:]]*"\([^"]*\)".*/\1/p')"
    exp="$(echo "$row" | sed -n 's/.*"expired":[[:space:]]*"\([^"]*\)".*/\1/p')"
    status="$(echo "$row" | sed -n 's/.*"status":[[:space:]]*"\([^"]*\)".*/\1/p')"
    printf "%-6s %-20s %-20s %-12s\n" "[$(printf "%02d" "$no")]" "${user:--}" "${exp:--}" "${status:--}"
    no=$((no+1))
  done

  pause
}

system_info() {
  sub_header "SYSTEM INFO"

  body="$(api_get "/api/info")"

  if ! echo "$body" | json_success; then
    print_result "$body"
    pause
    return
  fi

  domain="$(echo "$body" | json_value "domain")"
  public_ip="$(echo "$body" | json_value "public_ip")"
  private_ip="$(echo "$body" | json_value "private_ip")"
  port="$(echo "$body" | json_value "port")"
  service="$(echo "$body" | json_value "service")"

  box_top
  box_row "Domain      : ${domain:--}"
  box_row "Public IP   : ${public_ip:--}"
  box_row "Private IP  : ${private_ip:--}"
  box_row "Port        : ${port:-5667}"
  box_row "Service     : ${service:-zivpn}"
  box_row "OS          : $(get_os_name)"
  box_row "RAM         : $(get_ram_info)"
  box_row "Uptime      : $(get_uptime_info)"
  box_row "zivpn       : $(service_state zivpn.service)"
  box_row "api         : $(service_state zivpn-api.service)"
  box_row "bot         : $(service_state zivpn-bot.service)"
  box_bottom

  pause
}

restart_services() {
  sub_header "RESTART SERVICES"

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

backup_vpn() {
  sub_header "BACKUP DATA ZIVPN"

  backup_dir="/root/zivpn-backup"
  mkdir -p "$backup_dir"
  backup_file="${backup_dir}/zivpn-backup-$(date +%Y%m%d-%H%M%S).zip"

  if ! command -v zip >/dev/null 2>&1; then
    echo -e "${YELLOW}! zip belum terinstall. install dulu: apt-get install -y zip${NC}"
    pause
    return
  fi

  tmpdir="$(mktemp -d)"
  mkdir -p "${tmpdir}/etc-zivpn" "${tmpdir}/systemd" "${tmpdir}/bin"

  cp -a /etc/zivpn/. "${tmpdir}/etc-zivpn/" 2>/dev/null || true
  [[ -f /etc/systemd/system/zivpn.service ]] && cp -f /etc/systemd/system/zivpn.service "${tmpdir}/systemd/" || true
  [[ -f /etc/systemd/system/zivpn-api.service ]] && cp -f /etc/systemd/system/zivpn-api.service "${tmpdir}/systemd/" || true
  [[ -f /etc/systemd/system/zivpn-bot.service ]] && cp -f /etc/systemd/system/zivpn-bot.service "${tmpdir}/systemd/" || true
  [[ -f /usr/local/bin/zivpn ]] && cp -f /usr/local/bin/zivpn "${tmpdir}/bin/" || true
  [[ -f /usr/local/bin/menu ]] && cp -f /usr/local/bin/menu "${tmpdir}/bin/" || true
  [[ -f /usr/local/bin/menu-zivpn ]] && cp -f /usr/local/bin/menu-zivpn "${tmpdir}/bin/" || true

  (
    cd "$tmpdir"
    zip -qr "$backup_file" .
  )

  rm -rf "$tmpdir"

  echo -e "${GREEN}✔ Backup data ZiVPN berhasil dibuat${NC}"
  echo -e "${CYAN}${backup_file}${NC}"
  pause
}

restore_vpn() {
  sub_header "RESTORE DATA ZIVPN"

  read -rp "Masukkan path file backup .zip : " zipfile
  [[ -f "${zipfile:-}" ]] || { echo -e "${RED}File tidak ditemukan${NC}"; pause; return; }

  if ! command -v unzip >/dev/null 2>&1; then
    echo -e "${YELLOW}! unzip belum terinstall. install dulu: apt-get install -y unzip${NC}"
    pause
    return
  fi

  tmpdir="$(mktemp -d)"
  unzip -oq "$zipfile" -d "$tmpdir" || { rm -rf "$tmpdir"; echo -e "${RED}Gagal extract backup${NC}"; pause; return; }

  [[ -d "${tmpdir}/etc-zivpn" ]] && mkdir -p /etc/zivpn && cp -a "${tmpdir}/etc-zivpn/." /etc/zivpn/
  [[ -d "${tmpdir}/systemd" ]] && cp -f "${tmpdir}/systemd/"* /etc/systemd/system/ 2>/dev/null || true
  [[ -d "${tmpdir}/bin" ]] && cp -f "${tmpdir}/bin/"* /usr/local/bin/ 2>/dev/null || true

  chmod +x /usr/local/bin/zivpn /usr/local/bin/menu /usr/local/bin/menu-zivpn 2>/dev/null || true
  systemctl daemon-reload
  systemctl restart zivpn.service 2>/dev/null || true
  systemctl restart zivpn-api.service 2>/dev/null || true
  systemctl restart zivpn-bot.service 2>/dev/null || true

  rm -rf "$tmpdir"

  echo -e "${GREEN}✔ Restore data ZiVPN selesai${NC}"
  pause
}

backup_restore_menu() {
  while true; do
    sub_header "BACKUP / RESTORE ZIVPN"

    box_top
    box_row "[01] Backup Data ZiVPN"
    box_row "[02] Restore Data ZiVPN"
    box_row "[00] Kembali"
    box_bottom
    echo ""

    read -rp "Select options 》 " br
    case "${br:-}" in
      1|01) backup_vpn ;;
      2|02) restore_vpn ;;
      0|00) return ;;
      *) echo -e "${RED}Menu tidak valid${NC}"; sleep 1 ;;
    esac
  done
}

view_api_key() {
  sub_header "VIEW API KEY"

  box_top
  box_row "API URL    : ${BASE_URL}"
  box_row "Masked Key : $(mask_api_key "$API_KEY")"
  box_bottom
  echo ""

  read -rp "Tampilkan full API key? (y/N): " ans
  if [[ "${ans,,}" == "y" ]]; then
    echo ""
    echo -e "${GREEN}${API_KEY}${NC}"
  fi

  pause
}

main_menu() {
  while true; do
    header
    echo -ne "${GREEN}Selected Menu ⟩ ${NC}"
    read -r opt
    echo ""

    case "${opt:-}" in
      1|01) create_account ;;
      2|02) create_trial ;;
      3|03) renew_account ;;
      4|04) delete_account ;;
      5|05) list_accounts ;;
      6|06) system_info ;;
      7|07) backup_restore_menu ;;
      8|08) view_api_key ;;
      9|09) restart_services ;;
      0|00) clear; exit 0 ;;
      *) echo -e "${RED}Menu tidak valid${NC}"; sleep 1 ;;
    esac
  done
}

need_root
load_env
main_menu