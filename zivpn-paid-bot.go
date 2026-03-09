// zivpn-paid-bot.go
// ZiVPN Telegram Bot (YinnStore)
package main

import (
	"archive/zip"
	"bytes"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math/big"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	tgbotapi "github.com/go-telegram-bot-api/telegram-bot-api/v5"
)

// ==========================================
// Files
// ==========================================

const (
	BotConfigFile = "/etc/zivpn/bot-config.json"
	ApiPortFile   = "/etc/zivpn/api_port"
	ApiKeyFile    = "/etc/zivpn/apikey"
	DomainFile    = "/etc/zivpn/domain"
	PortFile      = "/etc/zivpn/port"

	TrialStateFile     = "/etc/zivpn/trial-state.json"
	TrialMaxPerDay     = 2
	TrialDuration      = 100 * time.Minute
	TrialCleanerPeriod = 1 * time.Minute

	BotStateFile = "/etc/zivpn/bot-state.json"
)

// ==========================================
// Globals
// ==========================================

var (
	ApiUrl           = "http://127.0.0.1:8787/api"
	ApiKey           = "CHANGE_ME" // overridden by /etc/zivpn/apikey
	resultMu         = &sync.Mutex{}
	resultMessageIDs = make(map[int64]int) // chatID -> msgID result akun
	mutex            = &sync.Mutex{}
	lastMu           = &sync.Mutex{}
	userStates       = make(map[int64]string)            // userID -> state
	tempUserData     = make(map[int64]map[string]string) // userID -> temp
	lastMessageIDs   = make(map[int64]int)               // chatID -> msgID (UI clean)

	botStart = time.Now()
)

// ==========================================
// Models
// ==========================================

type BotConfig struct {
	BotToken      string `json:"bot_token"`
	AdminID       int64  `json:"admin_id"`
	Mode          string `json:"mode"` // public/private
	Domain        string `json:"domain"`
	PakasirSlug   string `json:"pakasir_slug"`
	PakasirApiKey string `json:"pakasir_api_key"`
	DailyPrice    int    `json:"daily_price"`

	NotifyGroupID int64 `json:"notify_group_id"` // ✅ group notif
}

type IpInfo struct {
	City        string `json:"city"`
	RegionName  string `json:"regionName"`
	Country     string `json:"country"`
	CountryCode string `json:"countryCode"`
	Isp         string `json:"isp"`
	Query       string `json:"query"`
}

type UserData struct {
	Password string `json:"password"`
	Expired  string `json:"expired"`
	Status   string `json:"status"`
	IpLimit  int    `json:"ip_limit"`
}

type PakasirPayment struct {
	PaymentNumber string `json:"payment_number"`
	ExpiredAt     string `json:"expired_at"`
}

// trial persistence
type TrialState struct {
	Users map[string]*TrialUserState `json:"users"`
}
type TrialUserState struct {
	Date      string   `json:"date"`       // YYYY-MM-DD (WIB)
	Used      int      `json:"used"`       // used today
	Passwords []string `json:"passwords"`  // passwords created today
	CreatedAt []int64  `json:"created_at"` // unix times parallel to Passwords
}

// bot state persistence (join users + stats)
type BotState struct {
	Users          map[string]*BotUser `json:"users"`
	TotalAccounts  int                 `json:"total_accounts"`
	AccountCreated []int64             `json:"account_created"` // unix timestamps
}
type BotUser struct {
	ID        int64  `json:"id"`
	Name      string `json:"name"`
	JoinedAt  int64  `json:"joined_at"`
	Username  string `json:"username"`
	LastSeen  int64  `json:"last_seen"`
	LastChat  int64  `json:"last_chat"`
	IsBlocked bool   `json:"is_blocked"`
}

// ==========================================
// UI Labels
// ==========================================

const (
	btnBuy    = "🛒 𝘽𝙀𝙇𝙄 𝘼𝙆𝙐𝙉 𝙕𝙄𝙑𝙋𝙉"
	btnTrial  = "🌐 𝙏𝙍𝙄𝘼𝙇 𝘼𝙆𝙐𝙉 𝙕𝙄𝙑𝙋𝙉"
	btnInfo   = "📊 𝙎𝙔𝙎𝙏𝙀𝙈 𝙄𝙉𝙁𝙊"
	btnAdmin  = "🛠️ 𝘼𝘿𝙈𝙄𝙉 𝙋𝘼𝙉𝙀𝙇"
	btnBack   = "⬅️ 𝙆𝙀𝙈𝘽𝘼𝙇𝙄"
	btnCancel = "❌ 𝘽𝘼𝙏𝘼𝙇"

	btnBuyConfirm   = "✅ 𝙆𝙊𝙉𝙁𝙄𝙍𝙈𝘼𝙎𝙄 𝙊𝙍𝘿𝙀𝙍"
	btnTrialConfirm = "✅ 𝘾𝙊𝘽𝘼 𝙏𝙍𝙄𝘼𝙇"

	btnUsers      = "👥 𝙐𝙎𝙀𝙍 𝙈𝘼𝙉𝘼𝙂𝙀𝙍"
	btnPaySet     = "💳 𝙋𝘼𝙔𝙈𝙀𝙉𝙏 𝙎𝙀𝙏𝙏𝙄𝙉𝙂"
	btnBackupVPN  = "⬇️ 𝘽𝘼𝘾𝙆𝙐𝙋 𝙑𝙋𝙉"
	btnRestoreVPN = "⬆️ 𝙍𝙀𝙎𝙏𝙊𝙍𝙀 𝙑𝙋𝙉"
	btnBackupBot  = "⬇️ 𝘽𝘼𝘾𝙆𝙐𝙋 𝘽𝙊𝙏"
	btnRestoreBot = "⬆️ 𝙍𝙀𝙎𝙏𝙊𝙍𝙀 𝘽𝙊𝙏"
	btnMode       = "🔐 𝙈𝙊𝘿𝙀"
	btnSetSlug    = "🏷️ 𝙎𝙀𝙏 𝙋𝘼𝙆𝘼𝙎𝙄𝙍 𝙎𝙇𝙐𝙂"
	btnSetKey     = "🔑 𝙎𝙀𝙏 𝙋𝘼𝙆𝘼𝙎𝙄𝙍 𝘼𝙋𝙄 𝙆𝙀𝙔"
	btnSetPrice   = "💰 𝙎𝙀𝙏 𝙃𝘼𝙍𝙂𝘼/𝙃𝘼𝙍𝙄"
	btnSetGroup   = "👥 𝙎𝙀𝙏 𝙄𝘿 𝙂𝙍𝙊𝙐𝙋" // ✅ NEW
	btnTestPay    = "🧪 𝙏𝙀𝙎𝙏 𝙋𝘼𝙆𝘼𝙎𝙄𝙍"

	btnCreateUser = "➕ 𝘾𝙍𝙀𝘼𝙏𝙀"
	btnRenewUser  = "🔄 𝙍𝙀𝙉𝙀𝙒"
	btnDeleteUser = "🗑️ 𝘿𝙀𝙇𝙀𝙏𝙀"
	btnListUser   = "📋 𝙇𝙄𝙎𝙏"

	btnBroadcast = "📣 𝙆𝙄𝙍𝙄𝙈 𝙋𝙀𝙉𝙂𝙐𝙈𝙐𝙈𝘼𝙉"
)

const (
	limitIPDefault = 2
)

// ==========================================
// HTML Helpers (SAFE for Telegram HTML)
// ==========================================

func htmlEscape(s string) string {
	s = strings.ReplaceAll(s, "&", "&amp;")
	s = strings.ReplaceAll(s, "<", "&lt;")
	s = strings.ReplaceAll(s, ">", "&gt;")
	s = strings.ReplaceAll(s, `"`, "&quot;")
	return s
}

func codeHTML(s string) string {
	return "<code>" + htmlEscape(strings.TrimSpace(s)) + "</code>"
}

func stripHTML(s string) string {
	s = strings.ReplaceAll(s, "<blockquote>", "")
	s = strings.ReplaceAll(s, "</blockquote>", "")
	s = strings.ReplaceAll(s, "<b>", "")
	s = strings.ReplaceAll(s, "</b>", "")
	s = strings.ReplaceAll(s, "<code>", "")
	s = strings.ReplaceAll(s, "</code>", "")
	s = strings.ReplaceAll(s, "&amp;", "&")
	s = strings.ReplaceAll(s, "&lt;", "<")
	s = strings.ReplaceAll(s, "&gt;", ">")
	s = strings.ReplaceAll(s, "&quot;", `"`)
	return s
}

func quoteHTML(lines []string) string {
	var out []string
	for _, ln := range lines {
		if strings.TrimSpace(ln) == "" {
			out = append(out, "ㅤ")
			continue
		}
		out = append(out, htmlEscape(ln))
	}
	return "<blockquote>" + strings.Join(out, "\n") + "</blockquote>"
}

// ==========================================
// Time helpers (WIB)
// ==========================================

func wibLoc() *time.Location {
	return time.FixedZone("WIB", 7*3600)
}

func wibNowPretty() string {
	dt := time.Now().In(wibLoc())
	hari := []string{"Senin", "Selasa", "Rabu", "Kamis", "Jumat", "Sabtu", "Minggu"}[int(dt.Weekday()+6)%7]
	bulan := []string{"Jan", "Feb", "Mar", "Apr", "Mei", "Jun", "Jul", "Agu", "Sep", "Okt", "Nov", "Des"}[dt.Month()-1]
	return fmt.Sprintf("%s, %s, %02d %s %s", dt.Format("15.04"), hari, dt.Day(), bulan, dt.Format("06"))
}

func prettyDayDateWIB() string {
	dt := time.Now().In(wibLoc())
	hari := []string{"Senin", "Selasa", "Rabu", "Kamis", "Jumat", "Sabtu", "Minggu"}[int(dt.Weekday()+6)%7]
	return fmt.Sprintf("%s, %02d", hari, dt.Day())
}

func todayWIB() string {
	return time.Now().In(wibLoc()).Format("2006-01-02")
}

// ==========================================
// General Helpers
// ==========================================

func moneyIDR(n int) string {
	if n < 0 {
		n = 0
	}
	s := strconv.Itoa(n)
	var out []byte
	cnt := 0
	for i := len(s) - 1; i >= 0; i-- {
		out = append([]byte{s[i]}, out...)
		cnt++
		if cnt%3 == 0 && i != 0 {
			out = append([]byte{','}, out...)
		}
	}
	return string(out)
}

func genPassword(n int) string {
	const chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	var b strings.Builder
	for i := 0; i < n; i++ {
		idx, _ := rand.Int(rand.Reader, big.NewInt(int64(len(chars))))
		b.WriteByte(chars[idx.Int64()])
	}
	return b.String()
}

func genDigits(n int) string {
	const digits = "0123456789"
	var b strings.Builder
	for i := 0; i < n; i++ {
		idx, err := rand.Int(rand.Reader, big.NewInt(int64(len(digits))))
		if err != nil {
			b.WriteByte('0')
			continue
		}
		b.WriteByte(digits[idx.Int64()])
	}
	return b.String()
}

func serverNameFromISP(isp string) string {
	isp = strings.TrimSpace(isp)
	if isp == "" {
		return "ZIVPN"
	}
	isp = strings.Join(strings.Fields(isp), " ")
	if len(isp) > 26 {
		isp = isp[:26]
	}
	return isp
}

