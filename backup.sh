#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  OmniRoute — backup .env + data/ thành file .zip
#
#  - DB SQLite được snapshot bằng online backup API → nhất quán, KHÔNG cần dừng
#    container (không copy thẳng storage.sqlite/-wal đang được ghi)
#  - Kiểm tra toàn vẹn snapshot (PRAGMA quick_check) và file zip (unzip -t)
#  - Tự xoá bớt backup cũ, giữ BACKUP_KEEP bản mới nhất
#
#  Dùng:
#    ./backup.sh                  # backup .env, docker-compose.yml, data/
#    ./backup.sh --with-logs      # kèm thư mục logs/
#    ./backup.sh -o /mnt/nas/omniroute -k 30
#
#  Cấu hình (đọc từ .env, tham số dòng lệnh được ưu tiên):
#    BACKUP_DIR   thư mục chứa file zip      (mặc định ./backups)
#    BACKUP_KEEP  số bản giữ lại, 0 = giữ hết (mặc định 7)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

cd "$(dirname "$0")"
PROJECT_DIR=$(pwd)
ENV_FILE=.env

info() { printf '\033[1;34m[backup]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[  ok  ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[ warn ]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error ]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

get_env() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true; }
abs_path() { case "$1" in /*) echo "$1" ;; *) echo "$PROJECT_DIR/${1#./}" ;; esac; }

# ── Tham số ──────────────────────────────────────────────────────────────────
[ -f "$ENV_FILE" ] || die "Không tìm thấy $ENV_FILE — chưa cài đặt? (chạy ./setup.sh)"

WITH_LOGS=false
BACKUP_DIR=$(get_env BACKUP_DIR); BACKUP_DIR=${BACKUP_DIR:-./backups}
BACKUP_KEEP=$(get_env BACKUP_KEEP); BACKUP_KEEP=${BACKUP_KEEP:-7}

while [ $# -gt 0 ]; do
  case "$1" in
    --with-logs) WITH_LOGS=true ;;
    -o|--output) BACKUP_DIR=${2:?thiếu đường dẫn sau $1}; shift ;;
    -k|--keep)   BACKUP_KEEP=${2:?thiếu số lượng sau $1}; shift ;;
    -h|--help)   usage 0 ;;
    *) warn "Tham số không hợp lệ: $1"; usage 1 ;;
  esac
  shift
done
[[ "$BACKUP_KEEP" =~ ^[0-9]+$ ]] || die "BACKUP_KEEP phải là số nguyên ≥ 0 (đang là '$BACKUP_KEEP')."

for cmd in zip unzip python3; do
  command -v "$cmd" >/dev/null || die "Cần cài '$cmd' (vd: sudo apt install $cmd)."
done

DATA_PATH=$(abs_path "$(get_env DATA_PATH || true)"); [ "$DATA_PATH" != "$PROJECT_DIR/" ] || DATA_PATH=$PROJECT_DIR/data
LOG_PATH=$(abs_path "$(get_env LOG_PATH || true)");   [ "$LOG_PATH" != "$PROJECT_DIR/" ]  || LOG_PATH=$PROJECT_DIR/logs
BACKUP_DIR=$(abs_path "$BACKUP_DIR")
DB_FILE=$DATA_PATH/storage.sqlite

[ -d "$DATA_PATH" ] || die "Không tìm thấy thư mục data: $DATA_PATH"
[ -f "$DB_FILE" ]   || die "Không tìm thấy DB: $DB_FILE"
[ -f "$DATA_PATH/server.env" ] || warn "Thiếu $DATA_PATH/server.env (chứa key mã hoá DB) — backup sẽ không khôi phục được dữ liệu mã hoá!"

# ── Chuẩn bị ─────────────────────────────────────────────────────────────────
umask 077   # file zip chứa secret → chỉ owner đọc được
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

TS=$(date +%Y%m%d-%H%M%S)
NAME="omniroute-backup-$TS"
OUT="$BACKUP_DIR/$NAME.zip"
TMP_OUT="$OUT.partial"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/omniroute-backup.XXXXXX")
trap 'rm -rf "$STAGE"; rm -f "$TMP_OUT"' EXIT

info "Backup → $OUT"

# ── 1. Snapshot SQLite (online, nhất quán) ───────────────────────────────────
mkdir -p "$STAGE/snapshot/data"
python3 - "$DB_FILE" "$STAGE/snapshot/data/storage.sqlite" <<'PY'
import sqlite3, sys
src_path, dst_path = sys.argv[1], sys.argv[2]
src = sqlite3.connect(src_path, timeout=60)
dst = sqlite3.connect(dst_path)
src.backup(dst, pages=1024)          # online backup API: an toàn khi app đang ghi
src.close()
dst.execute("PRAGMA journal_mode=DELETE")  # file đơn, không kèm -wal/-shm
res = dst.execute("PRAGMA quick_check").fetchone()[0]
dst.close()
if res != "ok":
    sys.exit(f"quick_check thất bại: {res}")
PY
ok "Snapshot DB ($(du -h "$STAGE/snapshot/data/storage.sqlite" | cut -f1)) — quick_check: ok"

# ── 2. Gom file vào zip ──────────────────────────────────────────────────────
# Dùng symlink để trong zip luôn có đường dẫn data/, logs/ bất kể DATA_PATH thật
mkdir -p "$STAGE/tree"
ln -s "$PROJECT_DIR/$ENV_FILE" "$STAGE/tree/.env"
ln -s "$PROJECT_DIR/docker-compose.yml" "$STAGE/tree/docker-compose.yml"
ln -s "$DATA_PATH" "$STAGE/tree/data"
ITEMS=(.env docker-compose.yml data)
if $WITH_LOGS && [ -d "$LOG_PATH" ]; then
  ln -s "$LOG_PATH" "$STAGE/tree/logs"
  ITEMS+=(logs)
fi

IMAGE=$(docker inspect omniroute --format '{{.Config.Image}} ({{.Image}})' 2>/dev/null || echo "không xác định (container không chạy)")
cat > "$STAGE/snapshot/BACKUP_INFO.txt" <<EOF
OmniRoute backup
Thời điểm : $(date '+%F %T %z')
Máy       : $(hostname)
Nguồn     : $PROJECT_DIR
Image     : $IMAGE
Gồm       : ${ITEMS[*]} (data/storage.sqlite là snapshot nhất quán; bỏ qua data/db_backups/)

KHÔI PHỤC (trong thư mục dự án):
  docker compose down
  mv data data.old            # giữ lại bản hiện tại phòng khi cần
  unzip -o $NAME.zip -x BACKUP_INFO.txt
  docker compose up -d
EOF

(
  cd "$STAGE/tree"
  # Bỏ DB đang chạy (đã có snapshot), backup nội bộ của OmniRoute và cache tạm
  zip -q -r "$TMP_OUT" "${ITEMS[@]}" \
    -x 'data/storage.sqlite' 'data/storage.sqlite-*' 'data/db_backups/*'
)
( cd "$STAGE/snapshot" && zip -q -r "$TMP_OUT" data/storage.sqlite BACKUP_INFO.txt )

unzip -tq "$TMP_OUT" >/dev/null || die "File zip bị lỗi khi kiểm tra."
mv "$TMP_OUT" "$OUT"
ok "Đã tạo $(basename "$OUT") ($(du -h "$OUT" | cut -f1)), kiểm tra zip: ok"

# ── 3. Xoá backup cũ ─────────────────────────────────────────────────────────
if [ "$BACKUP_KEEP" -gt 0 ]; then
  mapfile -t old < <(ls -1t "$BACKUP_DIR"/omniroute-backup-*.zip 2>/dev/null | tail -n +"$((BACKUP_KEEP + 1))")
  for f in "${old[@]}"; do rm -f -- "$f"; done
  [ "${#old[@]}" -eq 0 ] || ok "Đã xoá ${#old[@]} backup cũ (giữ $BACKUP_KEEP bản mới nhất)."
fi

info "Hoàn tất. ⚠️  File chứa secret (.env) — lưu ở nơi an toàn, nên copy ra ngoài máy này."
