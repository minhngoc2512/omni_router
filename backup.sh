#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  OmniRoute — back up .env + data/ into a .zip file
#
#  - The SQLite DB is snapshotted via the online backup API → consistent, NO need
#    to stop the container (never copies a storage.sqlite/-wal that is being written)
#  - Verifies the snapshot (PRAGMA quick_check) and the zip file (unzip -t)
#  - Prunes old backups, keeping the newest BACKUP_KEEP files
#
#  Usage:
#    ./backup.sh                  # back up .env, docker-compose.yml, data/
#    ./backup.sh --with-logs      # also include logs/
#    ./backup.sh -o /mnt/nas/omniroute -k 30
#
#  Settings (read from .env; command-line options take precedence):
#    BACKUP_DIR   directory for the zip files     (default ./backups)
#    BACKUP_KEEP  number of backups to keep, 0 = keep all (default 7)
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

# ── Arguments ────────────────────────────────────────────────────────────────
[ -f "$ENV_FILE" ] || die "$ENV_FILE not found — not set up yet? (run ./setup.sh)"

WITH_LOGS=false
BACKUP_DIR=$(get_env BACKUP_DIR); BACKUP_DIR=${BACKUP_DIR:-./backups}
BACKUP_KEEP=$(get_env BACKUP_KEEP); BACKUP_KEEP=${BACKUP_KEEP:-7}

while [ $# -gt 0 ]; do
  case "$1" in
    --with-logs) WITH_LOGS=true ;;
    -o|--output) BACKUP_DIR=${2:?missing path after $1}; shift ;;
    -k|--keep)   BACKUP_KEEP=${2:?missing count after $1}; shift ;;
    -h|--help)   usage 0 ;;
    *) warn "Invalid argument: $1"; usage 1 ;;
  esac
  shift
done
[[ "$BACKUP_KEEP" =~ ^[0-9]+$ ]] || die "BACKUP_KEEP must be an integer ≥ 0 (got '$BACKUP_KEEP')."

for cmd in zip unzip python3; do
  command -v "$cmd" >/dev/null || die "'$cmd' is required (e.g. sudo apt install $cmd)."
done

DATA_PATH=$(abs_path "$(get_env DATA_PATH || true)"); [ "$DATA_PATH" != "$PROJECT_DIR/" ] || DATA_PATH=$PROJECT_DIR/data
LOG_PATH=$(abs_path "$(get_env LOG_PATH || true)");   [ "$LOG_PATH" != "$PROJECT_DIR/" ]  || LOG_PATH=$PROJECT_DIR/logs
BACKUP_DIR=$(abs_path "$BACKUP_DIR")
DB_FILE=$DATA_PATH/storage.sqlite

[ -d "$DATA_PATH" ] || die "Data directory not found: $DATA_PATH"
[ -f "$DB_FILE" ]   || die "DB not found: $DB_FILE"
[ -f "$DATA_PATH/server.env" ] || warn "$DATA_PATH/server.env is missing (holds the DB encryption key) — encrypted data will not be recoverable from this backup!"

# ── Preparation ──────────────────────────────────────────────────────────────
umask 077   # the zip contains secrets → owner-only access
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

TS=$(date +%Y%m%d-%H%M%S)
NAME="omniroute-backup-$TS"
OUT="$BACKUP_DIR/$NAME.zip"
TMP_OUT="$OUT.partial"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/omniroute-backup.XXXXXX")
trap 'rm -rf "$STAGE"; rm -f "$TMP_OUT"' EXIT

info "Backup → $OUT"

# ── 1. SQLite snapshot (online, consistent) ──────────────────────────────────
mkdir -p "$STAGE/snapshot/data"
python3 - "$DB_FILE" "$STAGE/snapshot/data/storage.sqlite" <<'PY'
import sqlite3, sys
src_path, dst_path = sys.argv[1], sys.argv[2]
src = sqlite3.connect(src_path, timeout=60)
dst = sqlite3.connect(dst_path)
src.backup(dst, pages=1024)          # online backup API: safe while the app is writing
src.close()
dst.execute("PRAGMA journal_mode=DELETE")  # single file, no -wal/-shm companions
res = dst.execute("PRAGMA quick_check").fetchone()[0]
dst.close()
if res != "ok":
    sys.exit(f"quick_check failed: {res}")
PY
ok "DB snapshot ($(du -h "$STAGE/snapshot/data/storage.sqlite" | cut -f1)) — quick_check: ok"

# ── 2. Build the zip ─────────────────────────────────────────────────────────
# Symlinks keep the archive paths as data/, logs/ regardless of the real DATA_PATH
mkdir -p "$STAGE/tree"
ln -s "$PROJECT_DIR/$ENV_FILE" "$STAGE/tree/.env"
ln -s "$PROJECT_DIR/docker-compose.yml" "$STAGE/tree/docker-compose.yml"
ln -s "$DATA_PATH" "$STAGE/tree/data"
ITEMS=(.env docker-compose.yml data)
if $WITH_LOGS && [ -d "$LOG_PATH" ]; then
  ln -s "$LOG_PATH" "$STAGE/tree/logs"
  ITEMS+=(logs)
fi

IMAGE=$(docker inspect omniroute --format '{{.Config.Image}} ({{.Image}})' 2>/dev/null || echo "unknown (container not running)")
cat > "$STAGE/snapshot/BACKUP_INFO.txt" <<EOF
OmniRoute backup
Created   : $(date '+%F %T %z')
Host      : $(hostname)
Source    : $PROJECT_DIR
Image     : $IMAGE
Contents  : ${ITEMS[*]} (data/storage.sqlite is a consistent snapshot; data/db_backups/ excluded)

RESTORE (inside the project directory):
  ./restore.sh $NAME.zip
or manually:
  docker compose down
  mv data data.old            # keep the current data just in case
  unzip -o $NAME.zip .env 'data/*'
  docker compose up -d
EOF

(
  cd "$STAGE/tree"
  # Skip the live DB (snapshot added below) and OmniRoute's own internal backups
  zip -q -r "$TMP_OUT" "${ITEMS[@]}" \
    -x 'data/storage.sqlite' 'data/storage.sqlite-*' 'data/db_backups/*'
)
( cd "$STAGE/snapshot" && zip -q -r "$TMP_OUT" data/storage.sqlite BACKUP_INFO.txt )

unzip -tq "$TMP_OUT" >/dev/null || die "Zip file failed verification."
mv "$TMP_OUT" "$OUT"
ok "Created $(basename "$OUT") ($(du -h "$OUT" | cut -f1)), zip check: ok"

# ── 3. Prune old backups ─────────────────────────────────────────────────────
if [ "$BACKUP_KEEP" -gt 0 ]; then
  mapfile -t old < <(ls -1t "$BACKUP_DIR"/omniroute-backup-*.zip 2>/dev/null | tail -n +"$((BACKUP_KEEP + 1))")
  for f in "${old[@]}"; do rm -f -- "$f"; done
  [ "${#old[@]}" -eq 0 ] || ok "Deleted ${#old[@]} old backup(s) (keeping the newest $BACKUP_KEEP)."
fi

info "Done. ⚠️  The file contains secrets (.env) — store it safely and copy it off this machine."