func uptimeStr() string {
	d := time.Since(botStart)
	h := int(d.Hours())
	m := int(d.Minutes()) % 60
	s := int(d.Seconds()) % 60
	return fmt.Sprintf("%02dh %02dm %02ds", h, m, s)
}

func displayName(u *tgbotapi.User) string {
	if u == nil {
		return "User"
	}
	name := strings.TrimSpace(strings.TrimSpace(u.FirstName + " " + u.LastName))
	if name == "" {
		if u.UserName != "" {
			return u.UserName
		}
		return "User"
	}
	return name
}

// Flag emoji from CountryCode
func flagEmoji(cc string) string {
	cc = strings.ToUpper(strings.TrimSpace(cc))
	if len(cc) != 2 {
		return "🏳️"
	}
	r1 := rune(cc[0]) - 'A' + 0x1F1E6
	r2 := rune(cc[1]) - 'A' + 0x1F1E6
	return string([]rune{r1, r2})
}

// ==========================================
// Bot State Persistence
// ==========================================

func loadBotState() BotState {
	st := BotState{
		Users:          map[string]*BotUser{},
		TotalAccounts:  0,
		AccountCreated: []int64{},
	}
	b, err := os.ReadFile(BotStateFile)
	if err != nil {
		return st
	}
	_ = json.Unmarshal(b, &st)
	if st.Users == nil {
		st.Users = map[string]*BotUser{}
	}
	if st.AccountCreated == nil {
		st.AccountCreated = []int64{}
	}
	return st
}

func saveBotState(st BotState) {
	b, _ := json.MarshalIndent(st, "", "  ")
	_ = os.WriteFile(BotStateFile, b, 0644)
}

func ensureUserJoined(userID int64, name, username string, chatID int64) {
	mutex.Lock()
	defer mutex.Unlock()

	st := loadBotState()
	key := strconv.FormatInt(userID, 10)

	now := time.Now().Unix()
	if st.Users[key] == nil {
		st.Users[key] = &BotUser{
			ID:       userID,
			Name:     name,
			Username: username,
			JoinedAt: now,
			LastSeen: now,
			LastChat: chatID,
		}
	} else {
		st.Users[key].Name = name
		st.Users[key].Username = username
		st.Users[key].LastSeen = now
		st.Users[key].LastChat = chatID
	}
	saveBotState(st)
}

func displayNameFromBotState(userID int64) string {
	mutex.Lock()
	defer mutex.Unlock()
	st := loadBotState()
	k := strconv.FormatInt(userID, 10)
	if st.Users != nil && st.Users[k] != nil && strings.TrimSpace(st.Users[k].Name) != "" {
		return st.Users[k].Name
	}
	return "User"
}

func usernameFromBotState(userID int64) string {
	mutex.Lock()
	defer mutex.Unlock()
	st := loadBotState()
	k := strconv.FormatInt(userID, 10)
	if st.Users != nil && st.Users[k] != nil && strings.TrimSpace(st.Users[k].Username) != "" {
		return st.Users[k].Username
	}
	return ""
}

func markAccountCreated() {
	mutex.Lock()
	defer mutex.Unlock()

	st := loadBotState()
	st.TotalAccounts++
	st.AccountCreated = append(st.AccountCreated, time.Now().Unix())

	if len(st.AccountCreated) > 20000 {
		st.AccountCreated = st.AccountCreated[len(st.AccountCreated)-20000:]
	}
	saveBotState(st)
}

func statsAccounts() (today, week, month int, totalUsers int, totalAccounts int) {
	mutex.Lock()
	defer mutex.Unlock()

	st := loadBotState()
	totalUsers = len(st.Users)
	totalAccounts = st.TotalAccounts

	loc := wibLoc()
	now := time.Now().In(loc)

	startToday := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, loc)

	weekday := int(now.Weekday())
	if weekday == 0 {
		weekday = 7
	}
	delta := weekday - 1
	startWeek := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, loc).AddDate(0, 0, -delta)

	startMonth := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, loc)

	for _, ts := range st.AccountCreated {
		t := time.Unix(ts, 0).In(loc)
		if !t.Before(startToday) {
			today++
		}
		if !t.Before(startWeek) {
			week++
		}
		if !t.Before(startMonth) {
			month++
		}
	}
	return
}

// ==========================================
// Trial Persistence
// ==========================================

func loadTrialState() TrialState {
	st := TrialState{Users: map[string]*TrialUserState{}}
	b, err := os.ReadFile(TrialStateFile)
	if err != nil {
		return st
	}
	_ = json.Unmarshal(b, &st)
	if st.Users == nil {
		st.Users = map[string]*TrialUserState{}
	}
	return st
}

func saveTrialState(st TrialState) {
	b, _ := json.MarshalIndent(st, "", "  ")
	_ = os.WriteFile(TrialStateFile, b, 0644)
}

func trialRemaining(userID int64, adminID int64) int {
	if userID == adminID {
		return 999999999
	}

	mutex.Lock()
	defer mutex.Unlock()

	st := loadTrialState()
	key := strconv.FormatInt(userID, 10)
	t := todayWIB()

	u := st.Users[key]
	if u == nil || u.Date != t {
		return TrialMaxPerDay
	}
	rem := TrialMaxPerDay - u.Used
	if rem < 0 {
		rem = 0
	}
	return rem
}

func reserveTrial(userID int64, password string) (bool, string) {
	mutex.Lock()
	defer mutex.Unlock()

	st := loadTrialState()
	key := strconv.FormatInt(userID, 10)
	t := todayWIB()

	u := st.Users[key]
	if u == nil || u.Date != t {
		u = &TrialUserState{Date: t}
		st.Users[key] = u
	}
	if u.Used >= TrialMaxPerDay {
		saveTrialState(st)
		return false, "Limit trial hari ini habis."
	}

	u.Used++
	u.Passwords = append(u.Passwords, password)
	u.CreatedAt = append(u.CreatedAt, time.Now().Unix())
	saveTrialState(st)
	return true, ""
}

func startTrialCleaner() {
	ticker := time.NewTicker(TrialCleanerPeriod)
	go func() {
		defer ticker.Stop()
		for range ticker.C {
			cleanupExpiredTrials()
		}
	}()
}

func cleanupExpiredTrials() {
	mutex.Lock()
	st := loadTrialState()
	mutex.Unlock()

	now := time.Now().Unix()
	expireSec := int64(TrialDuration.Seconds())
	changed := false

	for uid, u := range st.Users {
		if u == nil {
			continue
		}
		var keepPw []string
		var keepTs []int64

		n := len(u.Passwords)
		if len(u.CreatedAt) < n {
			n = len(u.CreatedAt)
		}

		for i := 0; i < n; i++ {
			pw := u.Passwords[i]
			ts := u.CreatedAt[i]
			if pw == "" || ts <= 0 {
				changed = true
				continue
			}
			if now-ts >= expireSec {
				_, _ = apiCall("POST", "/user/delete", map[string]interface{}{"password": pw})
				changed = true
				continue
			}
			keepPw = append(keepPw, pw)
			keepTs = append(keepTs, ts)
		}

		u.Passwords = keepPw
		u.CreatedAt = keepTs
		st.Users[uid] = u
	}

	if changed {
		mutex.Lock()
		saveTrialState(st)
		mutex.Unlock()
	}
}

// ==========================================
// Main
// ==========================================

func main() {
	if keyBytes, err := os.ReadFile(ApiKeyFile); err == nil {
		if s := strings.TrimSpace(string(keyBytes)); s != "" {
			ApiKey = s
		}
	}

	if portBytes, err := os.ReadFile(ApiPortFile); err == nil {
		port := strings.TrimSpace(string(portBytes))
		if port != "" {
			ApiUrl = fmt.Sprintf("http://127.0.0.1:%s/api", port)
		}
	} else {
		if p2, err2 := os.ReadFile(PortFile); err2 == nil {
			port := strings.TrimSpace(string(p2))
			if port != "" {
				ApiUrl = fmt.Sprintf("http://127.0.0.1:%s/api", port)
			}
		}
	}

	cfg, err := loadConfig()
	if err != nil {
		log.Fatal("Gagal memuat konfigurasi bot: ", err)
	}

	bot, err := tgbotapi.NewBotAPI(cfg.BotToken)
	if err != nil {
		log.Panic(err)
	}
	bot.Debug = false
	log.Printf("Authorized on account %s", bot.Self.UserName)

	go startPaymentChecker(bot, &cfg)
	startTrialCleaner()

	u := tgbotapi.NewUpdate(0)
	u.Timeout = 60
	u.AllowedUpdates = []string{"message", "callback_query"}
	updates := bot.GetUpdatesChan(u)

	for update := range updates {
		if update.Message != nil {
			handleMessage(bot, update.Message, &cfg)
		} else if update.CallbackQuery != nil {
			handleCallback(bot, update.CallbackQuery, &cfg)
		}
	}
}

// ==========================================
// Handlers
// ==========================================

func handleMessage(bot *tgbotapi.BotAPI, msg *tgbotapi.Message, cfg *BotConfig) {
	userID := msg.From.ID
	chatID := msg.Chat.ID

	ensureUserJoined(userID, displayName(msg.From), msg.From.UserName, chatID)

	if strings.ToLower(cfg.Mode) == "private" && userID != cfg.AdminID {
		sendPlain(bot, chatID, "⛔ Akses Ditolak. Bot ini Private.")
		return
	}

	mutex.Lock()
	state := userStates[userID]
	mutex.Unlock()

	if userID == cfg.AdminID && state == "admin_broadcast_wait" {
		processBroadcastMessage(bot, msg, cfg)
		return
	}

	if msg.Document != nil && userID == cfg.AdminID {
		mutex.Lock()
		state2 := userStates[userID]
		mutex.Unlock()
		if state2 == "waiting_restore_vpn_file" {
			processVPNRestoreFile(bot, msg, cfg)
			return
		}
		if state2 == "waiting_restore_bot_file" {
			processBotRestoreFile(bot, msg, cfg)
			return
		}
	}

	mutex.Lock()
	state3, ok := userStates[userID]
	mutex.Unlock()
	if ok {
		handleState(bot, msg, state3, cfg)
		return
	}

	if msg.IsCommand() {
		switch msg.Command() {
		case "start":
			showMainMenu(bot, chatID, userID, msg.From, cfg)
		default:
			sendPlain(bot, chatID, "❌ Perintah tidak dikenal.")
		}
	}
}

