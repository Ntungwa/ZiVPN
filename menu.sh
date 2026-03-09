#!/bin/bash
set -u

API_KEY_FILE="/etc/zivpn/apikey"
API_PORT_FILE="/etc/zivpn/api_port"
DOMAIN_FILE="/etc/zivpn/domain"
TG_NOTIFY_FILE="/etc/zivpn/telegram_notify.conf"
WATCH_PID_FILE="/etc/zivpn/.tg_notify_watch.pid"
WATCH_SNAPSHOT_FILE="/etc/zivpn/.tg_notify_users.snapshot"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;32m'
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
TG_BOT_TOKEN=""
TG_CHAT_ID=""

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo -e "${RED}Run as root!${NC}"
    exit 1
  fi
}

load_notify_config() {
  TG_BOT_TOKEN=""
  TG_CHAT_ID=""

  if [[ -f "$TG_NOTIFY_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$TG_NOTIFY_FILE" 2>/dev/null || true
  fi
}

save_notify_config() {
  mkdir -p /etc/zivpn
  cat >"$TG_NOTIFY_FILE" <<EOF
TG_BOT_TOKEN='${TG_BOT_TOKEN}'
TG_CHAT_ID='${TG_CHAT_ID}'
EOF
  chmod 600 "$TG_NOTIFY_FILE" 2>/dev/null || true
}

notify_enabled() {
  [[ -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]]
}

tg_html_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  echo "$s"
}

tg_send_message() {
  local text="$1"
  notify_enabled || return 0

  nohup curl -m 20 -fsS --retry 2 --retry-delay 1 \
    -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "text=${text}" \
    >/dev/null 2>&1 &
}

tg_send_document() {
  local filepath="$1"
  local caption="$2"
  notify_enabled || return 0
  [[ -f "$filepath" ]] || return 0

  nohup curl -m 180 -fsS --retry 2 --retry-delay 1 \
    -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" \
    --form-string "chat_id=${TG_CHAT_ID}" \
    --form-string "parse_mode=HTML" \
    --form-string "caption=${caption}" \
    -F "document=@${filepath}" \
    >/dev/null 2>&1 &
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
  load_notify_config
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

status_color() {
  local st="$1"
  case "$st" in
    active) printf "%b" "${GREEN}${st}${NC}" ;;
    inactive|failed) printf "%b" "${RED}${st}${NC}" ;;
    *) printf "%b" "${YELLOW}${st}${NC}" ;;
  esac
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

