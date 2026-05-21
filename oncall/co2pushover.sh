#!/usr/bin/env bash
# ============================================================
#  CO2 Sysadmin Alert Bot — Revamped
#  Telethon (telethon.py) tetap service terpisah
#
#  Flow saat ada tag ke TEAM_USERNAMES:
#    [1]  Whitelist check  : skip jika sender ada di SKIP_USERS
#    [2]  Forward internal : kirim notif ke group sysadmin
#    [3]  Download media   : ambil gambar via Bot API (jika ada)
#    [4]  Image analysis   : kirim ke Groq Vision (jika ada gambar)
#    [5]  Scope detection  : keyword guardrail → Groq LLM
#    [6]  Generate reply   : in-scope → random ack | out-scope → cc @DEV_TAG
#    [7]  Human delay      : sleep random DELAY_MIN–DELAY_MAX detik
#    [8]  Kirim reply      : POST /reply ke Telethon service
#    [9]  Sleep hour check : sleep → Pushover escalation | working → notif aja
#    [10] Incident log     : dokumentasi ke CSV
#
#  Usage: ./co2pushover.sh
#  Log  : journalctl -u soy-oncall -f
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load .env ─────────────────────────────────────────────────────────────────
[[ ! -f "$SCRIPT_DIR/.env" ]] && { echo "ERROR: .env tidak ditemukan"; exit 1; }
source "$SCRIPT_DIR/.env"

# ── Validasi env wajib ────────────────────────────────────────────────────────
for var in BOT_TOKEN BOT_USERNAME TEAM_USERNAMES \
           SYSADMIN_CHAT_ID INTERNAL_CHAT_ID \
           GROQ_API_KEY TELETHON_URL \
           PUSHOVER_TOKEN PUSHOVER_USER; do
  [[ -z "${!var:-}" ]] && { echo "ERROR: '$var' belum diisi di .env"; exit 1; }
done

# ── Konstanta & default ───────────────────────────────────────────────────────
API_URL="https://api.telegram.org/bot${BOT_TOKEN}"
OFFSET=0

GROQ_MODEL="${GROQ_MODEL:-meta-llama/llama-4-scout-17b-16e-instruct}"
GROQ_VISION_MODEL="${GROQ_VISION_MODEL:-meta-llama/llama-4-scout-17b-16e-instruct}"

SLEEP_HOUR_START="${SLEEP_HOUR_START:-22:00}"
SLEEP_HOUR_END="${SLEEP_HOUR_END:-06:00}"
TZ_JAKARTA="${TZ_JAKARTA:-Asia/Jakarta}"

DELAY_MIN="${DELAY_MIN:-3}"
DELAY_MAX="${DELAY_MAX:-7}"

SKIP_USERS="${SKIP_USERS:-}"       # pisah koma, tanpa @
DEV_TAG="${DEV_TAG:-@developer}"   # tag developer untuk out-of-scope

LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/incidents}"
TMP_DIR="${TMPDIR:-/tmp}"

# ── Reply pool (in-scope fallback) ────────────────────────────────────────────
REPLY_POOL=(
  "siap ko, dcek bentar ya"
  "oke ko, otw cek"
  "siap ko, dcek dl"
  "ok ko, bentar dcek dlu"
  "noted ko, otw dcek"
  "siaap ko, dcek bentar"
  "bentar ya ko, lg dcek"
  "ok ko, dcek dulu"
  "siap ko, langsung dicek"
  "otw cek ko"
)

# ── Keyword sysadmin — guardrail sebelum hit Groq ─────────────────────────────
# Jika salah satu keyword ini ada di pesan → langsung in-scope, skip LLM
SYSADMIN_KEYWORDS=(
  server vps vm instance cloud hosting
  network jaringan koneksi connection ip dns firewall bandwidth latency ping timeout port
  nginx apache caddy haproxy traefik cf cloudflare
  database db mysql postgres postgresql mongodb redis mariadb sqlite
  down error crash restart reboot hang stuck
  mati ngadat lemot slow failed fail berat gangguan
  "not responding" "tidak bisa" gabisa "ga bisa" "gak bisa"
  "500" "502" "503" "504"
  deploy deployment docker container kubernetes k8s pod image build pipeline
  ssl certificate cert https domain expired seo robots ipos
  monitoring log alert grafana prometheus zabbix statistic
  disk storage backup restore penuh
  ssh akses access login credentials permission denied
  website web api endpoint service aplikasi app bot config link banner
  pgsoft pragmatic provider
  resolve pointing upgrade
  "tidak jalan" "ga jalan" "gak jalan" "tidak berjalan"
)