func handleCallback(bot *tgbotapi.BotAPI, q *tgbotapi.CallbackQuery, cfg *BotConfig) {
	chatID := q.Message.Chat.ID
	userID := q.From.ID
	data := q.Data

	ensureUserJoined(userID, displayName(q.From), q.From.UserName, chatID)

	if strings.ToLower(cfg.Mode) == "private" && userID != cfg.AdminID {
		_, _ = bot.Request(tgbotapi.NewCallback(q.ID, "Akses ditolak"))
		return
	}

	switch {
	case data == "menu_buy":
		showPriceList(bot, chatID, userID, cfg, false)
	case data == "menu_trial":
		showPriceList(bot, chatID, userID, cfg, true)
	case data == "menu_info":
		systemInfo(bot, chatID, userID, cfg)
	case data == "menu_admin":
		if userID == cfg.AdminID {
			showAdminMenu(bot, chatID, userID, cfg)
		}

	case data == "buy_confirm":
		mutex.Lock()
		if _, ok := tempUserData[userID]; !ok {
			tempUserData[userID] = make(map[string]string)
		}
		tempUserData[userID]["chat_id"] = strconv.FormatInt(chatID, 10)
		tempUserData[userID]["is_trial"] = "0"
		userStates[userID] = "buy_password"
		mutex.Unlock()
		sendPlain(bot, chatID, "🔐 Masukkan Password Baru:")

	case data == "trial_confirm":
		pw := "YinnTrialX" + genDigits(5)

		if userID != cfg.AdminID {
			rem := trialRemaining(userID, cfg.AdminID)
			if rem <= 0 {
				sendPlain(bot, chatID, "❌ Trial hari ini sudah habis. (Max 2x / hari)")
				break
			}
			ok, reason := reserveTrial(userID, pw)
			if !ok {
				sendPlain(bot, chatID, "❌ "+reason)
				break
			}
		}

		createUser(bot, chatID, userID, pw, 1, cfg, "main", true)

	case data == "admin_users":
		if userID == cfg.AdminID {
			showAdminUsersMenu(bot, chatID, userID, cfg)
		}
	case data == "admin_payment":
		if userID == cfg.AdminID {
			showAdminPaymentMenu(bot, chatID, userID, cfg)
		}
	case data == "admin_backup_vpn":
		if userID == cfg.AdminID {
			performVPNBackup(bot, chatID)
		}
	case data == "admin_restore_vpn":
		if userID == cfg.AdminID {
			startVPNRestore(bot, chatID, userID)
		}
	case data == "admin_backup_bot":
		if userID == cfg.AdminID {
			performBotBackup(bot, chatID)
		}
	case data == "admin_restore_bot":
		if userID == cfg.AdminID {
			startBotRestore(bot, chatID, userID)
		}
	case data == "admin_mode":
		if userID == cfg.AdminID {
			toggleMode(bot, chatID, userID, cfg)
		}
	case data == "admin_broadcast":
		if userID == cfg.AdminID {
			startBroadcast(bot, chatID, userID)
		}

	case data == "pay_set_slug":
		if userID == cfg.AdminID {
			mutex.Lock()
			userStates[userID] = "admin_set_slug"
			mutex.Unlock()
			sendPlain(bot, chatID, "🏷️ Masukkan Pakasir Project Slug:")
		}
	case data == "pay_set_key":
		if userID == cfg.AdminID {
			mutex.Lock()
			userStates[userID] = "admin_set_key"
			mutex.Unlock()
			sendPlain(bot, chatID, "🔑 Masukkan Pakasir API Key:")
		}
	case data == "pay_set_price":
		if userID == cfg.AdminID {
			mutex.Lock()
			userStates[userID] = "admin_set_price"
			mutex.Unlock()
			sendPlain(bot, chatID, "💰 Masukkan Harga Per Hari (angka, IDR):")
		}
	case data == "pay_set_group":
		if userID == cfg.AdminID {
			mutex.Lock()
			userStates[userID] = "admin_set_group"
			mutex.Unlock()
			sendPlain(bot, chatID, "👥 Masukkan ID Group untuk notif (contoh: -100xxxxxxxxxx).\nKirim 0 untuk matikan notif group.")
		}
	case data == "pay_test":
		if userID == cfg.AdminID {
			testPakasir(bot, chatID, cfg)
		}

	case data == "um_create":
		if userID == cfg.AdminID {
			mutex.Lock()
			userStates[userID] = "admin_create_password"
			mutex.Unlock()
			sendPlain(bot, chatID, "➕ Create (Admin)\n\nMasukkan Password:")
		}
	case data == "um_list":
		if userID == cfg.AdminID {
			listUsers(bot, chatID)
		}
	case data == "um_renew":
		if userID == cfg.AdminID {
			showUserSelection(bot, chatID, 1, "renew")
		}
	case data == "um_delete":
		if userID == cfg.AdminID {
			showUserSelection(bot, chatID, 1, "delete")
		}

	case strings.HasPrefix(data, "page_"):
		if userID == cfg.AdminID {
			handlePagination(bot, chatID, data)
		}
	case strings.HasPrefix(data, "select_renew:"):
		if userID == cfg.AdminID {
			startRenewUser(bot, chatID, userID, data)
		}
	case strings.HasPrefix(data, "select_delete:"):
		if userID == cfg.AdminID {
			confirmDeleteUser(bot, chatID, data)
		}
	case strings.HasPrefix(data, "confirm_delete:"):
		if userID == cfg.AdminID {
			username := strings.TrimPrefix(data, "confirm_delete:")
			deleteUser(bot, chatID, userID, username, cfg)
		}

	case data == "cancel":
		cancelOperation(bot, chatID, userID, cfg, q.From)
	case data == "back_main":
		showMainMenu(bot, chatID, userID, q.From, cfg)
	case data == "back_admin":
		if userID == cfg.AdminID {
			showAdminMenu(bot, chatID, userID, cfg)
		}
	case data == "back_admin_users":
		if userID == cfg.AdminID {
			showAdminUsersMenu(bot, chatID, userID, cfg)
		}
	case data == "back_admin_payment":
		if userID == cfg.AdminID {
			showAdminPaymentMenu(bot, chatID, userID, cfg)
		}
	}

	_, _ = bot.Request(tgbotapi.NewCallback(q.ID, ""))
}

// ==========================================
// State handler
// ==========================================

func handleState(bot *tgbotapi.BotAPI, msg *tgbotapi.Message, state string, cfg *BotConfig) {
	userID := msg.From.ID
	chatID := msg.Chat.ID
	text := strings.TrimSpace(msg.Text)

	switch state {
	case "buy_password":
		if !validatePassword(bot, chatID, text) {
			return
		}
		mutex.Lock()
		if _, ok := tempUserData[userID]; !ok {
			tempUserData[userID] = make(map[string]string)
		}
		tempUserData[userID]["password"] = text
		userStates[userID] = "buy_days"
		mutex.Unlock()

		sendPlain(bot, chatID, fmt.Sprintf("⏳ Masukkan Durasi (hari)\nHarga per hari: Rp %s", moneyIDR(cfg.DailyPrice)))

	case "buy_days":
		days, ok := validateNumber(bot, chatID, text, 1, 365, "Durasi")
		if !ok {
			return
		}
		mutex.Lock()
		tempUserData[userID]["days"] = strconv.Itoa(days)
		mutex.Unlock()

		processPayment(bot, chatID, userID, days, cfg)

	case "admin_create_password":
		if !validatePassword(bot, chatID, text) {
			return
		}
		mutex.Lock()
		if _, ok := tempUserData[userID]; !ok {
			tempUserData[userID] = make(map[string]string)
		}
		tempUserData[userID]["password"] = text
		userStates[userID] = "admin_create_days"
		mutex.Unlock()

		sendPlain(bot, chatID, "⏳ Masukkan Durasi (hari):")

	case "admin_create_days":
		days, ok := validateNumber(bot, chatID, text, 1, 3650, "Durasi")
		if !ok {
			return
		}
		mutex.Lock()
		pw := tempUserData[userID]["password"]
		mutex.Unlock()

		resetAllState(userID)
		createUser(bot, chatID, userID, pw, days, cfg, "admin", false)

	case "renew_days":
		days, ok := validateNumber(bot, chatID, text, 1, 3650, "Durasi")
		if !ok {
			return
		}
		mutex.Lock()
		username := tempUserData[userID]["username"]
		mutex.Unlock()

		resetAllState(userID)
		renewUser(bot, chatID, userID, username, days, cfg)

	case "admin_set_slug":
		text = strings.TrimSpace(text)
		if text == "" {
			sendPlain(bot, chatID, "❌ Slug tidak boleh kosong. Coba lagi:")
			return
		}
		cfg.PakasirSlug = text
		_ = saveConfig(cfg)
		resetAllState(userID)
		sendPlain(bot, chatID, "✅ Pakasir Slug tersimpan.")
		showAdminPaymentMenu(bot, chatID, userID, cfg)

	case "admin_set_key":
		text = strings.TrimSpace(text)
		if text == "" {
			sendPlain(bot, chatID, "❌ API Key tidak boleh kosong. Coba lagi:")
			return
		}
		cfg.PakasirApiKey = text
		_ = saveConfig(cfg)
		resetAllState(userID)
		sendPlain(bot, chatID, "✅ Pakasir API Key tersimpan.")
		showAdminPaymentMenu(bot, chatID, userID, cfg)

	case "admin_set_price":
		val, err := strconv.Atoi(strings.ReplaceAll(text, ",", ""))
		if err != nil || val < 0 {
			sendPlain(bot, chatID, "❌ Harga harus angka >= 0. Coba lagi:")
			return
		}
		cfg.DailyPrice = val
		_ = saveConfig(cfg)
		resetAllState(userID)
		sendPlain(bot, chatID, "✅ Harga per hari tersimpan.")
		showAdminPaymentMenu(bot, chatID, userID, cfg)

	case "admin_set_group":
		val, err := strconv.ParseInt(strings.ReplaceAll(text, " ", ""), 10, 64)
		if err != nil {
			sendPlain(bot, chatID, "❌ ID Group harus angka (contoh -100xxxxxxxxxx). Coba lagi:")
			return
		}
		cfg.NotifyGroupID = val
		_ = saveConfig(cfg)
		resetAllState(userID)
		sendPlain(bot, chatID, "✅ Notify Group ID tersimpan.")
		showAdminPaymentMenu(bot, chatID, userID, cfg)

	case "waiting_restore_vpn_file":
		sendPlain(bot, chatID, "⬆️ Kirim file ZIP backup VPN sekarang.")
	case "waiting_restore_bot_file":
		sendPlain(bot, chatID, "⬆️ Kirim file ZIP backup database bot sekarang.")
	}
}

// ==========================================
// Pages (HTML)
// ==========================================

