#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  OmniRoute — cài đặt lần đầu (bước 1-3 trong README)
#    1. Tạo .env từ .env.example
#    2. Sinh secret ngẫu nhiên cho các biến còn trống
#    3. Tạo thư mục data / logs / redis
#
#  An toàn khi chạy lại nhiều lần:
#    - Không bao giờ ghi đè giá trị đã có trong .env
#    - Không bao giờ xoá hay sửa dữ liệu trong data/, logs/, redis/
#    - Nếu đã có dữ liệu cũ mà thiếu .env/secret → dừng lại thay vì sinh key mới
#      (key mới sẽ làm hỏng API key đã mã hoá trong DB)
#
#  Dùng:  ./setup.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

cd "$(dirname "$0")"

ENV_FILE=.env
EXAMPLE_FILE=.env.example
CONTAINER_UID=1000   # image chạy bằng user `node` uid 1000

info()  { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[  ok ]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[ warn]\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

command -v openssl >/dev/null || die "Cần cài openssl để sinh secret."
[ -f "$EXAMPLE_FILE" ] || die "Không tìm thấy $EXAMPLE_FILE."

# Đọc giá trị một biến từ file .env (dòng không comment, lấy dòng cuối cùng)
get_env() {
  local key=$1 file=${2:-$ENV_FILE}
  grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 | cut -d= -f2- || true
}

# Ghi giá trị cho biến CHỈ KHI biến đang trống; thêm mới nếu chưa có dòng nào
set_env_if_empty() {
  local key=$1 value=$2
  if grep -qE "^${key}=" "$ENV_FILE"; then
    [ -z "$(get_env "$key")" ] || return 1
    KEY="$key" VALUE="$value" awk '
      BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VALUE"] }
      index($0, k "=") == 1 && !done { print k "=" v; done = 1; next }
      { print }
    ' "$ENV_FILE" > "$ENV_FILE.tmp" && cat "$ENV_FILE.tmp" > "$ENV_FILE" && rm -f "$ENV_FILE.tmp"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

# Đường dẫn dữ liệu: ưu tiên .env, sau đó .env.example, cuối cùng là mặc định
path_var() {
  local key=$1 default=$2 v
  v=$(get_env "$key" "$ENV_FILE")
  [ -n "$v" ] || v=$(get_env "$key" "$EXAMPLE_FILE")
  echo "${v:-$default}"
}

DATA_PATH=$(path_var DATA_PATH ./data)
DB_FILE="$DATA_PATH/storage.sqlite"
has_existing_data() { [ -f "$DB_FILE" ]; }

# ── Bước 1: .env ─────────────────────────────────────────────────────────────
if [ -f "$ENV_FILE" ]; then
  ok "Đã có $ENV_FILE — giữ nguyên, chỉ bổ sung giá trị còn trống."
else
  if has_existing_data; then
    die "Có dữ liệu cũ ($DB_FILE) nhưng thiếu $ENV_FILE.
        Hãy khôi phục $ENV_FILE từ bản backup. Sinh secret mới sẽ làm hỏng dữ liệu đã mã hoá."
  fi
  cp "$EXAMPLE_FILE" "$ENV_FILE"
  ok "Đã tạo $ENV_FILE từ $EXAMPLE_FILE."
fi
chmod 600 "$ENV_FILE"

# ── Bước 2: secret ───────────────────────────────────────────────────────────
rand_b64() { openssl rand -base64 "$1" | tr -d '\n'; }
rand_hex() { openssl rand -hex "$1"; }
rand_pw()  { openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-24; }

# Các secret gắn với dữ liệu đã lưu: không được sinh mới khi DB đã tồn tại
DATA_BOUND_SECRETS=(API_KEY_SECRET)
# INITIAL_PASSWORD chỉ có tác dụng ở lần khởi động đầu tiên (DB trống)
FIRST_BOOT_ONLY=(INITIAL_PASSWORD)

declare -A GENERATORS=(
  [JWT_SECRET]="rand_b64 48"
  [API_KEY_SECRET]="rand_hex 32"
  [OMNIROUTE_WS_BRIDGE_SECRET]="rand_b64 32"
  [MACHINE_ID_SALT]="rand_hex 16"
  [INITIAL_PASSWORD]="rand_pw"
)
ORDER=(INITIAL_PASSWORD JWT_SECRET API_KEY_SECRET OMNIROUTE_WS_BRIDGE_SECRET MACHINE_ID_SALT)

new_password=""
for key in "${ORDER[@]}"; do
  if [ -n "$(get_env "$key")" ]; then
    ok "$key đã có giá trị — bỏ qua."
    continue
  fi
  if has_existing_data; then
    if [[ " ${DATA_BOUND_SECRETS[*]} " == *" $key "* ]]; then
      die "$key đang trống nhưng đã có dữ liệu ($DB_FILE).
        Khôi phục giá trị cũ từ backup .env — không tự sinh để tránh hỏng dữ liệu."
    fi
    if [[ " ${FIRST_BOOT_ONLY[*]} " == *" $key "* ]]; then
      warn "$key trống nhưng DB đã khởi tạo — bỏ qua (chỉ dùng ở lần chạy đầu)."
      continue
    fi
  fi
  value=$(${GENERATORS[$key]})
  set_env_if_empty "$key" "$value"
  ok "Đã sinh $key."
  [ "$key" = INITIAL_PASSWORD ] && new_password=$value
done

# ── Bước 3: thư mục ──────────────────────────────────────────────────────────
for key_default in "DATA_PATH ./data" "LOG_PATH ./logs" "REDIS_DATA_PATH ./redis"; do
  set -- $key_default
  dir=$(path_var "$1" "$2")
  if [ -d "$dir" ]; then
    ok "Thư mục $dir đã tồn tại — giữ nguyên dữ liệu."
  else
    mkdir -p "$dir"
    ok "Đã tạo thư mục $dir."
  fi
  owner=$(stat -c %u "$dir")
  if [ "$owner" != "$CONTAINER_UID" ]; then
    warn "$dir thuộc uid $owner, container chạy uid $CONTAINER_UID → có thể lỗi quyền ghi."
    warn "  Sửa: sudo chown -R $CONTAINER_UID:$CONTAINER_UID $dir"
  fi
done

# ── Kiểm tra biến mới trong .env.example mà .env chưa có ─────────────────────
missing=$(comm -23 \
  <(grep -oE '^[A-Z_][A-Z0-9_]*=' "$EXAMPLE_FILE" | sort -u) \
  <(grep -oE '^[A-Z_][A-Z0-9_]*=' "$ENV_FILE" | sort -u) | tr -d '=' | tr '\n' ' ')
if [ -n "$missing" ]; then
  warn "Các biến có trong $EXAMPLE_FILE nhưng chưa có trong $ENV_FILE (dùng mặc định):"
  warn "  $missing"
fi

echo
info "Hoàn tất. Khởi động bằng:  docker compose up -d"
if [ -n "$new_password" ]; then
  info "Mật khẩu dashboard lần đầu (INITIAL_PASSWORD trong $ENV_FILE): $new_password"
fi