# ─────────────────────────────────────────────────────────────────────────────
log() { echo "[$(date '+%F %T')] $*" >&2; }

# ── Dynamic Random delay (Human-like) ─────────────────────────────────────────
random_delay() {
  local msg_text="$1"
  local reply_text="$2"
  local has_image="${3:-}"
  local is_sleep="${4:-false}"

  python3 - "$msg_text" "$reply_text" "$has_image" "$is_sleep" <<'PYEOF'
import sys, time, random

msg = sys.argv[1]
reply = sys.argv[2]
has_img = sys.argv[3] == "yes" or sys.argv[3] == "true"
is_sleep = sys.argv[4] == "true"

# 1. Reading time (approx 0.15s - 0.25s per word)
words = len(msg.split())
read_time = words * random.uniform(0.15, 0.25)

# 2. Image viewing time (if image is present, add 1.5s - 3.0s)
img_time = random.uniform(1.5, 3.0) if has_img else 0.0

# 3. Thinking time / Decision jitter
if is_sleep:
    # At night, simulate waking up/finding phone: 12.0s - 25.0s
    think_time = random.uniform(12.0, 25.0)
else:
    # During the day: 1.0s - 2.5s
    think_time = random.uniform(1.0, 2.5)

total_delay = read_time + img_time + think_time

if is_sleep:
    total_delay = min(max(total_delay, 12.0), 30.0)
else:
    total_delay = min(max(total_delay, 2.0), 7.0)

d = round(total_delay, 1)
print(d)
time.sleep(d)
PYEOF
}