func showMainMenu(bot *tgbotapi.BotAPI, chatID, userID int64, from *tgbotapi.User, cfg *BotConfig) {
	ipInfo, _ := getIpInfo()
	serverName := serverNameFromISP(ipInfo.Isp)

	domain := cfg.Domain
	if domain == "" {
		if b, err := os.ReadFile(DomainFile); err == nil {
			if s := strings.TrimSpace(string(b)); s != "" {
				domain = s
			}
		}
	}
	if domain == "" {
		domain = "(Not Configured)"
	}

	todayCnt, weekCnt, monthCnt, totalUsers, totalAccounts := statsAccounts()

	rem := trialRemaining(userID, cfg.AdminID)
	remText := fmt.Sprintf("%d/%d", rem, TrialMaxPerDay)
	if userID == cfg.AdminID {
		remText = "∞ (UNLIMITED)"
	}

	dashBlock := strings.Join([]string{
		fmt.Sprintf("👥 Total User : %d", totalUsers),
		fmt.Sprintf("🌐 Global Transaksi : %d", totalAccounts),
		"📆 Waktu: " + wibNowPretty(),
		"⏱️ Runtime : " + uptimeStr(),
		"🤖 Username Bot : @" + htmlEscape(bot.Self.UserName),
		"🥷 Owner: @yinnprovpn",
		"📁 Server: " + htmlEscape(serverName),
		"🌐 Domain: " + htmlEscape(domain),
		"💸 Harga/Hari: Rp " + htmlEscape(moneyIDR(cfg.DailyPrice)),
		"━━━━━━━━━━",
		fmt.Sprintf("🆕 Akun dibuat hari ini : %d", todayCnt),
		fmt.Sprintf("📈 Akun dibuat minggu ini: %d", weekCnt),
		fmt.Sprintf("📊 Akun dibuat bulan ini : %d", monthCnt),
	}, "\n")

	akunBlock := strings.Join([]string{
		"🆔 ID : " + htmlEscape(strconv.FormatInt(userID, 10)),
		"👤 Nama : " + htmlEscape(displayName(from)),
		"📌 Limit Trial : " + htmlEscape(remText),
	}, "\n")

	html := ""
	html += "👋 Welcome, <b>" + htmlEscape(displayName(from)) + "</b>\n\n"
	html += "<b>𝙔𝙞𝙣𝙣 𝙑𝙋𝙉 𝘼𝙪𝙩𝙤 𝙊𝙧𝙙𝙚𝙧 🤖</b>\n"
	html += "━━━━━━━━━━━━━━━━━━━━━━\n"
	html += "📊 <b>Dashboard utama</b>\n"
	html += "<blockquote>" + dashBlock + "</blockquote>\n"
	html += "━━━━━━━━━━━━━━━━━━━━━━\n"
	html += "👤 <b>Ringkasan akun saya</b>\n"
	html += "<blockquote>" + akunBlock + "</blockquote>\n"
	html += "━━━━━━━━━━━━━━━━━━━━━━\n"
	html += "Pilih menu dibawah ini untuk melanjutkan. 👇"

	kb := [][]tgbotapi.InlineKeyboardButton{
		{
			tgbotapi.NewInlineKeyboardButtonData(btnBuy, "menu_buy"),
			tgbotapi.NewInlineKeyboardButtonData(btnTrial, "menu_trial"),
		},
		{tgbotapi.NewInlineKeyboardButtonData(btnInfo, "menu_info")},
	}
	if userID == cfg.AdminID {
		kb = append(kb, []tgbotapi.InlineKeyboardButton{
			tgbotapi.NewInlineKeyboardButtonData(btnAdmin, "menu_admin"),
		})
	}
	markup := tgbotapi.NewInlineKeyboardMarkup(kb...)
	sendAndTrackHTML(bot, chatID, html, &markup)
}

func showMainMenuSimple(bot *tgbotapi.BotAPI, chatID, userID int64, cfg *BotConfig) {
	name := displayNameFromBotState(userID)
	uname := usernameFromBotState(userID)
	dummy := &tgbotapi.User{
		ID:        userID,
		UserName:  uname,
		FirstName: name,
	}
	showMainMenu(bot, chatID, userID, dummy, cfg)
}

func showPriceList(bot *tgbotapi.BotAPI, chatID, userID int64, cfg *BotConfig, isTrial bool) {
	ipInfo, _ := getIpInfo()
	serverName := serverNameFromISP(ipInfo.Isp)

	daily := cfg.DailyPrice
	h30 := daily * 30

	if isTrial {
		rem := trialRemaining(userID, cfg.AdminID)
		remText := fmt.Sprintf("%d/%d", rem, TrialMaxPerDay)
		if userID == cfg.AdminID {
			remText = "∞ (UNLIMITED)"
		}

		html := ""
		html += "━━━━━━━━━━━━━━━━━━━━━━\n"
		html += "<b>🎁 Informasi Trial Akun ZIVPN</b>\n"
		html += "━━━━━━━━━━━━━━━━━━━━━━\n"
		html += "📁 Nama Server : " + codeHTML(serverName) + "\n"
		html += "🕒 Durasi      : " + codeHTML("100 menit") + "\n"
		html += "📱 Limit IP    : " + codeHTML(fmt.Sprintf("%d", limitIPDefault)) + "\n"
		html += "📌 Sisa Trial  : " + codeHTML(remText) + "\n"
		html += "──────────────────────\n"
		html += "Password dibuat otomatis.\n"

		markup := tgbotapi.NewInlineKeyboardMarkup(
			tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(btnTrialConfirm, "trial_confirm")),
			tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(btnBack, "back_main")),
		)
		sendAndTrackHTML(bot, chatID, html, &markup)
		return
	}

	html := ""
	html += "━━━━━━━━━━━━━━━━━━━━━━\n"
	html += "<b>📖 Daftar Dan Harga Akun ZIVPN</b>\n"
	html += "━━━━━━━━━━━━━━━━━━━━━━\n"
	html += "📁 Nama Server : " + codeHTML(serverName) + "\n"
	html += "💵 Harga 30 Hari : " + codeHTML("Rp "+moneyIDR(h30)) + "\n"
	html += "💸 Harga Per Hari: " + codeHTML("Rp "+moneyIDR(daily)) + "\n"
	html += "📱 Limit IP      : " + codeHTML(fmt.Sprintf("%d", limitIPDefault)) + "\n"
	html += "──────────────────────\n"
	html += "Klik konfirmasi untuk lanjut.\n"

	markup := tgbotapi.NewInlineKeyboardMarkup(
		tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(btnBuyConfirm, "buy_confirm")),
		tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(btnBack, "back_main")),
	)
	sendAndTrackHTML(bot, chatID, html, &markup)
}

// ==========================================
// Admin Menus
// ==========================================

func showAdminMenu(bot *tgbotapi.BotAPI, chatID, userID int64, cfg *BotConfig) {
	modeText := "private"
	if strings.ToLower(cfg.Mode) == "public" {
		modeText = "public"
	}

	html := ""
	html += "<b>🛠️ ADMIN PANEL</b>\n"
	html += "━━━━━━━━━━━━━━━━━━━━━━\n"
	html += "Mode       : " + codeHTML(modeText) + "\n"
	html += "Harga/Hari  : " + codeHTML("Rp "+moneyIDR(cfg.DailyPrice)) + "\n"
	html += "Pakasir Slug: " + codeHTML(maskShort(cfg.PakasirSlug)) + "\n"
	html += "Pakasir Key : " + codeHTML(maskKey(cfg.PakasirApiKey)) + "\n"
	html += "Notify Group: " + codeHTML(strconv.FormatInt(cfg.NotifyGroupID, 10)) + "\n"
	html += "━━━━━━━━━━━━━━━━━━━━━━\n"

	markup := tgbotapi.NewInlineKeyboardMarkup(
		tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(btnUsers, "admin_users")),
		tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(btnPaySet, "admin_payment")),
		tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(btnBroadcast, "admin_broadcast")),
		tgbotapi.NewInlineKeyboardRow(
			tgbotapi.NewInlineKeyboardButtonData(btnBackupVPN, "admin_backup_vpn"),
			tgbotapi.NewInlineKeyboardButtonData(btnRestoreVPN, "admin_restore_vpn"),
		),
		tgbotapi.NewInlineKeyboardRow(
			tgbotapi.NewInlineKeyboardButtonData(btnBackupBot, "admin_backup_bot"),
			tgbotapi.NewInlineKeyboardButtonData(btnRestoreBot, "admin_restore_bot"),
		),
		tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(btnMode, "admin_mode")),
		tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(btnBack, "back_main")),
	)
	sendAndTrackHTML(bot, chatID, html, &markup)
}

func showAdminPaymentMenu(bot *tgbotapi.BotAPI, chatID, userID int64, cfg *BotConfig) {
	html := ""
	html += "<b>💳 PAYMENT SETTING</b>\n"
	html += "━━━━━━━━━━━━━━━━━━━━━━\n"
	html += "Pakasir Slug : " + codeHTML(maskShort(cfg.PakasirSlug)) + "\n"
	html += "Pakasir Key  : " + codeHTML(maskKey(cfg.PakasirApiKey)) + "\n"
	html += "Harga/Hari   : " + codeHTML("Rp "+moneyIDR(cfg.DailyPrice)) + "\n"
	html += "Group Notif  : " + codeHTML(strconv.FormatInt(cfg.NotifyGroupID, 10)) + "\n"
	html += "━━━━━━━━━━━━━━━━━━━━━━\n"

	markup := tgbotapi.NewInlineKeyboardMarkup(
		tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(btnSetSlug, "pay_set_slug")),
		tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(btnSetKey, "pay_set_key")),
		tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(btnSetPrice, "pay_set_price")),
		tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(btnSetGroup, "pay_set_group")),
		tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(btnTestPay, "pay_test")),
		tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(btnBack, "back_admin")),
	)
	sendAndTrackHTML(bot, chatID, html, &markup)
}

func showAdminUsersMenu(bot *tgbotapi.BotAPI, chatID, userID int64, cfg *BotConfig) {
	html := ""
	html += "<b>👥 USER MANAGER</b>\n"
	html += "━━━━━━━━━━━━━━━━━━━━━━\n"
	html += "Pilih aksi user:\n"
	html += "━━━━━━━━━━━━━━━━━━━━━━\n"

	markup := tgbotapi.NewInlineKeyboardMarkup(
		tgbotapi.NewInlineKeyboardRow(
			tgbotapi.NewInlineKeyboardButtonData(btnCreateUser, "um_create"),
			tgbotapi.NewInlineKeyboardButtonData("📋 𝙇𝙄𝙎𝙏", "um_list"),
		),
		tgbotapi.NewInlineKeyboardRow(
			tgbotapi.NewInlineKeyboardButtonData("🔄 𝙍𝙀𝙉𝙀𝙒", "um_renew"),
			tgbotapi.NewInlineKeyboardButtonData("🗑️ 𝘿𝙀𝙇𝙀𝙏𝙀", "um_delete"),
		),
		tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(btnBack, "back_admin")),
	)
	sendAndTrackHTML(bot, chatID, html, &markup)
}

// ==========================================
// Loading Dots (QRIS)
// ==========================================

func startLoadingDots(bot *tgbotapi.BotAPI, chatID int64, base string) (stop func(), msgID int) {
	m := tgbotapi.NewMessage(chatID, base)
	sent, err := bot.Send(m)
	if err != nil {
		return func() {}, 0
	}

	done := make(chan struct{})
	ticker := time.NewTicker(900 * time.Millisecond)

	go func(mid int) {
		defer ticker.Stop()
		dots := 0
		for {
			select {
			case <-done:
				return
			case <-ticker.C:
				dots = (dots + 1) % 4
				s := base + strings.Repeat(".", dots)
				edit := tgbotapi.NewEditMessageText(chatID, mid, s)
				_, _ = bot.Send(edit)
			}
		}
	}(sent.MessageID)

	stopFn := func() {
		select {
		case <-done:
		default:
			close(done)
		}
		_, _ = bot.Request(tgbotapi.NewDeleteMessage(chatID, sent.MessageID))
	}
	return stopFn, sent.MessageID
}

// ==========================================
// Payment + Checker
// ==========================================