mask_token() {
  local k="$1"
  local len=${#k}
  if (( len <= 10 )); then
    echo "$k"
    return
  fi
  echo "${k:0:6}******${k: -4}"
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

repeat_char() {
  local char="$1"
  local count="$2"
  local out=""
  local i
  for ((i=0; i<count; i++)); do
    out+="$char"
  done
  printf "%s" "$out"
}

fit_text() {
  local width="$1"
  shift
  local text="$*"
  text="${text//$'\n'/ }"
  if (( ${#text} > width )); then
    printf "%s" "${text:0:width}"
  else
    printf "%-${width}s" "$text"
  fi
}

format_expiry_human() {
  local exp="$1"
  local f=""
  f="$(LC_TIME=C date -d "$exp" '+%d %B %Y %H:%M' 2>/dev/null || true)"
  [[ -n "$f" ]] && echo "$f" || echo "$exp"
}

get_isp_info() {
  local ip="$1"
  local isp="-"

  [[ -z "${ip:-}" || "$ip" == "-" ]] && { echo "-"; return; }

  isp="$(curl -m 6 -fsSL "https://ipinfo.io/${ip}/org" 2>/dev/null | tr -d '\r' || true)"
  [[ -z "${isp:-}" ]] && isp="-"

  echo "$isp"
}

show_account_result_box() {
  local title="$1"
  local host="$2"
  local password="$3"
  local expired="$4"
  local api_info public_ip private_ip ip isp exp_fmt
  local border_len=25

  api_info="$(api_get "/api/info")"
  public_ip="$(echo "$api_info" | json_value "public_ip")"
  private_ip="$(echo "$api_info" | json_value "private_ip")"
  ip="${public_ip:-$private_ip}"
  [[ -z "${ip:-}" ]] && ip="-"

  isp="$(get_isp_info "$ip")"
  exp_fmt="$(format_expiry_human "$expired")"

  echo ""
  echo -e "${BOLD}${WHITE}${title}${NC}"
  printf "┌%s┐\n" "$(repeat_char "─" "$border_len")"
  printf "│ Host    : %s\n" "$host"
  printf "│ IP      : %s\n" "$ip"
  printf "│ ISP     : %s\n" "$isp"
  printf "│ Pass    : %s\n" "$password"
  printf "│ Expired : %s\n" "$exp_fmt"
  printf "└%s┘\n" "$(repeat_char "─" "$border_len")"
}

send_account_notification() {
  local title="$1"
  local host="$2"
  local password="$3"
  local expired="$4"
  local api_info public_ip private_ip ip isp exp_fmt notif

  api_info="$(api_get "/api/info")"
  public_ip="$(echo "$api_info" | json_value "public_ip")"
  private_ip="$(echo "$api_info" | json_value "private_ip")"
  ip="${public_ip:-$private_ip}"
  [[ -z "${ip:-}" ]] && ip="-"

  isp="$(get_isp_info "$ip")"
  exp_fmt="$(format_expiry_human "$expired")"

  notif="<b>$(tg_html_escape "$title")</b>
Host    : <code>$(tg_html_escape "$host")</code>
IP      : <code>$(tg_html_escape "$ip")</code>
ISP     : <code>$(tg_html_escape "$isp")</code>
Pass    : <code>$(tg_html_escape "$password")</code>
Expired : <code>$(tg_html_escape "$exp_fmt")</code>"

  tg_send_message "$notif"
}

get_current_users_list() {
  local body
  body="$(api_get "/api/users")"
  echo "$body" | tr '{' '\n' | grep '"password"' | sed -n 's/.*"password":[[:space:]]*"\([^"]*\)".*/\1/p' | sort -u
}

notify_deleted_accounts_once() {
  local old_file new_file user
  old_file="$(mktemp)"
  new_file="$(mktemp)"

  [[ -f "$WATCH_SNAPSHOT_FILE" ]] && cp -f "$WATCH_SNAPSHOT_FILE" "$old_file" || true
  get_current_users_list > "$new_file"

  if [[ -s "$old_file" ]]; then
    while IFS= read -r user; do
      [[ -z "${user:-}" ]] && continue
      if ! grep -Fxq "$user" "$new_file"; then
        tg_send_message "<b>AKUN ZIVPN DIHAPUS</b>
User    : <code>$(tg_html_escape "$user")</code>
Host    : <code>$(tg_html_escape "$DOMAIN")</code>
Time    : <code>$(date '+%d %B %Y %H:%M')</code>"
      fi
    done < "$old_file"
  fi

  cp -f "$new_file" "$WATCH_SNAPSHOT_FILE" 2>/dev/null || true
  rm -f "$old_file" "$new_file"
}

watch_deleted_accounts_loop() {
  load_env
  mkdir -p /etc/zivpn
  echo "$$" > "$WATCH_PID_FILE"

  if [[ ! -f "$WATCH_SNAPSHOT_FILE" ]]; then
    get_current_users_list > "$WATCH_SNAPSHOT_FILE"
  fi

  while true; do
    load_env
    if ! notify_enabled; then
      rm -f "$WATCH_PID_FILE"
      exit 0
    fi
    notify_deleted_accounts_once
    sleep 20
  done
}

ensure_delete_watcher() {
  if notify_enabled; then
    if [[ -f "$WATCH_PID_FILE" ]]; then
      local pid
      pid="$(cat "$WATCH_PID_FILE" 2>/dev/null || true)"
      if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
        return 0
      fi
    fi

    nohup /usr/local/bin/menu-zivpn --watch-delete >/dev/null 2>&1 &
    echo $! > "$WATCH_PID_FILE"
  else
    if [[ -f "$WATCH_PID_FILE" ]]; then
      local pid
      pid="$(cat "$WATCH_PID_FILE" 2>/dev/null || true)"
      [[ -n "${pid:-}" ]] && kill "$pid" 2>/dev/null || true
      rm -f "$WATCH_PID_FILE"
    fi
  fi
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

print_top_banner() {
  echo -e "${CYAN}╭────────────────────────────────────────────────────╮${NC}"
  echo -e "${CYAN}│${NC}${RED}           SCRIPT PREMIUM YINNSTORE ZIVPN           ${NC}${CYAN}│${NC}"
  echo -e "${CYAN}╰────────────────────────────────────────────────────╯${NC}"
  echo ""
}

print_server_box() {
  local api_info public_ip private_ip core api bot os_name ram_info uptime_info
  api_info="$(api_get "/api/info")"
  public_ip="$(echo "$api_info" | json_value "public_ip")"
  private_ip="$(echo "$api_info" | json_value "private_ip")"
  os_name="$(get_os_name)"
  ram_info="$(get_ram_info)"
  uptime_info="$(get_uptime_info)"
  core="$(service_state zivpn.service)"
  api="$(service_state zivpn-api.service)"
  bot="$(service_state zivpn-bot.service)"

  echo -e " ${CYAN}╭────────────────────────────────────────────────────╮${NC}"
  printf " ${CYAN}│${NC} ${WHITE}• DOMAIN${NC}    = %s\n" "${DOMAIN}"
  printf " ${CYAN}│${NC} ${WHITE}• API${NC}       = %s\n" "127.0.0.1:${API_PORT}"
  printf " ${CYAN}│${NC} ${WHITE}• PUBLIC IP${NC} = %s\n" "${public_ip:--}"
  printf " ${CYAN}│${NC} ${WHITE}• PRIVATE IP${NC}= %s\n" "${private_ip:--}"
  printf " ${CYAN}│${NC} ${WHITE}• OS${NC}        = %s\n" "${os_name:--}"
  printf " ${CYAN}│${NC} ${WHITE}• RAM${NC}       = %s\n" "${ram_info:--}"
  printf " ${CYAN}│${NC} ${WHITE}• UPTIME${NC}    = %s\n" "${uptime_info:--}"
  printf " ${CYAN}│${NC} ${WHITE}• CORE${NC}      = %b\n" "$(status_color "$core")"
  printf " ${CYAN}│${NC} ${WHITE}• API STATUS${NC}= %b\n" "$(status_color "$api")"
#  printf " ${CYAN}│${NC} ${WHITE}• BOT STATUS${NC}= %b\n" "$(status_color "$bot")"
  echo -e " ${CYAN}╰────────────────────────────────────────────────────╯${NC}"
  echo ""
}

print_account_box() {
  echo -e " ${CYAN}╭────────────────────────────────────────────────────╮${NC}"
  echo -e " ${CYAN}│${NC}${WHITE}               TOTAL ACCOUNT SUMMARY                ${NC}${CYAN}│${NC}"
  echo -e " ${CYAN}├────────────────────────────────────────────────────┤${NC}"
  printf " ${CYAN}│${NC} ${WHITE}TOTAL USER${NC}  = %-8s   ${WHITE}ACTIVE${NC} = %-8s\n" "${TOTAL_USERS}" "${ACTIVE_USERS}"
  printf " ${CYAN}│${NC} ${WHITE}EXPIRED${NC}     = %-8s   ${WHITE}API KEY${NC}= %s\n" "${EXPIRED_USERS}" "$(mask_api_key "$API_KEY")"
  echo -e " ${CYAN}╰────────────────────────────────────────────────────╯${NC}"
  echo ""
}

print_menu_box() {
  echo -e " ${CYAN}╭────────────────────────────────────────────────────╮${NC}"
  printf " ${CYAN}│${NC} ${GREEN}[01]${NC} %-20s ${GREEN}[06]${NC} %-13s       ${CYAN}│${NC}\n" "CREATE ACCOUNT" "SYSTEM INFO"
  printf " ${CYAN}│${NC} ${GREEN}[02]${NC} %-20s ${GREEN}[07]${NC} %-13s      ${CYAN}│${NC}\n" "CREATE TRIAL" "BACKUP/RESTORE"
  printf " ${CYAN}│${NC} ${GREEN}[03]${NC} %-20s ${GREEN}[08]${NC} %-13s       ${CYAN}│${NC}\n" "RENEW ACCOUNT" "VIEW API KEY"
  printf " ${CYAN}│${NC} ${GREEN}[04]${NC} %-20s ${GREEN}[09]${NC} %-13s     ${CYAN}│${NC}\n" "DELETE ACCOUNT" "RESTART SERVICE"
  printf " ${CYAN}│${NC} ${GREEN}[05]${NC} %-20s ${GREEN}[10]${NC} %-13s       ${CYAN}│${NC}\n" "LIST ACCOUNTS" "TG NOTIF"
  printf " ${CYAN}│${NC} ${GREEN}[11]${NC} %-20s ${RED}[00]${NC} %-13s       ${CYAN}│${NC}\n" "DEL ALL EXP" "EXIT"
  echo -e " ${CYAN}╰────────────────────────────────────────────────────╯${NC}"
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

create_account() {
  sub_header "CREATE PREMIUM ACCOUNT"

  read -rp "Username/password account : " username
  read -rp "Masa aktif (hari)         : " days

  [[ -n "${username:-}" ]] || { echo -e "${RED}Username tidak boleh kosong${NC}"; pause; return; }
  [[ "${days:-}" =~ ^[0-9]+$ ]] || { echo -e "${RED}Days harus angka${NC}"; pause; return; }
  (( days > 0 )) || { echo -e "${RED}Days minimal 1${NC}"; pause; return; }

  body="$(api_post "/api/user/create" "{\"password\":\"${username}\",\"days\":${days}}")"
  print_result "$body"

  domain="$(echo "$body" | json_value "domain")"
  expired="$(echo "$body" | json_value "expired")"

  if echo "$body" | json_success; then
    show_account_result_box "CREATE AKUN ZIVPN PREMIUM" "${domain:-$DOMAIN}" "${username}" "${expired:--}"
    send_account_notification "CREATE AKUN ZIVPN PREMIUM" "${domain:-$DOMAIN}" "${username}" "${expired:--}"
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

  domain="$(echo "$body" | json_value "domain")"
  expired="$(echo "$body" | json_value "expired")"

  if echo "$body" | json_success; then
    show_account_result_box "TRIAL AKUN ZIVPN PREMIUM" "${domain:-$DOMAIN}" "${username}" "${expired:--}"
    send_account_notification "TRIAL AKUN ZIVPN PREMIUM" "${domain:-$DOMAIN}" "${username}" "${expired:--}"
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
    printf "${WHITE}Expired baru ${NC}: %s\n" "${expired:--}"
    send_account_notification "RENEW AKUN ZIVPN PREMIUM" "${DOMAIN}" "${username}" "${expired:--}"
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

  if echo "$body" | json_success; then
    tg_send_message "<b>AKUN ZIVPN DIHAPUS</b>
User    : <code>$(tg_html_escape "$username")</code>
Host    : <code>$(tg_html_escape "$DOMAIN")</code>
Time    : <code>$(date '+%d %B %Y %H:%M')</code>"
    get_current_users_list > "$WATCH_SNAPSHOT_FILE" 2>/dev/null || true
  fi

  pause
}

delete_all_expired() {
  local body deleted failed username status status_lc
  deleted=0
  failed=0

  sub_header "DELETE ALL EXPIRED ACCOUNT"

  body="$(api_get "/api/users")"
  if ! echo "$body" | json_success; then
    print_result "$body"
    pause
    return
  fi

  mapfile -t expired_list < <(
    echo "$body" | tr '{' '\n' | grep '"password"' | while read -r row; do
      username="$(echo "$row" | sed -n 's/.*"password":[[:space:]]*"\([^"]*\)".*/\1/p')"
      status="$(echo "$row" | sed -n 's/.*"status":[[:space:]]*"\([^"]*\)".*/\1/p')"
      status_lc="$(printf '%s' "$status" | tr '[:upper:]' '[:lower:]')"

      if [[ -n "$username" && "$status_lc" == "expired" ]]; then
        echo "$username"
      fi
    done
  )

  if [[ "${#expired_list[@]}" -eq 0 ]]; then
    echo -e "${YELLOW}Tidak ada akun expired${NC}"
    pause
    return
  fi

  echo -e "${WHITE}Akun expired ditemukan:${NC} ${#expired_list[@]}"
  for i in "${!expired_list[@]}"; do
    printf "${GREEN}[%02d]${NC} %s\n" "$((i+1))" "${expired_list[$i]}"
  done
  echo ""

  read -rp "Yakin hapus semua akun expired? (y/N) : " confirm
  [[ "${confirm,,}" == "y" ]] || {
    echo -e "${YELLOW}Dibatalkan${NC}"
    pause
    return
  }

  for username in "${expired_list[@]}"; do
    body="$(api_post "/api/user/delete" "{\"password\":\"${username}\"}")"
    if echo "$body" | json_success; then
      ((deleted++))
      tg_send_message "<b>AKUN ZIVPN DIHAPUS</b>
User    : <code>$(tg_html_escape "$username")</code>
Host    : <code>$(tg_html_escape "$DOMAIN")</code>
Time    : <code>$(date '+%d %B %Y %H:%M')</code>"
    else
      ((failed++))
    fi
  done

  get_current_users_list > "$WATCH_SNAPSHOT_FILE" 2>/dev/null || true

  echo ""
  echo -e "${GREEN}Berhasil dihapus : ${deleted}${NC}"
  echo -e "${YELLOW}Gagal dihapus    : ${failed}${NC}"

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

  printf "${WHITE}Domain      ${NC}: %s\n" "${domain:--}"
  printf "${WHITE}Public IP   ${NC}: %s\n" "${public_ip:--}"
  printf "${WHITE}Private IP  ${NC}: %s\n" "${private_ip:--}"
  printf "${WHITE}Port        ${NC}: %s\n" "${port:-5667}"
  printf "${WHITE}Service     ${NC}: %s\n" "${service:-zivpn}"
  printf "${WHITE}OS          ${NC}: %s\n" "$(get_os_name)"
  printf "${WHITE}RAM         ${NC}: %s\n" "$(get_ram_info)"
  printf "${WHITE}Uptime      ${NC}: %s\n" "$(get_uptime_info)"
  echo ""
  printf "${WHITE}zivpn       ${NC}: %s\n" "$(service_state zivpn.service)"
  printf "${WHITE}api         ${NC}: %s\n" "$(service_state zivpn-api.service)"
  printf "${WHITE}bot         ${NC}: %s\n" "$(service_state zivpn-bot.service)"

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
  mkdir -p "${tmpdir}/etc-zivpn" "${tmpdir}/systemd"

  cp -a /etc/zivpn/. "${tmpdir}/etc-zivpn/" 2>/dev/null || true
  [[ -f /etc/systemd/system/zivpn.service ]] && cp -f /etc/systemd/system/zivpn.service "${tmpdir}/systemd/" || true
  [[ -f /etc/systemd/system/zivpn-api.service ]] && cp -f /etc/systemd/system/zivpn-api.service "${tmpdir}/systemd/" || true
  [[ -f /etc/systemd/system/zivpn-bot.service ]] && cp -f /etc/systemd/system/zivpn-bot.service "${tmpdir}/systemd/" || true

  (
    cd "$tmpdir"
    zip -qr "$backup_file" .
  )

  rm -rf "$tmpdir"

  echo -e "${GREEN}✔ Backup data ZiVPN berhasil dibuat${NC}"
  echo -e "${CYAN}${backup_file}${NC}"

  tg_send_message "<b>Backup Data ZiVPN</b>
Host    : <code>$(tg_html_escape "$DOMAIN")</code>
Path    : <code>$(tg_html_escape "$backup_file")</code>
Time    : <code>$(date '+%d %B %Y %H:%M')</code>"
  tg_send_document "$backup_file" "<b>File Backup Data ZiVPN</b>
Host    : <code>$(tg_html_escape "$DOMAIN")</code>
Path    : <code>$(tg_html_escape "$backup_file")</code>
Time    : <code>$(date '+%d %B %Y %H:%M')</code>"

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

  systemctl daemon-reload
  systemctl restart zivpn.service 2>/dev/null || true
  systemctl restart zivpn-api.service 2>/dev/null || true
  systemctl restart zivpn-bot.service 2>/dev/null || true

  rm -rf "$tmpdir"

  echo -e "${GREEN}✔ Restore data ZiVPN selesai${NC}"

  tg_send_message "<b>RESTORE DATA ZIVPN BERHASIL</b>
Host    : <code>$(tg_html_escape "$DOMAIN")</code>
Path    : <code>$(tg_html_escape "$zipfile")</code>
Time    : <code>$(date '+%d %B %Y %H:%M')</code>"

  get_current_users_list > "$WATCH_SNAPSHOT_FILE" 2>/dev/null || true

  pause
}

backup_restore_menu() {
  while true; do
    sub_header "BACKUP / RESTORE ZIVPN"

    echo -e "${GREEN}[01]${NC} Backup Data ZiVPN"
    echo -e "${GREEN}[02]${NC} Restore Data ZiVPN"
    echo -e "${RED}[00]${NC} Kembali"
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

  echo -e "${WHITE}API URL     ${NC}: ${BASE_URL}"
  echo -e "${WHITE}Masked Key  ${NC}: $(mask_api_key "$API_KEY")"
  echo ""

  read -rp "Tampilkan full API key? (y/N): " ans
  if [[ "${ans,,}" == "y" ]]; then
    echo ""
    echo -e "${GREEN}${API_KEY}${NC}"
  fi

  pause
}

telegram_notif_menu() {
  while true; do
    sub_header "TELEGRAM NOTIFICATION"

    echo -e "${WHITE}Status      ${NC}: $(notify_enabled && echo ENABLED || echo DISABLED)"
    echo -e "${WHITE}Bot Token   ${NC}: ${TG_BOT_TOKEN:+$(mask_token "$TG_BOT_TOKEN")}"
    echo -e "${WHITE}Chat ID     ${NC}: ${TG_CHAT_ID:--}"
    echo ""
    echo -e "${GREEN}[01]${NC} Set Bot Token"
    echo -e "${GREEN}[02]${NC} Set Chat ID"
    echo -e "${GREEN}[03]${NC} Test Notification"
    echo -e "${GREEN}[04]${NC} Disable Notification"
    echo -e "${RED}[00]${NC} Kembali"
    echo ""

    read -rp "Select options 》 " tgopt
    case "${tgopt:-}" in
      1|01)
        read -rp "Masukkan Bot Token : " TG_BOT_TOKEN
        save_notify_config
        ensure_delete_watcher
        echo -e "${GREEN}✔ Bot token disimpan${NC}"
        pause
        ;;
      2|02)
        read -rp "Masukkan Chat ID   : " TG_CHAT_ID
        save_notify_config
        ensure_delete_watcher
        echo -e "${GREEN}✔ Chat ID disimpan${NC}"
        pause
        ;;
      3|03)
        tg_send_message "<b>TEST NOTIF ZIVPN BERHASIL</b>
Host    : <code>$(tg_html_escape "$DOMAIN")</code>
Time    : <code>$(date '+%d %B %Y %H:%M')</code>"
        echo -e "${GREEN}✔ Test notif dikirim${NC}"
        pause
        ;;
      4|04)
        TG_BOT_TOKEN=""
        TG_CHAT_ID=""
        save_notify_config
        ensure_delete_watcher
        echo -e "${YELLOW}✔ Notifikasi dinonaktifkan${NC}"
        pause
        ;;
      0|00) return ;;
      *) echo -e "${RED}Menu tidak valid${NC}"; sleep 1 ;;
    esac
  done
}

main_menu() {
  ensure_delete_watcher
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
      10) telegram_notif_menu ;;
      11) delete_all_expired ;;
      0|00) clear; exit 0 ;;
      *) echo -e "${RED}Menu tidak valid${NC}"; sleep 1 ;;
    esac
  done
}

if [[ "${1:-}" == "--watch-delete" ]]; then
  load_env
  watch_deleted_accounts_loop
  exit 0
fi

need_root
load_env
main_menu