# ── Random pick dari reply pool ───────────────────────────────────────────────
random_reply() {
  local idx=$(( RANDOM % ${#REPLY_POOL[@]} ))
  echo "${REPLY_POOL[$idx]}"
}

# ── Cek apakah sender ada di SKIP_USERS ──────────────────────────────────────
is_skip_user() {
  local sender_lower
  sender_lower=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  [[ -z "$SKIP_USERS" ]] && return 1

  local IFS=','
  for u in $SKIP_USERS; do
    local u_lower
    u_lower=$(printf '%s' "${u// /}" | tr 'A-Z' 'a-z')
    [[ "$sender_lower" == "$u_lower" ]] && return 0
  done
  return 1
}

# ── Sanitize HTML ─────────────────────────────────────────────────────────────
html_escape() {
  echo "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

# ── Hitung tanggal incident ───────────────────────────────────────────────────
incident_date() {
  local now_minutes start_minutes
  now_minutes=$(TZ="$TZ_JAKARTA" date '+%H * 60 + %M' | bc)
  start_minutes=$(python3 -c "h,m=map(int,'${SLEEP_HOUR_START}'.split(':'));print(h*60+m)")
  if [[ "$now_minutes" -ge "$start_minutes" ]]; then
    TZ="$TZ_JAKARTA" date -d '+1 day' '+%Y-%m-%d'
  else
    TZ="$TZ_JAKARTA" date '+%Y-%m-%d'
  fi
}

# ── Dokumentasi incident ke CSV ───────────────────────────────────────────────
incident_log() {
  local chat_title="$1" chat_id="$2" message_text="$3"
  local scope_label="$4" pushover_summary="$5"

  mkdir -p "$LOG_DIR"
  local file_date csv_file timestamp
  file_date=$(incident_date)
  csv_file="$LOG_DIR/incidents_${file_date}.csv"
  timestamp=$(TZ="$TZ_JAKARTA" date '+%Y-%m-%d %H:%M:%S')

  [[ ! -f "$csv_file" ]] && \
    echo "timestamp,group_name,chat_id,message,scope,pushover_summary" > "$csv_file"

  python3 - "$timestamp" "$chat_title" "$chat_id" \
             "$message_text" "$scope_label" "$pushover_summary" <<'PYEOF'
import csv, sys, io
row = sys.argv[1:7]
buf = io.StringIO()
csv.writer(buf, quoting=csv.QUOTE_ALL).writerow(row)
print(buf.getvalue(), end='')
PYEOF
}

# ── Cek sleep hours ───────────────────────────────────────────────────────────
is_sleep_hours() {
  local current_minutes="$1"
  python3 - "$current_minutes" "$SLEEP_HOUR_START" "$SLEEP_HOUR_END" <<'PYEOF'
import sys
cur = int(sys.argv[1])
sh, sm = map(int, sys.argv[2].split(":"))
eh, em = map(int, sys.argv[3].split(":"))
start = sh * 60 + sm
end   = eh * 60 + em
if start > end:
    result = cur >= start or cur < end
else:
    result = start <= cur < end
sys.exit(0 if result else 1)
PYEOF
}

# ── Waktu Jakarta ─────────────────────────────────────────────────────────────
get_current_minutes() {
  TZ="$TZ_JAKARTA" date '+%H * 60 + %M' | bc
}
get_time_string() {
  TZ="$TZ_JAKARTA" date '+%H:%M:%S'
}

# ── [1] Forward ke group internal sysadmin ────────────────────────────────────
send_telegram() {
  local chat_id="$1" text="$2"
  local resp http_code
  resp=$(curl -s -w "\n%{http_code}" -X POST "$API_URL/sendMessage" \
    -d "chat_id=$chat_id" \
    --data-urlencode "text=$text" \
    -d "parse_mode=HTML")
  http_code=$(echo "$resp" | tail -n1)
  [[ "$http_code" -ne 200 ]] && \
    log "   ❌ Telegram gagal ($http_code): $(echo "$resp" | sed '$d')"
}

# ── [3] Download media dari Bot API ──────────────────────────────────────────
# Return: path ke file tmp, atau kosong jika tidak ada/gagal
download_media() {
  local msg_json="$1"

  # Cek apakah ada photo atau document (image)
  local file_id mime_type
  file_id=$(echo "$msg_json" | jq -r '
    if .photo then
      .photo | last | .file_id
    elif (.document.mime_type // "") | startswith("image/") then
      .document.file_id
    else
      empty
    end' 2>/dev/null)

  [[ -z "$file_id" ]] && return 0

  mime_type=$(echo "$msg_json" | jq -r '
    if .photo then "image/jpeg"
    else .document.mime_type // "image/jpeg"
    end' 2>/dev/null)

  log "   📸 Ada gambar (file_id: ${file_id:0:20}...), download via Bot API..."

  # Ambil file path dari Telegram
  local file_resp file_path
  file_resp=$(curl -s "$API_URL/getFile?file_id=$file_id")
  file_path=$(echo "$file_resp" | jq -r '.result.file_path // empty')

  [[ -z "$file_path" ]] && { log "   ❌ Gagal ambil file_path dari Telegram"; return 0; }

  # Download file ke tmp
  local tmp_file
  tmp_file=$(mktemp "${TMP_DIR}/soy_img_XXXXXX")
  local dl_url="https://api.telegram.org/file/bot${BOT_TOKEN}/${file_path}"

  curl -s -o "$tmp_file" "$dl_url"
  if [[ $? -ne 0 ]] || [[ ! -s "$tmp_file" ]]; then
    log "   ❌ Gagal download file gambar"
    rm -f "$tmp_file"
    return 0
  fi

  local file_size
  file_size=$(wc -c < "$tmp_file")
  log "   ✓ Gambar downloaded (${file_size} bytes)"

  # Return path:mime_type
  echo "${tmp_file}:${mime_type}"
}

# ── [4] Groq Vision — analisa gambar ─────────────────────────────────────────
groq_analyze_image() {
  local img_path="$1"
  local mime_type="${2:-image/jpeg}"

  log "   🔍 Analisa gambar via Groq Vision..."

  local b64_data
  b64_data=$(base64 -w 0 "$img_path" 2>/dev/null || base64 "$img_path" 2>/dev/null)
  [[ -z "$b64_data" ]] && { log "   ❌ Gagal encode base64"; echo "unknown"; return; }

  local data_url="data:${mime_type};base64,${b64_data}"

  local system_prompt='Kamu adalah classifier gambar untuk tim sysadmin. Tentukan apakah gambar ini berkaitan dengan pekerjaan sysadmin/IT infrastructure. Scope sysadmin: error server, screenshot terminal/CLI, log error, dashboard monitoring, error website (5xx/4xx), konfigurasi jaringan, masalah database, error deployment, SSL, DNS. Jawab HANYA dalam format JSON tanpa markdown: {"is_sysadmin": true atau false, "reason": "alasan singkat"}'

  local payload
  payload=$(python3 - "$GROQ_VISION_MODEL" "$system_prompt" "$data_url" <<'PYEOF'
import json, sys
model  = sys.argv[1]
sysprompt = sys.argv[2]
dataurl   = sys.argv[3]
print(json.dumps({
  "model": model,
  "messages": [
    {"role": "system", "content": sysprompt},
    {"role": "user", "content": [
      {"type": "image_url", "image_url": {"url": dataurl}},
      {"type": "text", "text": "Apakah gambar ini berkaitan dengan pekerjaan sysadmin/IT infrastructure?"}
    ]}
  ],
  "max_tokens": 128,
  "temperature": 0.1
}))
PYEOF
)

  local resp
  resp=$(curl -s -X POST "https://api.groq.com/openai/v1/chat/completions" \
    -H "Authorization: Bearer $GROQ_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload")

  python3 - "$resp" <<'PYEOF'
import json, sys
try:
    data    = json.loads(sys.argv[1])
    content = data["choices"][0]["message"]["content"].strip()
    content = content.replace("```json","").replace("```","").strip()
    result  = json.loads(content)
    print("true" if result.get("is_sysadmin", True) else "false")
    print(result.get("reason",""), file=sys.stderr)
except Exception as e:
    print("true")  # fallback in-scope
    print(f"parse error: {e}", file=sys.stderr)
PYEOF
}

# ── [5a] Keyword guardrail ────────────────────────────────────────────────────
# Return 0 = keyword match (in-scope), 1 = tidak match
keyword_check() {
  local text_lower
  text_lower=$(printf '%s' "$1" | tr 'A-Z' 'a-z')

  for kw in "${SYSADMIN_KEYWORDS[@]}"; do
    if [[ "$text_lower" == *"$kw"* ]]; then
      log "   🔑 Keyword match: '$kw'"
      return 0
    fi
  done
  return 1
}

# ── [5b] Groq LLM scope check ────────────────────────────────────────────────
# Return: "true" atau "false"
groq_scope_check() {
  local user_message="$1"

  local system_prompt='Kamu adalah classifier yang menentukan apakah pesan termasuk scope kerja IT Support / Sysadmin. Scope pekerjaan ini meliputi: server down, deployment error, database, jaringan, SSL/DNS, monitoring, akses server, konfigurasi bot, setup domain (domain rotator, SEO, protection), kendala Cloudflare (CF), integrasi provider game (pgsoft, pragmatic, dll), perbaikan link/banner, pengecekan statistik/upgrade aplikasi, dan segala laporan gangguan/error/lambat (berat) dari user. Jika pesan meminta "bantu cek", "tolong proses", atau melaporkan kendala teknis/sistem, anggap itu IN-SCOPE (true). Di luar scope HANYA: pertanyaan murni bisnis, keuangan (deposit/withdraw), HR, atau hal yang 100% tidak ada hubungannya dengan teknis/sistem. Jawab HANYA dalam format JSON tanpa markdown: {"is_sysadmin": true atau false, "confidence": "high/medium/low"}'

  local payload
  payload=$(python3 - "$GROQ_MODEL" "$system_prompt" "$user_message" <<'PYEOF'
import json, sys
print(json.dumps({
  "model": sys.argv[1],
  "messages": [
    {"role": "system", "content": sys.argv[2]},
    {"role": "user",   "content": f'Pesan: "{sys.argv[3]}"'}
  ],
  "max_tokens": 64,
  "temperature": 0.1
}))
PYEOF
)

  local resp
  resp=$(curl -s -X POST "https://api.groq.com/openai/v1/chat/completions" \
    -H "Authorization: Bearer $GROQ_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload")

  python3 - "$resp" <<'PYEOF'
import json, sys
try:
    data    = json.loads(sys.argv[1])
    content = data["choices"][0]["message"]["content"].strip()
    content = content.replace("```json","").replace("```","").strip()
    result  = json.loads(content)
    is_sys  = result.get("is_sysadmin", True)
    conf    = result.get("confidence","medium")
    print("true" if is_sys else "false")
    print(f"confidence: {conf}", file=sys.stderr)
except Exception as e:
    print("true")  # fallback in-scope
    print(f"parse error: {e}", file=sys.stderr)
PYEOF
}

# ── [6a] Groq LLM human reply generation ──────────────────────────────────────
# Return: teks reply contextual, atau kosong jika gagal
groq_generate_human_reply() {
  local user_message="$1"

  local system_prompt='Kamu adalah asisten sysadmin / IT support. Tugasmu adalah memberikan balasan singkat (acknowledgment) bahwa kamu sedang mengecek kendala yang dilaporkan oleh user.
Aturan penting:
1. Gunakan bahasa chat santai Indonesia (lowercase/huruf kecil semua, boleh pakai singkatan umum seperti dcek, dlu, lg, otw, bentar, ok/oke, siap).
2. Jika user memanggil "ko" atau "koko", gunakan sapaan "ko" di balasanmu. Contoh: "siap ko, otw cek", "oke ko, bentar dcek dlu".
3. JANGAN terlalu formal (hindari "Halo", "Baik, saya akan...", "Terima kasih").
4. Buat balasanmu singkat dan jika memungkinkan, buat kontekstual berdasarkan apa yang dilaporkan secara ringkas (contoh: "oke ko, bentar dcek ipos nya", "siap ko, otw ping servernya", "siap dcek dlu ssl nya ko").
5. Jawab HANYA teks balasannya saja, tanpa tanda kutip, tanpa penjelasan, dan tanpa markdown.'

  local payload
  payload=$(python3 - "$GROQ_MODEL" "$system_prompt" "$user_message" <<'PYEOF'
import json, sys
print(json.dumps({
  "model": sys.argv[1],
  "messages": [
    {"role": "system", "content": sys.argv[2]},
    {"role": "user",   "content": f'Pesan: "{sys.argv[3]}"'}
  ],
  "max_tokens": 48,
  "temperature": 0.8
}))
PYEOF
)

  local resp
  resp=$(curl -s -X POST "https://api.groq.com/openai/v1/chat/completions" \
    -H "Authorization: Bearer $GROQ_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload")

  python3 - "$resp" <<'PYEOF'
import json, sys
try:
    data    = json.loads(sys.argv[1])
    content = data["choices"][0]["message"]["content"].strip()
    if content.startswith('"') and content.endswith('"'):
        content = content[1:-1]
    if content.startswith("'") and content.endswith("'"):
        content = content[1:-1]
    print(content.strip())
except Exception as e:
    print("")
PYEOF
}

# ── [5] Determine scope — gabungan keyword + LLM + image ─────────────────────
# Return: "in" atau "out"
determine_scope() {
  local text="$1"
  local image_result="${2:-}"   # "true", "false", atau kosong

  # Kalau ada gambar dan gambar is_sysadmin → in-scope langsung
  if [[ "$image_result" == "true" ]]; then
    log "   ✅ Scope: IN (gambar sysadmin detected)"
    echo "in"; return
  fi

  # Strip mention dari text
  local clean_text
  clean_text=$(echo "$text" | sed 's/@[A-Za-z0-9_]*//g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  # Kalau text kosong total
  if [[ -z "$clean_text" ]]; then
    if [[ "$image_result" == "false" ]]; then
      log "   ❌ Scope: OUT (hanya gambar bukan sysadmin, no text)"
      echo "out"; return
    fi
    log "   ✅ Scope: IN (text kosong, default in-scope)"
    echo "in"; return
  fi

  # Step C: keyword guardrail
  if keyword_check "$clean_text"; then
    echo "in"; return
  fi

  # Text sangat pendek tanpa keyword → cek LLM juga buat konfirmasi
  local word_count
  word_count=$(echo "$clean_text" | wc -w)

  log "   🤖 Groq LLM scope check (${word_count} kata)..."
  local llm_result
  llm_result=$(groq_scope_check "$clean_text")

  if [[ "$llm_result" == "true" ]]; then
    log "   ✅ Scope: IN (LLM confirm)"
    echo "in"
  else
    log "   ❌ Scope: OUT (LLM confirm)"
    echo "out"
  fi
}

# ── [8] Kirim reply via Telethon service ──────────────────────────────────────
send_telethon() {
  local chat_id="$1" message="$2" reply_to_id="$3"
  local session="${TELETHON_SESSION:-}"

  local payload
  payload=$(python3 - "$chat_id" "$message" "$reply_to_id" "$session" <<'PYEOF'
import json, sys
d = {
  "chat_id":             int(sys.argv[1]),
  "message":             sys.argv[2],
  "reply_to_message_id": int(sys.argv[3]) if sys.argv[3] else None,
}
if sys.argv[4]:
    d["session"] = sys.argv[4]
print(json.dumps(d))
PYEOF
)

  local resp http_code
  resp=$(curl -s -w "\n%{http_code}" -X POST "$TELETHON_URL/reply" \
    -H "Content-Type: application/json" \
    ${API_TOKEN:+-H "X-API-Token: $API_TOKEN"} \
    -d "$payload")
  http_code=$(echo "$resp" | tail -n1)

  if [[ "$http_code" -eq 200 ]]; then
    log "   ✓ Telethon reply terkirim"
  else
    log "   ❌ Telethon gagal ($http_code): $(echo "$resp" | sed '$d')"
  fi
}

# ── Pushover ──────────────────────────────────────────────────────────────────
pushover_send() {
  local device="${1:-}"
  local payload
  payload=$(python3 - "$PUSHOVER_TOKEN" "$PUSHOVER_USER" "$device" <<'PYEOF'
import json, sys
d = {
  "token":    sys.argv[1],
  "user":     sys.argv[2],
  "title":    "Sysadmin Alert",
  "message":  "Ada client butuh bantuan! Segera cek.",
  "priority": 2,
  "sound":    "alert",
  "retry":    30,
  "expire":   600,
}
if sys.argv[3]:
    d["device"] = sys.argv[3]
print(json.dumps(d))
PYEOF
)

  local resp http_code receipt
  resp=$(curl -s -w "\n%{http_code}" -X POST "https://api.pushover.net/1/messages.json" \
    -H "Content-Type: application/json" \
    -d "$payload")
  http_code=$(echo "$resp" | tail -n1)

  if [[ "$http_code" -eq 200 ]]; then
    receipt=$(echo "$resp" | sed '$d' | \
      python3 -c "import json,sys; print(json.load(sys.stdin).get('receipt',''))" 2>/dev/null)
    echo "$receipt"
  else
    log "   ❌ Pushover gagal ($http_code): $(echo "$resp" | sed '$d')"
    echo ""
  fi
}

pushover_is_acked() {
  local receipt="$1"
  [[ -z "$receipt" ]] && return 1
  local resp ack
  resp=$(curl -s "https://api.pushover.net/1/receipts/${receipt}.json?token=${PUSHOVER_TOKEN}")
  ack=$(echo "$resp" | python3 -c \
    "import json,sys; print(json.load(sys.stdin).get('acknowledged',0))" 2>/dev/null)
  [[ "$ack" == "1" ]]
}

pushover_wait_ack() {
  local receipt="$1" timeout_s="$2" label="$3"
  local elapsed=0
  while [[ "$elapsed" -lt "$timeout_s" ]]; do
    sleep 5
    elapsed=$((elapsed + 5))
    if pushover_is_acked "$receipt"; then
      log "   ✅ Pushover acked by $label (${elapsed}s)"
      return 0
    fi
  done
  log "   ⚠️  $label tidak ack dalam ${timeout_s}s, escalate..."
  return 1
}

send_pushover() {
  local primary="${PUSHOVER_DEVICE_PRIMARY:-}"
  local backup="${PUSHOVER_DEVICE_BACKUP:-}"
  local higher="${PUSHOVER_DEVICE_HIGHER:-}"
  local highest="${PUSHOVER_DEVICE_HIGHEST:-}"

  local wait_primary="${PUSHOVER_WAIT_PRIMARY:-60}"
  local wait_backup="${PUSHOVER_WAIT_BACKUP:-60}"
  local wait_higher="${PUSHOVER_WAIT_HIGHER:-300}"
  local wait_highest="${PUSHOVER_WAIT_HIGHEST:-600}"

  local summary_parts=()

  for level_name in primary backup higher highest; do
    local device wait_val receipt
    case "$level_name" in
      primary) device="$primary"; wait_val="$wait_primary" ;;
      backup)  device="$backup";  wait_val="$wait_backup"  ;;
      higher)  device="$higher";  wait_val="$wait_higher"  ;;
      highest) device="$highest"; wait_val="$wait_highest" ;;
    esac

    [[ -z "$device" ]] && continue

    log "   📲 Pushover → $level_name: $device (timeout: ${wait_val}s)"
    receipt=$(pushover_send "$device")

    if pushover_wait_ack "$receipt" "$wait_val" "$device"; then
      summary_parts+=("$level_name ($device): ✓ acknowledged")
      printf '%s' "$(IFS='|'; echo "${summary_parts[*]}")"
      return 0
    else
      summary_parts+=("$level_name ($device): ✗ no response")
    fi
  done

  log "   ☠️  Semua level Pushover tidak ack — expired"
  printf '%s' "$(IFS='|'; echo "${summary_parts[*]}")"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN FLOW
# ─────────────────────────────────────────────────────────────────────────────
handle_trigger() {
  local chat_id="$1"
  local chat_title="$2"
  local from_user="$3"
  local message_text="$4"
  local message_id="$5"
  local tagged_user="$6"
  local msg_json="$7"

  local safe_text safe_title safe_user
  safe_text=$(html_escape "$message_text")
  safe_title=$(html_escape "$chat_title")
  safe_user=$(html_escape "$from_user")

  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "🔔 TRIGGER @$from_user → @$tagged_user di [$chat_title]"
  log "   💬 ${message_text:0:80}"

  # [1] Whitelist check
  if is_skip_user "$from_user"; then
    log "   ⏭️  SKIP: @$from_user ada di SKIP_USERS, abaikan"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    return 0
  fi

  # [1.5] Cooldown check (3 menit) per chat
  local now
  now=$(date +%s)
  local cooldown_file="${TMP_DIR}/soy_cooldown_${chat_id}"
  if [[ -f "$cooldown_file" ]]; then
    local last_time
    last_time=$(cat "$cooldown_file" 2>/dev/null || echo 0)
    local diff=$((now - last_time))
    if [[ "$diff" -lt 180 ]]; then
      log "   ⏭️  SKIP: Cooldown 3 menit masih aktif (sudah reply ${diff}s yang lalu)"
      log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      return 0
    fi
  fi
  echo "$now" > "$cooldown_file"

  # [2] Forward ke group internal sysadmin
  log "   ⏳ Forward ke group internal..."
  local notif_msg
  notif_msg="🚨 <b>CLIENT BUTUH BANTUAN</b>"$'\n'
  notif_msg+="📌 <b>Group:</b> $safe_title"$'\n'
  notif_msg+="👤 <b>From:</b> @$safe_user"$'\n'
  notif_msg+="💬 <b>Message:</b>"$'\n'
  notif_msg+="<pre>$safe_text</pre>"
  send_telegram "$INTERNAL_CHAT_ID" "$notif_msg" || true
  log "   ✓ Forward ke internal terkirim"

  # [3] Download media (jika ada)
  local img_tmp="" img_mime="image/jpeg" image_result=""
  local media_info
  media_info=$(download_media "$msg_json")

  if [[ -n "$media_info" ]]; then
    img_tmp="${media_info%%:*}"
    img_mime="${media_info##*:}"
  fi

  # [4] Analisa gambar via Groq Vision (jika ada)
  if [[ -n "$img_tmp" ]] && [[ -f "$img_tmp" ]]; then
    image_result=$(groq_analyze_image "$img_tmp" "$img_mime")
    log "   🖼️  Image analysis result: $image_result"
    rm -f "$img_tmp"
  fi

  # Strip mention dari text untuk LLM & delay
  local clean_text
  clean_text=$(echo "$message_text" | sed 's/@[A-Za-z0-9_]*//g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  # [5] Scope detection
  log "   🔎 Scope detection..."
  local scope
  scope=$(determine_scope "$message_text" "$image_result")

  # [6] Generate reply
  local reply_text scope_label
  if [[ "$scope" == "in" ]]; then
    scope_label="IN SCOPE"
    log "   🤖 Generating human-like contextual reply..."
    reply_text=$(groq_generate_human_reply "$clean_text")
    if [[ -z "$reply_text" ]]; then
      reply_text=$(random_reply)
      log "   ⚠️  Groq reply failed, fallback to pool: '$reply_text'"
    else
      log "   ✅ $scope_label (Groq reply) → reply: '$reply_text'"
    fi
  else
    reply_text="cc $DEV_TAG"
    scope_label="OUT OF SCOPE"
    log "   ❌ $scope_label → reply: '$reply_text'"
  fi

  # Update notif internal dengan info scope
  local scope_update
  scope_update="📊 <b>Scope:</b> $scope_label"$'\n'
  scope_update+="💡 <b>Reply:</b> <code>$reply_text</code>"
  send_telegram "$INTERNAL_CHAT_ID" "$scope_update" || true

  # [7] Human-like delay (Reading + Image viewing + Thinking/Waking up time)
  local has_img_flag="false"
  if [[ -n "$media_info" ]]; then
    has_img_flag="true"
  fi
  local is_sleep="false"
  if is_sleep_hours "$(get_current_minutes)"; then
    is_sleep="true"
  fi

  log "   ⏳ Human delay (reading & thinking delay)..."
  local actual_delay
  actual_delay=$(random_delay "$clean_text" "$reply_text" "$has_img_flag" "$is_sleep")
  log "   ✓ Delay selesai (${actual_delay}s)"

  # [8] Kirim reply via Telethon
  log "   📤 Kirim reply via Telethon..."
  send_telethon "$chat_id" "$reply_text" "$message_id"

  # [9] Sleep hour check
  local current_minutes time_string pushover_summary="working hours / pushover tidak aktif"
  current_minutes=$(get_current_minutes)
  time_string=$(get_time_string)
  log "   🕐 Waktu Jakarta: $time_string (sleep: ${SLEEP_HOUR_START}–${SLEEP_HOUR_END})"

  if is_sleep_hours "$current_minutes"; then
    log "   🌙 SLEEP HOURS — trigger Pushover escalation"
    pushover_summary=$(send_pushover)
    log "   📋 Pushover summary: $pushover_summary"
  else
    log "   ☀️  Working hours — notif internal sudah terkirim"
  fi

  # [10] Incident log → CSV
  local file_date
  file_date=$(incident_date)
  local csv_row
  csv_row=$(incident_log "$chat_title" "$chat_id" "$message_text" \
                         "$scope_label" "$pushover_summary")
  echo "$csv_row" >> "$LOG_DIR/incidents_${file_date}.csv"
  log "   ✓ Incident → incidents/incidents_${file_date}.csv"

  log "✅ Flow selesai untuk @$from_user"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ─────────────────────────────────────────────────────────────────────────────
# TELEGRAM POLLING LOOP
# ─────────────────────────────────────────────────────────────────────────────
log "Menghapus Telegram webhook (jika ada)..."
curl -s "$API_URL/deleteWebhook" > /dev/null

log "Bot        : @$BOT_USERNAME"
log "Monitor    : $TEAM_USERNAMES"
log "Skip users : ${SKIP_USERS:-none}"
log "Dev tag    : $DEV_TAG"
log "Sleep hours: ${SLEEP_HOUR_START} – ${SLEEP_HOUR_END}"

# Buang update lama
log "Membuang update lama..."
INIT_RESP=$(curl -s "$API_URL/getUpdates" -d timeout=0 -d offset="-1")
if echo "$INIT_RESP" | jq empty 2>/dev/null; then
  LAST_ID=$(echo "$INIT_RESP" | jq -r '.result[-1].update_id // empty')
  if [[ -n "$LAST_ID" ]]; then
    OFFSET=$((LAST_ID + 1))
    log "Skip update lama s/d update_id=$LAST_ID, mulai dari $OFFSET"
  fi
fi

log "Mulai polling..."

while true; do
  RESPONSE=$(curl -s "$API_URL/getUpdates" -d timeout=25 -d offset="$OFFSET")

  if ! echo "$RESPONSE" | jq empty 2>/dev/null; then
    log "ERROR: Response bukan JSON valid, retry dalam 5s..."
    sleep 5
    continue
  fi

  updates_count=$(echo "$RESPONSE" | jq '.result | length')
  [[ "$updates_count" -eq 0 ]] && continue

  for ((i=0; i<updates_count; i++)); do
    update=$(echo "$RESPONSE" | jq ".result[$i]")
    update_id=$(echo "$update" | jq '.update_id')
    OFFSET=$((update_id + 1))

    [[ $(echo "$update" | jq 'has("message")') != "true" ]] && continue

    msg=$(echo        "$update" | jq '.message')
    chat_id=$(echo    "$msg" | jq -r '.chat.id // ""')
    chat_title=$(echo "$msg" | jq -r '.chat.title // "Private Chat"')
    from_user=$(echo  "$msg" | jq -r '.from.username // .from.first_name // "unknown"')
    message_id=$(echo "$msg" | jq -r '.message_id // ""')

    # Ambil text dari pesan biasa ATAU caption (jika ada gambar)
    text=$(echo "$msg" | jq -r '.text // .caption // ""')

    # Ignore pesan dari bot sendiri
    bot_lower=$(printf '%s' "$BOT_USERNAME" | tr 'A-Z' 'a-z')
    from_lower=$(printf '%s' "$from_user"   | tr 'A-Z' 'a-z')
    [[ "$from_lower" == "$bot_lower" ]] && continue

    # Ignore pesan dari group internal
    [[ "$chat_id" == "$SYSADMIN_CHAT_ID"  ]] && continue
    [[ "$chat_id" == "$INTERNAL_CHAT_ID"  ]] && continue

    # Cek apakah ada trigger @tag
    # Pesan dengan gambar tapi tanpa teks juga perlu dicek (caption bisa kosong)
    lower_text=$(printf '%s' "$text" | tr 'A-Z' 'a-z')
    has_media=$(echo "$msg" | jq -r 'if .photo or (.document.mime_type // "" | startswith("image/")) then "yes" else "no" end')

    trigger=0
    tagged_user=""
    for member in $TEAM_USERNAMES; do
      member_lower=$(printf '%s' "$member" | tr 'A-Z' 'a-z')
      if [[ "$lower_text" == *"@$member_lower"* ]]; then
        tagged_user="$member"
        trigger=1
        break
      fi
    done

    # Jika tidak ada trigger tag dan tidak ada media → skip
    [[ "$trigger" -eq 0 ]] && continue

    handle_trigger \
      "$chat_id"    \
      "$chat_title" \
      "$from_user"  \
      "$text"       \
      "$message_id" \
      "$tagged_user" \
      "$msg"

  done
done