func processPayment(bot *tgbotapi.BotAPI, chatID, userID int64, days int, cfg *BotConfig) {
	if strings.TrimSpace(cfg.PakasirSlug) == "" || strings.TrimSpace(cfg.PakasirApiKey) == "" || cfg.DailyPrice <= 0 {
		sendPlain(bot, chatID, "❌ Payment belum diset.\n\nAdmin: buka 🛠️ Admin Panel -> 💳 Payment Setting untuk set Pakasir & harga.")
		resetAllState(userID)
		return
	}

	price := days * cfg.DailyPrice
	if price < 500 {
		sendPlain(bot, chatID, fmt.Sprintf("❌ Total Rp %s. Minimal transaksi Rp 500.\nTambah durasi.", moneyIDR(price)))
		return
	}

	mutex.Lock()
	pw := tempUserData[userID]["password"]
	mutex.Unlock()

	// ✅ Loading sampai QR benar-benar terkirim (atau fallback terkirim)
	stopLoading, _ := startLoadingDots(bot, chatID, "⏳ Membuat pesanan, harap tunggu")
	stopNow := func() {
		if stopLoading != nil {
			stopLoading()
			stopLoading = nil
		}
	}

	orderID := fmt.Sprintf("ZIVPN-%d-%d", userID, time.Now().Unix())
	payment, err := createPakasirTransaction(cfg, orderID, price)
	if err != nil {
		stopNow()
		sendPlain(bot, chatID, "❌ Gagal membuat pembayaran: "+err.Error())
		resetAllState(userID)
		return
	}

	mutex.Lock()
	if _, ok := tempUserData[userID]; !ok {
		tempUserData[userID] = make(map[string]string)
	}
	tempUserData[userID]["order_id"] = orderID
	tempUserData[userID]["price"] = strconv.Itoa(price)
	tempUserData[userID]["chat_id"] = strconv.FormatInt(chatID, 10)
	tempUserData[userID]["days"] = strconv.Itoa(days)
	tempUserData[userID]["password"] = pw
	mutex.Unlock()

	// ✅ Gabung detail + QR jadi 1 (caption)
	cap := ""
	cap += "<b>🧾 TAGIHAN PEMBAYARAN</b>\n"
	cap += "━━━━━━━━━━━━━━━━━━━━━━\n"
	cap += "🔐 Password : " + codeHTML(pw) + "\n"
	cap += "📅 Durasi   : " + codeHTML(fmt.Sprintf("%d hari", days)) + "\n"
	cap += "💰 Total    : " + codeHTML("Rp "+moneyIDR(price)) + "\n"
	if strings.TrimSpace(payment.ExpiredAt) != "" {
		cap += "⏳ Expired  : " + codeHTML(payment.ExpiredAt) + "\n"
	}
	cap += "━━━━━━━━━━━━━━━━━━━━━━\n"
	cap += "🔄 Auto cek : " + codeHTML("3 detik") + "\n"
	cap += "✅ QRIS siap. Silakan scan.\n"
	cap += "Order: " + codeHTML(orderID)

	markup := tgbotapi.NewInlineKeyboardMarkup(
		tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(btnCancel, "cancel")),
	)

	qrUrl := fmt.Sprintf("https://api.qrserver.com/v1/create-qr-code/?size=320x320&data=%s", payment.PaymentNumber)

	// kirim QR
	photo := tgbotapi.NewPhoto(chatID, tgbotapi.FileURL(qrUrl))
	photo.Caption = cap
	photo.ParseMode = "HTML"
	photo.ReplyMarkup = markup

	// biar gak kehapus menu sebelumnya kalau user masih butuh lihat, kita tetap bersihin UI biasa:
	deleteLastMessage(bot, chatID)

	sent, sendErr := bot.Send(photo)
	if sendErr != nil {
		// ✅ fallback biar gak blank
		stopNow()
		fallback := ""
		fallback += "🧾 TAGIHAN PEMBAYARAN\n"
		fallback += "━━━━━━━━━━━━━━━━━━━━━━\n"
		fallback += "🔐 Password : " + pw + "\n"
		fallback += "📅 Durasi   : " + fmt.Sprintf("%d hari", days) + "\n"
		fallback += "💰 Total    : Rp " + moneyIDR(price) + "\n"
		if strings.TrimSpace(payment.ExpiredAt) != "" {
			fallback += "⏳ Expired  : " + payment.ExpiredAt + "\n"
		}
		fallback += "━━━━━━━━━━━━━━━━━━━━━━\n"
		fallback += "✅ QRIS (LINK):\n" + qrUrl + "\n"
		fallback += "Order: " + orderID + "\n"
		fallback += "━━━━━━━━━━━━━━━━━━━━━━"

		msg := tgbotapi.NewMessage(chatID, fallback)
		msg.ReplyMarkup = markup
		s2, _ := bot.Send(msg)
		if s2.MessageID != 0 {
			lastMu.Lock()
			lastMessageIDs[chatID] = s2.MessageID
			lastMu.Unlock()
		}
	} else {
		// ✅ baru hapus loading setelah QR sukses terkirim
		stopNow()
		if sent.MessageID != 0 {
			lastMu.Lock()
			lastMessageIDs[chatID] = sent.MessageID
			lastMu.Unlock()
		}
	}

	mutex.Lock()
	delete(userStates, userID)
	mutex.Unlock()
}

func startPaymentChecker(bot *tgbotapi.BotAPI, cfg *BotConfig) {
	ticker := time.NewTicker(3 * time.Second)
	defer ticker.Stop()

	for range ticker.C {
		mutex.Lock()
		ids := make([]int64, 0, len(tempUserData))
		for uid, data := range tempUserData {
			if _, ok := data["order_id"]; ok {
				ids = append(ids, uid)
			}
		}
		mutex.Unlock()

		for _, uid := range ids {
			mutex.Lock()
			data, ok := tempUserData[uid]
			mutex.Unlock()
			if !ok {
				continue
			}

			orderID := data["order_id"]
			price := data["price"]
			chatIDStr := data["chat_id"]
			password := data["password"]
			daysStr := data["days"]

			if orderID == "" || price == "" || chatIDStr == "" || password == "" || daysStr == "" {
				continue
			}

			chatID, _ := strconv.ParseInt(chatIDStr, 10, 64)
			status, err := checkPakasirStatus(cfg, orderID, price)
			if err != nil {
				continue
			}

			if status == "completed" || status == "success" {
				days, _ := strconv.Atoi(daysStr)

				// optional: delete QR message after paid (biar clean)
				deleteLastMessage(bot, chatID)

				createUser(bot, chatID, uid, password, days, cfg, "main", false)

				mutex.Lock()
				delete(tempUserData, uid)
				delete(userStates, uid)
				mutex.Unlock()
			}
		}
	}
}

// ==========================================
// Group Notify (ORDER/TRIAL) - FULL QUOTE
// ==========================================

func sendGroupNotify(bot *tgbotapi.BotAPI, cfg *BotConfig, isTrial bool, buyerID int64, buyerName, buyerUsername, region string, flag string, price string) {
	if cfg.NotifyGroupID == 0 {
		log.Printf("[GROUP] notify_group_id = 0 (mati), skip")
		return
	}

	buyer := buyerName
	if strings.TrimSpace(buyerUsername) != "" {
		buyer = "@" + buyerUsername
	}

	header := "✅ ORDER ZIVPN BERHASIL"
	if isTrial {
		header = "✅ TRIAL ZIVPN BERHASIL"
	}

	lines := []string{
		"━━━━━━━━━━━━━━━━━━━━━━",
		header,
		"━━━━━━━━━━━━━━━━━━━━━━",
	}

	if isTrial {
		lines = append(lines,
			fmt.Sprintf("🥷 User: %s", buyer),
			fmt.Sprintf("🆔 User ID: %d", buyerID),
			fmt.Sprintf("📆 Tanggal: %s", prettyDayDateWIB()),
			"",
			"📌 Detail Trial:",
			fmt.Sprintf("🌐 Server: %s %s", flag, region),
			"🔑 Password: xxxxxx",
		)
	} else {
		lines = append(lines,
			fmt.Sprintf("👤 Buyer: %s", buyer),
			fmt.Sprintf("🆔 User ID: %d", buyerID),
			fmt.Sprintf("📆 Tanggal: %s", prettyDayDateWIB()),
			"",
			"📌 Detail Produk:",
			fmt.Sprintf("🌐 Server: %s %s", flag, region),
			"🔑 Password: xxxxx",
			fmt.Sprintf("💰 Harga: %s", price),
		)
	}

	lines = append(lines, "━━━━━━━━━━━━━━━━━━━━━━")

	// 1) Coba kirim HTML (blockquote)
	msgHTML := quoteHTML(lines)
	m := tgbotapi.NewMessage(cfg.NotifyGroupID, msgHTML)
	m.ParseMode = "HTML"
	m.DisableWebPagePreview = true

	if _, err := bot.Send(m); err != nil {
		// 2) Kalau gagal, fallback plain text (PASTI terkirim kalau bot punya akses)
		log.Printf("[GROUP] send HTML failed: %v (fallback plain text)", err)

		plain := strings.Join(lines, "\n")
		m2 := tgbotapi.NewMessage(cfg.NotifyGroupID, plain)
		m2.DisableWebPagePreview = true

		if _, err2 := bot.Send(m2); err2 != nil {
			log.Printf("[GROUP] send plain failed: %v (group_id=%d)", err2, cfg.NotifyGroupID)
		}
	} else {
		log.Printf("[GROUP] sent OK (group_id=%d)", cfg.NotifyGroupID)
	}
}

// ==========================================
// API (User Ops)
// ==========================================

func createUser(bot *tgbotapi.BotAPI, chatID int64, userID int64, password string, days int, cfg *BotConfig, returnTo string, isTrial bool) {
	res, err := apiCall("POST", "/user/create", map[string]interface{}{
		"password": password,
		"days":     days,
		"ip_limit": limitIPDefault,
	})
	if err != nil {
		sendPlain(bot, chatID, "❌ Error API: "+err.Error())
		return
	}

	if res["success"] == true {
		data, _ := res["data"].(map[string]interface{})

		markAccountCreated()

		ipInfo, _ := getIpInfo()
		region := strings.TrimSpace(ipInfo.RegionName)
		if region == "" {
			region = strings.TrimSpace(ipInfo.Country)
		}
		flag := flagEmoji(ipInfo.CountryCode)

		bName := displayNameFromBotState(userID)
		bUname := usernameFromBotState(userID)

		priceText := "-"
		if !isTrial && returnTo == "main" && userID != cfg.AdminID {
			mutex.Lock()
			p := ""
			if tempUserData[userID] != nil {
				p = tempUserData[userID]["price"]
			}
			mutex.Unlock()
			if p != "" {
				if n, e := strconv.Atoi(p); e == nil {
					priceText = "Rp " + moneyIDR(n)
				} else {
					priceText = "Rp " + p
				}
			}
		}

		if isTrial || (!isTrial && returnTo == "main" && userID != cfg.AdminID) {
			sendGroupNotify(bot, cfg, isTrial, userID, bName, bUname, region, flag, priceText)
		}

		sendAccountInfo(bot, chatID, userID, data, cfg, returnTo, isTrial)
		return
	}
	sendPlain(bot, chatID, fmt.Sprintf("❌ Gagal membuat akun: %v", res["message"]))
}

func renewUser(bot *tgbotapi.BotAPI, chatID int64, userID int64, password string, days int, cfg *BotConfig) {
	res, err := apiCall("POST", "/user/renew", map[string]interface{}{
		"password": password,
		"days":     days,
	})
	if err != nil {
		sendPlain(bot, chatID, "❌ Error API: "+err.Error())
		return
	}

	if res["success"] == true {
		data, _ := res["data"].(map[string]interface{})
		sendAccountInfo(bot, chatID, userID, data, cfg, "admin", false)
		return
	}
	sendPlain(bot, chatID, fmt.Sprintf("❌ Gagal renew: %v", res["message"]))
}

func deleteUser(bot *tgbotapi.BotAPI, chatID int64, userID int64, password string, cfg *BotConfig) {
	res, err := apiCall("POST", "/user/delete", map[string]interface{}{
		"password": password,
	})
	if err != nil {
		sendPlain(bot, chatID, "❌ Error API: "+err.Error())
		return
	}

	if res["success"] == true {
		sendPlain(bot, chatID, "✅ Password berhasil dihapus.")
		showAdminUsersMenu(bot, chatID, userID, cfg)
		return
	}
	sendPlain(bot, chatID, fmt.Sprintf("❌ Gagal delete: %v", res["message"]))
}

// ==========================================
// Result Account (HTML) - DO NOT DELETE RESULT
// ==========================================

func sendAccountInfo(bot *tgbotapi.BotAPI, chatID int64, userID int64, data map[string]interface{}, cfg *BotConfig, returnTo string, isTrial bool) {
	ipInfo, _ := getIpInfo()

	domain := cfg.Domain
	if domain == "" {
		domain = "(Not Configured)"
	}

	pw := fmt.Sprintf("%v", data["password"])
	exp := fmt.Sprintf("%v", data["expired"])

	title := "✅ AKUN BERHASIL DIBUAT"
	if isTrial {
		title = "✅ TRIAL AKUN BERHASIL DIBUAT"
	}

	html := ""
	html += "<b>" + htmlEscape(title) + "</b>\n"
	html += "━━━━━━━━━━━━━━━━━━━━━━\n"
	html += "🔐 Password : " + codeHTML(pw) + "\n"
	html += "🌐 Domain   : " + codeHTML(domain) + "\n"
	html += "📱 Limit IP : " + codeHTML(fmt.Sprintf("%d", limitIPDefault)) + "\n"
	html += "🏙 City     : " + codeHTML(ipInfo.City) + "\n"
	html += "📡 ISP      : " + codeHTML(ipInfo.Isp) + "\n"
	html += "📅 Expired  : " + codeHTML(exp) + "\n"
	if isTrial {
		html += "⏳ Auto edit : " + codeHTML("100 menit") + "\n"
	}
	html += "━━━━━━━━━━━━━━━━━━━━━━\n"

	msg := tgbotapi.NewMessage(chatID, html)
	msg.ParseMode = "HTML"
	msg.DisableWebPagePreview = true
	sent, err := bot.Send(msg)
	if err != nil {
		return
	}

	if sent.MessageID != 0 {
		resultMu.Lock()
		resultMessageIDs[chatID] = sent.MessageID
		resultMu.Unlock()
		updateTrackedMessage(chatID, sent.MessageID)
	}

	go func(mid int) {
		time.Sleep(6 * time.Second)
		resultMu.Lock()
		delete(resultMessageIDs, chatID)
		resultMu.Unlock()
		updateTrackedMessage(chatID, mid)
		showMainMenuSimple(bot, chatID, userID, cfg)
	}(sent.MessageID)
}

// ==========================================
// Helpers (send / delete / cancel)
// ==========================================

func updateTrackedMessage(chatID int64, msgID int) {
	if msgID == 0 {
		return
	}
	lastMu.Lock()
	lastMessageIDs[chatID] = msgID
	lastMu.Unlock()
}

func getTrackedMessage(chatID int64) int {
	lastMu.Lock()
	defer lastMu.Unlock()
	return lastMessageIDs[chatID]
}

func sendAndTrack(bot *tgbotapi.BotAPI, msg tgbotapi.MessageConfig) {
	msgID := getTrackedMessage(msg.ChatID)

	if msgID != 0 {
		edit := tgbotapi.NewEditMessageText(msg.ChatID, msgID, msg.Text)
		emptyMarkup := tgbotapi.InlineKeyboardMarkup{InlineKeyboard: [][]tgbotapi.InlineKeyboardButton{}}
		edit.ReplyMarkup = &emptyMarkup
		if markup, ok := msg.ReplyMarkup.(tgbotapi.InlineKeyboardMarkup); ok {
			edit.ReplyMarkup = &markup
		}
		if markup, ok := msg.ReplyMarkup.(*tgbotapi.InlineKeyboardMarkup); ok {
			edit.ReplyMarkup = markup
		}
		_, err := bot.Send(edit)
		if err == nil {
			updateTrackedMessage(msg.ChatID, msgID)
			return
		}
	}

	sent, err := bot.Send(msg)
	if err != nil {
		log.Printf("SEND ERROR chat=%d: %v", msg.ChatID, err)
		msg.ParseMode = ""
		sent2, err2 := bot.Send(msg)
		if err2 != nil {
			log.Printf("SEND FALLBACK ERROR chat=%d: %v", msg.ChatID, err2)
			return
		}
		updateTrackedMessage(msg.ChatID, sent2.MessageID)
		return
	}

	updateTrackedMessage(msg.ChatID, sent.MessageID)
}

func sendAndTrackHTML(bot *tgbotapi.BotAPI, chatID int64, html string, kb *tgbotapi.InlineKeyboardMarkup) {
	msgID := getTrackedMessage(chatID)

	if msgID != 0 {
		edit := tgbotapi.NewEditMessageText(chatID, msgID, html)
		edit.ParseMode = "HTML"
		edit.DisableWebPagePreview = true
		emptyMarkup := tgbotapi.InlineKeyboardMarkup{InlineKeyboard: [][]tgbotapi.InlineKeyboardButton{}}
		edit.ReplyMarkup = &emptyMarkup
		if kb != nil {
			edit.ReplyMarkup = kb
		}
		_, err := bot.Send(edit)
		if err == nil {
			updateTrackedMessage(chatID, msgID)
			return
		}
	}

	msg := tgbotapi.NewMessage(chatID, html)
	msg.ParseMode = "HTML"
	msg.DisableWebPagePreview = true
	if kb != nil {
		msg.ReplyMarkup = kb
	}

	sent, err := bot.Send(msg)
	if err != nil {
		log.Printf("SEND HTML ERROR chat=%d: %v", chatID, err)
		msg.ParseMode = ""
		msg.Text = stripHTML(html)
		sent2, err2 := bot.Send(msg)
		if err2 != nil {
			log.Printf("SEND HTML FALLBACK ERROR chat=%d: %v", chatID, err2)
			return
		}
		updateTrackedMessage(chatID, sent2.MessageID)
		return
	}

	updateTrackedMessage(chatID, sent.MessageID)
}

func deleteLastMessage(bot *tgbotapi.BotAPI, chatID int64) {
	lastMu.Lock()
	msgID, ok := lastMessageIDs[chatID]
	if ok {
		delete(lastMessageIDs, chatID)
	}
	lastMu.Unlock()

	if !ok || msgID == 0 {
		return
	}

	resultMu.Lock()
	protected := resultMessageIDs[chatID]
	resultMu.Unlock()

	if protected != 0 && msgID == protected {
		return
	}

	_, err := bot.Request(tgbotapi.NewDeleteMessage(chatID, msgID))
	if err != nil {
		log.Printf("DELETE ERROR chat=%d msg=%d: %v", chatID, msgID, err)
	}
}

func sendPlain(bot *tgbotapi.BotAPI, chatID int64, text string) {
	msgID := getTrackedMessage(chatID)

	if msgID != 0 {
		edit := tgbotapi.NewEditMessageText(chatID, msgID, text)
		emptyMarkup := tgbotapi.InlineKeyboardMarkup{InlineKeyboard: [][]tgbotapi.InlineKeyboardButton{}}
		edit.ReplyMarkup = &emptyMarkup
		_, err := bot.Send(edit)
		if err == nil {
			updateTrackedMessage(chatID, msgID)
			return
		}
	}

	msg := tgbotapi.NewMessage(chatID, text)
	sent, err := bot.Send(msg)
	if err != nil {
		log.Printf("SEND PLAIN ERROR chat=%d: %v", chatID, err)
		return
	}
	updateTrackedMessage(chatID, sent.MessageID)
}

func cancelOperation(bot *tgbotapi.BotAPI, chatID, userID int64, cfg *BotConfig, from *tgbotapi.User) {
	resetAllState(userID)
	showMainMenu(bot, chatID, userID, from, cfg)
}

func resetAllState(userID int64) {
	mutex.Lock()
	delete(userStates, userID)
	delete(tempUserData, userID)
	mutex.Unlock()
}

// ==========================================
// Validators
// ==========================================

func validatePassword(bot *tgbotapi.BotAPI, chatID int64, text string) bool {
	if len(text) < 3 || len(text) > 20 {
		sendPlain(bot, chatID, "❌ Password harus 3-20 karakter. Coba lagi:")
		return false
	}
	if !regexp.MustCompile(`^[a-zA-Z0-9_-]+$`).MatchString(text) {
		sendPlain(bot, chatID, "❌ Password hanya boleh huruf, angka, - dan _. Coba lagi:")
		return false
	}
	return true
}

func validateNumber(bot *tgbotapi.BotAPI, chatID int64, text string, min, max int, fieldName string) (int, bool) {
	val, err := strconv.Atoi(strings.ReplaceAll(text, ",", ""))
	if err != nil || val < min || val > max {
		sendPlain(bot, chatID, fmt.Sprintf("❌ %s harus angka (%d-%d). Coba lagi:", fieldName, min, max))
		return 0, false
	}
	return val, true
}

// ==========================================
// Config
// ==========================================

func loadConfig() (BotConfig, error) {
	var cfg BotConfig
	b, err := os.ReadFile(BotConfigFile)
	if err != nil {
		return cfg, err
	}
	if err := json.Unmarshal(b, &cfg); err != nil {
		return cfg, err
	}
	if strings.TrimSpace(cfg.Mode) == "" {
		cfg.Mode = "private"
	}
	if cfg.Domain == "" {
		if d, err2 := os.ReadFile(DomainFile); err2 == nil {
			cfg.Domain = strings.TrimSpace(string(d))
		}
	}
	return cfg, nil
}

func saveConfig(cfg *BotConfig) error {
	b, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(BotConfigFile, b, 0644)
}

func maskKey(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return "-"
	}
	if len(s) <= 6 {
		return "***"
	}
	return s[:3] + "****" + s[len(s)-3:]
}

func maskShort(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return "-"
	}
	if len(s) > 24 {
		return s[:24]
	}
	return s
}

// ==========================================
// API Client
// ==========================================

func apiCall(method, endpoint string, payload interface{}) (map[string]interface{}, error) {
	var reqBody []byte
	var err error
	if payload != nil {
		reqBody, err = json.Marshal(payload)
		if err != nil {
			return nil, err
		}
	}

	client := &http.Client{Timeout: 20 * time.Second}
	req, err := http.NewRequest(method, ApiUrl+endpoint, bytes.NewBuffer(reqBody))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-API-Key", ApiKey)

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	var result map[string]interface{}
	_ = json.Unmarshal(body, &result)
	return result, nil
}

func getIpInfo() (IpInfo, error) {
	client := &http.Client{Timeout: 4 * time.Second}
	req, err := http.NewRequest("GET", "http://ip-api.com/json/", nil)
	if err != nil {
		return IpInfo{City: "-", Isp: ""}, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return IpInfo{City: "-", Isp: ""}, err
	}
	defer resp.Body.Close()

	var info IpInfo
	if err := json.NewDecoder(resp.Body).Decode(&info); err != nil {
		return IpInfo{City: "-", Isp: ""}, err
	}
	if strings.TrimSpace(info.City) == "" {
		info.City = "-"
	}
	return info, nil
}

func getUsers() ([]UserData, error) {
	res, err := apiCall("GET", "/users", nil)
	if err != nil {
		return nil, err
	}
	if res["success"] != true {
		return nil, fmt.Errorf("failed to get users")
	}

	var users []UserData
	dataBytes, _ := json.Marshal(res["data"])
	_ = json.Unmarshal(dataBytes, &users)
	return users, nil
}

// ==========================================
// Broadcast (Admin) - MISSING FUNCS PATCH
// ==========================================

func startBroadcast(bot *tgbotapi.BotAPI, chatID int64, userID int64) {
	mutex.Lock()
	userStates[userID] = "admin_broadcast_wait"
	mutex.Unlock()

	msg := ""
	msg += "📣 <b>KIRIM PENGUMUMAN</b>\n"
	msg += "━━━━━━━━━━━━━━━━━━━━━━\n"
	msg += "Kirim sekarang:\n"
	msg += "• Teks biasa, atau\n"
	msg += "• Gambar + Caption\n"
	msg += "━━━━━━━━━━━━━━━━━━━━━━\n"
	msg += "Untuk batal, tekan tombol di bawah."

	markup := tgbotapi.NewInlineKeyboardMarkup(
		tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(btnCancel, "cancel")),
	)
	sendAndTrackHTML(bot, chatID, msg, &markup)
}

func processBroadcastMessage(bot *tgbotapi.BotAPI, msg *tgbotapi.Message, cfg *BotConfig) {
	chatID := msg.Chat.ID
	userID := msg.From.ID
	if userID != cfg.AdminID {
		return
	}

	mutex.Lock()
	st := loadBotState()
	mutex.Unlock()

	type target struct {
		uid int64
	}
	var targets []target
	for _, u := range st.Users {
		if u == nil || u.IsBlocked {
			continue
		}
		targets = append(targets, target{uid: u.ID})
	}

	hasPhoto := (len(msg.Photo) > 0)
	isText := strings.TrimSpace(msg.Text) != ""
	caption := strings.TrimSpace(msg.Caption)

	if !hasPhoto && !isText {
		sendPlain(bot, chatID, "❌ Kirim teks atau gambar + caption.")
		return
	}

	// stop state broadcast
	mutex.Lock()
	delete(userStates, userID)
	mutex.Unlock()

	sendPlain(bot, chatID, fmt.Sprintf("⏳ Mengirim pengumuman ke %d user...", len(targets)))

	success := 0
	fail := 0

	for _, t := range targets {
		if hasPhoto {
			photos := msg.Photo
			fileID := photos[len(photos)-1].FileID
			p := tgbotapi.NewPhoto(t.uid, tgbotapi.FileID(fileID))
			if caption != "" {
				p.Caption = caption
				p.ParseMode = "HTML"
			}
			_, err := bot.Send(p)
			if err != nil {
				fail++
				markUserBlockedIfNeeded(t.uid, err)
			} else {
				success++
			}
		} else {
			m := tgbotapi.NewMessage(t.uid, msg.Text)
			m.ParseMode = "HTML"
			_, err := bot.Send(m)
			if err != nil {
				// fallback plain text kalau html fail
				m.ParseMode = ""
				m.Text = stripHTML(msg.Text)
				_, err2 := bot.Send(m)
				if err2 != nil {
					fail++
					markUserBlockedIfNeeded(t.uid, err2)
				} else {
					success++
				}
			} else {
				success++
			}
		}
		time.Sleep(35 * time.Millisecond)
	}

	sendPlain(bot, chatID, fmt.Sprintf("✅ Broadcast selesai.\nBerhasil: %d\nGagal: %d", success, fail))
	showAdminMenu(bot, chatID, userID, cfg)
}

// ==========================================
// User List / Pagination (Admin) - MISSING FUNCS PATCH
// ==========================================

func listUsers(bot *tgbotapi.BotAPI, chatID int64) {
	users, err := getUsers()
	if err != nil {
		sendPlain(bot, chatID, "❌ Gagal mengambil data user.")
		return
	}
	if len(users) == 0 {
		sendPlain(bot, chatID, "📂 Tidak ada user.")
		return
	}

	var b strings.Builder
	b.WriteString("📋 List Passwords\n")
	for _, u := range users {
		st := "🟢"
		if strings.EqualFold(u.Status, "Expired") {
			st = "🔴"
		}
		b.WriteString(fmt.Sprintf("\n%s %s (%s)", st, u.Password, u.Expired))
	}
	sendPlain(bot, chatID, b.String())
}

func showUserSelection(bot *tgbotapi.BotAPI, chatID int64, page int, action string) {
	users, err := getUsers()
	if err != nil {
		sendPlain(bot, chatID, "❌ Gagal mengambil data user.")
		return
	}
	if len(users) == 0 {
		sendPlain(bot, chatID, "📂 Tidak ada user.")
		return
	}

	perPage := 10
	totalPages := (len(users) + perPage - 1) / perPage
	if page < 1 {
		page = 1
	}
	if page > totalPages {
		page = totalPages
	}

	start := (page - 1) * perPage
	end := start + perPage
	if end > len(users) {
		end = len(users)
	}

	var rows [][]tgbotapi.InlineKeyboardButton
	for _, u := range users[start:end] {
		label := fmt.Sprintf("%s (%s)", u.Password, u.Status)
		if strings.EqualFold(u.Status, "Expired") {
			label = "🔴 " + label
		} else {
			label = "🟢 " + label
		}
		cb := fmt.Sprintf("select_%s:%s", action, u.Password)
		rows = append(rows, tgbotapi.NewInlineKeyboardRow(
			tgbotapi.NewInlineKeyboardButtonData(label, cb),
		))
	}

	var navRow []tgbotapi.InlineKeyboardButton
	if page > 1 {
		navRow = append(navRow, tgbotapi.NewInlineKeyboardButtonData("⬅️ Prev", fmt.Sprintf("page_%s:%d", action, page-1)))
	}
	if page < totalPages {
		navRow = append(navRow, tgbotapi.NewInlineKeyboardButtonData("Next ➡️", fmt.Sprintf("page_%s:%d", action, page+1)))
	}
	if len(navRow) > 0 {
		rows = append(rows, navRow)
	}
	rows = append(rows, tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(btnBack, "back_admin_users")))

	msg := tgbotapi.NewMessage(chatID, fmt.Sprintf("📋 Pilih User untuk %s (Halaman %d/%d):", strings.Title(action), page, totalPages))
	msg.ReplyMarkup = tgbotapi.NewInlineKeyboardMarkup(rows...)
	sendAndTrack(bot, msg)
}

func handlePagination(bot *tgbotapi.BotAPI, chatID int64, data string) {
	parts := strings.Split(data, ":")
	if len(parts) != 2 {
		return
	}
	action := strings.TrimPrefix(parts[0], "page_")
	page, _ := strconv.Atoi(parts[1])
	showUserSelection(bot, chatID, page, action)
}

func startRenewUser(bot *tgbotapi.BotAPI, chatID int64, userID int64, data string) {
	username := strings.TrimPrefix(data, "select_renew:")
	mutex.Lock()
	if _, ok := tempUserData[userID]; !ok {
		tempUserData[userID] = make(map[string]string)
	}
	tempUserData[userID]["username"] = username
	userStates[userID] = "renew_days"
	mutex.Unlock()

	sendPlain(bot, chatID, fmt.Sprintf("🔄 Renew %s\n\n⏳ Masukkan Tambahan Durasi (hari):", username))
}

func confirmDeleteUser(bot *tgbotapi.BotAPI, chatID int64, data string) {
	username := strings.TrimPrefix(data, "select_delete:")
	msg := tgbotapi.NewMessage(chatID, fmt.Sprintf("❓ Yakin ingin menghapus %s?", username))
	msg.ReplyMarkup = tgbotapi.NewInlineKeyboardMarkup(
		tgbotapi.NewInlineKeyboardRow(
			tgbotapi.NewInlineKeyboardButtonData("✅ Ya, Hapus", "confirm_delete:"+username),
			tgbotapi.NewInlineKeyboardButtonData(btnCancel, "back_admin_users"),
		),
	)
	sendAndTrack(bot, msg)
}

// ==========================================
// Pakasir
// ==========================================

func createPakasirTransaction(cfg *BotConfig, orderID string, amount int) (*PakasirPayment, error) {
	url := "https://app.pakasir.com/api/transactioncreate/qris"
	payload := map[string]interface{}{
		"project":  cfg.PakasirSlug,
		"order_id": orderID,
		"amount":   amount,
		"api_key":  cfg.PakasirApiKey,
	}

	jsonPayload, _ := json.Marshal(payload)
	req, _ := http.NewRequest("POST", url, bytes.NewBuffer(jsonPayload))
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 12 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var result map[string]interface{}
	_ = json.NewDecoder(resp.Body).Decode(&result)

	if paymentData, ok := result["payment"].(map[string]interface{}); ok {
		pn, _ := paymentData["payment_number"].(string)
		ea, _ := paymentData["expired_at"].(string)
		if pn == "" {
			return nil, fmt.Errorf("invalid response (payment_number kosong)")
		}
		return &PakasirPayment{PaymentNumber: pn, ExpiredAt: ea}, nil
	}
	return nil, fmt.Errorf("invalid response from Pakasir")
}

func checkPakasirStatus(cfg *BotConfig, orderID string, amountStr string) (string, error) {
	url := fmt.Sprintf(
		"https://app.pakasir.com/api/transactiondetail?project=%s&amount=%s&order_id=%s&api_key=%s",
		cfg.PakasirSlug, amountStr, orderID, cfg.PakasirApiKey,
	)

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	var result map[string]interface{}
	_ = json.NewDecoder(resp.Body).Decode(&result)

	if transaction, ok := result["transaction"].(map[string]interface{}); ok {
		st, _ := transaction["status"].(string)
		if st == "" {
			return "", fmt.Errorf("status kosong")
		}
		return st, nil
	}
	return "", fmt.Errorf("transaction not found")
}

func testPakasir(bot *tgbotapi.BotAPI, chatID int64, cfg *BotConfig) {
	if strings.TrimSpace(cfg.PakasirSlug) == "" || strings.TrimSpace(cfg.PakasirApiKey) == "" {
		sendPlain(bot, chatID, "❌ Pakasir belum diset.")
		return
	}
	orderID := fmt.Sprintf("TEST-%d", time.Now().Unix())
	p, err := createPakasirTransaction(cfg, orderID, 500)
	if err != nil {
		sendPlain(bot, chatID, "❌ Test gagal: "+err.Error())
		return
	}
	sendPlain(bot, chatID, "✅ Test OK\nPaymentNumber: "+p.PaymentNumber+"\nExpiredAt: "+p.ExpiredAt)
}

// ==========================================
// Backup / Restore (VPN & BOT dipisah)
// ==========================================

func performVPNBackup(bot *tgbotapi.BotAPI, chatID int64) {
	sendPlain(bot, chatID, "⏳ Sedang membuat backup data VPN...")

	files := []string{
		"/etc/zivpn/config.json",
		"/etc/zivpn/users.json",
		"/etc/zivpn/domain",
		"/etc/zivpn/apikey",
		"/etc/zivpn/api_port",
		"/etc/zivpn/port",
	}

	buf := new(bytes.Buffer)
	zipWriter := zip.NewWriter(buf)

	for _, file := range files {
		if _, err := os.Stat(file); os.IsNotExist(err) {
			continue
		}
		f, err := os.Open(file)
		if err != nil {
			continue
		}
		func(src *os.File, fullPath string) {
			defer src.Close()
			w, err := zipWriter.Create(filepath.Base(fullPath))
			if err != nil {
				return
			}
			_, _ = io.Copy(w, src)
		}(f, file)
	}
	_ = zipWriter.Close()

	fileName := fmt.Sprintf("zivpn-vpn-backup-%s.zip", time.Now().Format("20060102-150405"))
	tmpFile := "/tmp/" + fileName
	if err := os.WriteFile(tmpFile, buf.Bytes(), 0644); err != nil {
		sendPlain(bot, chatID, "❌ Gagal membuat file backup VPN.")
		return
	}
	defer os.Remove(tmpFile)

	doc := tgbotapi.NewDocument(chatID, tgbotapi.FilePath(tmpFile))
	doc.Caption = "✅ Backup Data VPN"
	deleteLastMessage(bot, chatID)
	_, _ = bot.Send(doc)
}

func startVPNRestore(bot *tgbotapi.BotAPI, chatID int64, userID int64) {
	mutex.Lock()
	userStates[userID] = "waiting_restore_vpn_file"
	mutex.Unlock()
	sendPlain(bot, chatID, "⬆️ Restore Data VPN\n\nSilakan kirim file ZIP backup data VPN.\n⚠️ Data VPN saat ini akan ditimpa.")
}

func processVPNRestoreFile(bot *tgbotapi.BotAPI, msg *tgbotapi.Message, cfg *BotConfig) {
	chatID := msg.Chat.ID
	userID := msg.From.ID

	resetAllState(userID)
	sendPlain(bot, chatID, "⏳ Memproses restore data VPN...")

	if msg.Document == nil {
		sendPlain(bot, chatID, "❌ File tidak ditemukan.")
		return
	}

	fileID := msg.Document.FileID
	f, err := bot.GetFile(tgbotapi.FileConfig{FileID: fileID})
	if err != nil {
		sendPlain(bot, chatID, "❌ Gagal mengunduh file.")
		return
	}

	fileURL := f.Link(cfg.BotToken)
	resp, err := http.Get(fileURL)
	if err != nil {
		sendPlain(bot, chatID, "❌ Gagal download content.")
		return
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		sendPlain(bot, chatID, "❌ Gagal membaca file.")
		return
	}

	zipReader, err := zip.NewReader(bytes.NewReader(body), int64(len(body)))
	if err != nil {
		sendPlain(bot, chatID, "❌ File bukan ZIP valid.")
		return
	}

	validFiles := map[string]bool{
		"config.json": true,
		"users.json":  true,
		"domain":      true,
		"apikey":      true,
		"api_port":    true,
		"port":        true,
	}

	for _, zf := range zipReader.File {
		if !validFiles[zf.Name] {
			continue
		}
		rc, err := zf.Open()
		if err != nil {
			continue
		}
		dstPath := filepath.Join("/etc/zivpn", zf.Name)
		dst, err := os.Create(dstPath)
		if err != nil {
			_ = rc.Close()
			continue
		}
		_, _ = io.Copy(dst, rc)
		_ = dst.Close()
		_ = rc.Close()
	}

	_ = exec.Command("systemctl", "restart", "zivpn").Run()
	_ = exec.Command("systemctl", "restart", "zivpn-api").Run()

	_, _ = bot.Send(tgbotapi.NewMessage(chatID, "✅ Restore data VPN berhasil! Service direstart."))
	go func() {
		time.Sleep(2 * time.Second)
		_ = exec.Command("systemctl", "restart", "zivpn-bot").Run()
	}()

	showMainMenu(bot, chatID, userID, msg.From, cfg)
}

func performBotBackup(bot *tgbotapi.BotAPI, chatID int64) {
	sendPlain(bot, chatID, "⏳ Sedang membuat backup database bot...")

	files := []string{
		BotConfigFile,
		TrialStateFile,
		BotStateFile,
	}

	buf := new(bytes.Buffer)
	zipWriter := zip.NewWriter(buf)

	for _, file := range files {
		if _, err := os.Stat(file); os.IsNotExist(err) {
			continue
		}
		f, err := os.Open(file)
		if err != nil {
			continue
		}
		func(src *os.File, fullPath string) {
			defer src.Close()
			w, err := zipWriter.Create(filepath.Base(fullPath))
			if err != nil {
				return
			}
			_, _ = io.Copy(w, src)
		}(f, file)
	}
	_ = zipWriter.Close()

	fileName := fmt.Sprintf("zivpn-bot-backup-%s.zip", time.Now().Format("20060102-150405"))
	tmpFile := "/tmp/" + fileName
	if err := os.WriteFile(tmpFile, buf.Bytes(), 0644); err != nil {
		sendPlain(bot, chatID, "❌ Gagal membuat file backup database bot.")
		return
	}
	defer os.Remove(tmpFile)

	doc := tgbotapi.NewDocument(chatID, tgbotapi.FilePath(tmpFile))
	doc.Caption = "✅ Backup Database Bot"
	deleteLastMessage(bot, chatID)
	_, _ = bot.Send(doc)
}

func startBotRestore(bot *tgbotapi.BotAPI, chatID int64, userID int64) {
	mutex.Lock()
	userStates[userID] = "waiting_restore_bot_file"
	mutex.Unlock()
	sendPlain(bot, chatID, "⬆️ Restore Database Bot\n\nSilakan kirim file ZIP backup database bot.\n⚠️ Data bot saat ini akan ditimpa.")
}

func processBotRestoreFile(bot *tgbotapi.BotAPI, msg *tgbotapi.Message, cfg *BotConfig) {
	chatID := msg.Chat.ID
	userID := msg.From.ID

	resetAllState(userID)
	sendPlain(bot, chatID, "⏳ Memproses restore database bot...")

	if msg.Document == nil {
		sendPlain(bot, chatID, "❌ File tidak ditemukan.")
		return
	}

	fileID := msg.Document.FileID
	f, err := bot.GetFile(tgbotapi.FileConfig{FileID: fileID})
	if err != nil {
		sendPlain(bot, chatID, "❌ Gagal mengunduh file.")
		return
	}

	fileURL := f.Link(cfg.BotToken)
	resp, err := http.Get(fileURL)
	if err != nil {
		sendPlain(bot, chatID, "❌ Gagal download content.")
		return
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		sendPlain(bot, chatID, "❌ Gagal membaca file.")
		return
	}

	zipReader, err := zip.NewReader(bytes.NewReader(body), int64(len(body)))
	if err != nil {
		sendPlain(bot, chatID, "❌ File bukan ZIP valid.")
		return
	}

	validFiles := map[string]string{
		"bot-config.json":  BotConfigFile,
		"trial-state.json": TrialStateFile,
		"bot-state.json":   BotStateFile,
	}

	restored := 0
	for _, zf := range zipReader.File {
		dstPath, ok := validFiles[zf.Name]
		if !ok {
			continue
		}
		rc, err := zf.Open()
		if err != nil {
			continue
		}
		data, err := io.ReadAll(rc)
		_ = rc.Close()
		if err != nil {
			continue
		}
		if err := os.WriteFile(dstPath, data, 0644); err != nil {
			continue
		}
		restored++
	}

	if restored == 0 {
		sendPlain(bot, chatID, "❌ Tidak ada file database bot yang valid di dalam ZIP.")
		return
	}

	_, _ = bot.Send(tgbotapi.NewMessage(chatID, "✅ Restore database bot berhasil! Bot akan direstart."))
	go func() {
		time.Sleep(2 * time.Second)
		_ = exec.Command("systemctl", "restart", "zivpn-bot").Run()
	}()
}

// ==========================================
// System Info
// ==========================================

func systemInfo(bot *tgbotapi.BotAPI, chatID, userID int64, cfg *BotConfig) {
	res, err := apiCall("GET", "/info", nil)
	if err != nil {
		sendPlain(bot, chatID, "❌ Error API: "+err.Error())
		return
	}
	if res["success"] != true {
		sendPlain(bot, chatID, "❌ Gagal mengambil info.")
		return
	}

	data, _ := res["data"].(map[string]interface{})
	ipInfo, _ := getIpInfo()

	html := ""
	html += "<b>📊 SYSTEM INFO</b>\n"
	html += "━━━━━━━━━━━━━━━━━━━━━━\n"
	html += "🌐 Domain    : " + codeHTML(cfg.Domain) + "\n"
	html += "📍 Public IP : " + codeHTML(fmt.Sprintf("%v", data["public_ip"])) + "\n"
	html += "🔌 Port      : " + codeHTML(fmt.Sprintf("%v", data["port"])) + "\n"
	html += "⚙️ Service   : " + codeHTML(fmt.Sprintf("%v", data["service"])) + "\n"
	html += "🏙 City      : " + codeHTML(ipInfo.City) + "\n"
	html += "📡 ISP       : " + codeHTML(ipInfo.Isp) + "\n"
	html += "━━━━━━━━━━━━━━━━━━━━━━\n"

	markup := tgbotapi.NewInlineKeyboardMarkup(
		tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(btnBack, "back_main")),
	)
	sendAndTrackHTML(bot, chatID, html, &markup)
}

// ==========================================
// Mode Toggle
// ==========================================

func toggleMode(bot *tgbotapi.BotAPI, chatID int64, userID int64, cfg *BotConfig) {
	if userID != cfg.AdminID {
		return
	}
	if strings.ToLower(cfg.Mode) == "public" {
		cfg.Mode = "private"
	} else {
		cfg.Mode = "public"
	}
	_ = saveConfig(cfg)
	sendPlain(bot, chatID, "✅ Mode diubah menjadi: "+cfg.Mode)
	showAdminMenu(bot, chatID, userID, cfg)
}

// ==========================================
// Blocked marker (helper) - MISSING FUNCS PATCH
// ==========================================

func markUserBlockedIfNeeded(targetID int64, err error) {
	if err == nil {
		return
	}
	es := strings.ToLower(err.Error())
	if strings.Contains(es, "blocked") || strings.Contains(es, "chat not found") || strings.Contains(es, "forbidden") {
		mutex.Lock()
		defer mutex.Unlock()
		st := loadBotState()
		key := strconv.FormatInt(targetID, 10)
		if st.Users[key] != nil {
			st.Users[key].IsBlocked = true
			saveBotState(st)
		}
	}
}
