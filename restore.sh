#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  OmniRoute — restore .env + data/ from a backup .zip created by backup.sh
#
#  Usage:
#    ./restore.sh --list                     # list available backups in BACKUP_DIR
#    ./restore.sh --latest                   # restore the newest backup
#    ./restore.sh backups/omniroute-backup-YYYYmmdd-HHMMSS.zip
#
#  Options:
#    --keep-env   keep the current .env instead of the one in the backup
#                 (only allowed when the data-bound secrets match)
#    -y, --yes    do not ask for confirmation
#
#  Safety:
#    - The zip and its DB snapshot are verified BEFORE anything is touched
#    - Nothing is deleted: the current data dir and .env are renamed to
#      *.pre-restore-<timestamp> so the restore can be undone
#    - Data is always restored into a fresh, empty data dir (no stale -wal/-shm)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

cd "$(dirname "$0")"
PROJECT_DIR=$(pwd)
ENV_FILE=.env
SERVICE=omniroute
CONTAINER_UID=1000
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-240}   # seconds
# Secrets that must match the restored DB (see README → Backup & restore)
DATA_BOUND_SECRETS=(API_KEY_SECRET STORAGE_ENCRYPTION_KEY)

info() { printf '\033[1;34m[restore]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[  ok   ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[ warn  ]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[ error ]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

get_env() { grep -E "^$1=" "${2:-$ENV_FILE}" 2>/dev/null | tail -n1 | cut -d= -f2- || true; }
abs_path() { case "$1" in /*) echo "$1" ;; *) echo "$PROJECT_DIR/${1#./}" ;; esac; }
container_id() { docker compose ps -q "$SERVICE" 2>/dev/null | head -n1; }
rel() { echo "${1#"$PROJECT_DIR"/}"; }   # shorter paths in messages

# ── Arguments ────────────────────────────────────────────────────────────────
ZIP=""; LIST=false; LATEST=false; KEEP_ENV=false; ASSUME_YES=false
while [ $# -gt 0 ]; do
  case "$1" in
    --list)      LIST=true ;;
    --latest)    LATEST=true ;;
    --keep-env)  KEEP_ENV=true ;;
    -y|--yes)    ASSUME_YES=true ;;
    -h|--help)   usage 0 ;;
    -*)          warn "Invalid argument: $1"; usage 1 ;;
    *)           [ -z "$ZIP" ] || die "Only one backup file may be given."; ZIP=$1 ;;
  esac
  shift
done

for cmd in unzip python3; do
  command -v "$cmd" >/dev/null || die "'$cmd' is required (e.g. sudo apt install $cmd)."
done
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 (docker compose) is required."

BACKUP_DIR=$(get_env BACKUP_DIR); BACKUP_DIR=$(abs_path "${BACKUP_DIR:-./backups}")

list_backups() { ls -1t "$BACKUP_DIR"/omniroute-backup-*.zip 2>/dev/null || true; }

if $LIST || { [ -z "$ZIP" ] && ! $LATEST; }; then
  info "Backups in $BACKUP_DIR (newest first):"
  found=false
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    found=true
    printf '    %-45s %6s   %s\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)" "$(date -r "$f" '+%F %T')"
  done < <(list_backups)
  $found || echo "    (none)"
  $LIST || { echo; info "Restore with: ./restore.sh <file.zip>  or  ./restore.sh --latest"; }
  exit 0
fi

if $LATEST; then
  [ -z "$ZIP" ] || die "Use either --latest or a file, not both."
  ZIP=$(list_backups | head -n1)
  [ -n "$ZIP" ] || die "No backups found in $BACKUP_DIR."
fi
[ -f "$ZIP" ] || die "Backup file not found: $ZIP"
ZIP=$(abs_path "$ZIP")

# ── 1. Verify the backup before touching anything ────────────────────────────
info "Verifying $(basename "$ZIP") …"
unzip -tq "$ZIP" >/dev/null || die "Zip file is corrupted."
ENTRIES=$(unzip -Z1 "$ZIP")
grep -qx 'data/storage.sqlite' <<<"$ENTRIES" || die "Not an OmniRoute backup: data/storage.sqlite is missing."
grep -qx '.env' <<<"$ENTRIES" || { $KEEP_ENV || die ".env is missing from the backup — use --keep-env to restore with the current .env."; }
grep -qx 'data/server.env' <<<"$ENTRIES" || warn "data/server.env is missing from the backup — encrypted data may be unreadable."

# Stage next to the project (same filesystem → the final move is a rename)
STAGE=$(mktemp -d "$PROJECT_DIR/.restore.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
# Only .env and data/ are restored (logs/ and docker-compose.yml are skipped;
# the compose file is tracked in git)
INCLUDE=('data/*')
grep -qx '.env' <<<"$ENTRIES" && INCLUDE+=('.env')
unzip -q "$ZIP" "${INCLUDE[@]}" -d "$STAGE" || die "Extraction failed. Nothing was changed."
rm -f "$STAGE/data/storage.sqlite-wal" "$STAGE/data/storage.sqlite-shm"

python3 - "$STAGE/data/storage.sqlite" <<'PY'
import sqlite3, sys
con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
res = con.execute("PRAGMA quick_check").fetchone()[0]
con.close()
if res != "ok":
    sys.exit(f"quick_check failed: {res}")
PY
ok "Zip and DB snapshot verified (quick_check: ok)."

# Which .env will be active after the restore
if $KEEP_ENV; then
  [ -f "$ENV_FILE" ] || die "--keep-env given but $ENV_FILE does not exist."
  TARGET_ENV=$ENV_FILE
  if [ -f "$STAGE/.env" ]; then
    for key in "${DATA_BOUND_SECRETS[@]}"; do
      [ "$(get_env "$key" "$STAGE/.env")" = "$(get_env "$key" "$ENV_FILE")" ] \
        || die "$key differs between the backup and the current .env — the restored DB needs the backup's value. Run without --keep-env."
    done
  fi
else
  TARGET_ENV=$STAGE/.env
fi
DATA_PATH=$(get_env DATA_PATH "$TARGET_ENV"); DATA_PATH=$(abs_path "${DATA_PATH:-./data}")
DATA_PATH=${DATA_PATH%/}

# ── 2. Confirm ───────────────────────────────────────────────────────────────
TS=$(date +%Y%m%d-%H%M%S)
echo
if unzip -p "$ZIP" BACKUP_INFO.txt >/dev/null 2>&1; then
  unzip -p "$ZIP" BACKUP_INFO.txt | sed -n '1,6p' | sed 's/^/    /'
  echo
fi
info "This will:"
echo "    - stop the '$SERVICE' container"
[ -e "$DATA_PATH" ] && echo "    - move $(rel "$DATA_PATH") → $(rel "$DATA_PATH").pre-restore-$TS"
echo "    - restore data/ from the backup into $(rel "$DATA_PATH")"
if $KEEP_ENV; then
  echo "    - keep the current $ENV_FILE"
else
  [ -f "$ENV_FILE" ] && echo "    - move $ENV_FILE → $ENV_FILE.pre-restore-$TS"
  echo "    - restore $ENV_FILE from the backup"
fi
echo "    - start the stack and wait for it to become healthy"
echo
if ! $ASSUME_YES; then
  [ -t 0 ] || die "Not running interactively — pass --yes to confirm."
  read -r -p "Continue? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || die "Aborted. Nothing was changed."
fi

# ── 3. Stop, swap data and .env ──────────────────────────────────────────────
if [ -n "$(container_id)" ]; then
  info "Stopping $SERVICE …"
  docker compose stop "$SERVICE" >/dev/null 2>&1 || die "Could not stop $SERVICE. Nothing was changed."
fi

MOVED_DATA=""; MOVED_ENV=""
if [ -e "$DATA_PATH" ]; then
  MOVED_DATA="$DATA_PATH.pre-restore-$TS"
  mv "$DATA_PATH" "$MOVED_DATA"
fi
mkdir -p "$(dirname "$DATA_PATH")"
mv "$STAGE/data" "$DATA_PATH"
ok "Restored data → $(rel "$DATA_PATH")"

if ! $KEEP_ENV; then
  if [ -f "$ENV_FILE" ]; then
    MOVED_ENV="$ENV_FILE.pre-restore-$TS"
    mv "$ENV_FILE" "$MOVED_ENV"
  fi
  cp "$STAGE/.env" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok "Restored $ENV_FILE"
fi

owner=$(stat -c %u "$DATA_PATH")
[ "$owner" = "$CONTAINER_UID" ] || warn "$DATA_PATH is owned by uid $owner, the container runs as uid $CONTAINER_UID. Fix: sudo chown -R $CONTAINER_UID:$CONTAINER_UID $DATA_PATH"

# ── 4. Start and wait for healthy ────────────────────────────────────────────
info "Starting the stack …"
docker compose up -d >/dev/null 2>&1 || docker compose up -d || true
info "Waiting for the container to become healthy (up to ${HEALTH_TIMEOUT}s) …"
status=starting
for ((i = 0; i < HEALTH_TIMEOUT; i += 3)); do
  status=$(docker inspect "$(container_id)" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || echo missing)
  case "$status" in healthy|unhealthy|exited|dead|missing) break ;; esac
  sleep 3
done

undo_steps() {
  echo "  cd $PROJECT_DIR"
  echo "  docker compose stop $SERVICE"
  echo "  mv $(rel "$DATA_PATH") $(rel "$DATA_PATH").discarded-$TS"
  [ -z "$MOVED_DATA" ] || echo "  mv $(rel "$MOVED_DATA") $(rel "$DATA_PATH")"
  [ -z "$MOVED_ENV" ]  || echo "  mv $MOVED_ENV $ENV_FILE"
  echo "  docker compose up -d"
}

if [ "$status" != "healthy" ]; then
  warn "Container is not healthy (status: $status). Last 50 log lines:"
  docker compose logs --tail 50 "$SERVICE" || true
  echo >&2
  warn "To undo the restore:"
  undo_steps >&2
  exit 1
fi

ok "Restore complete — OmniRoute is running (healthy)."
if [ -n "$MOVED_DATA" ] || [ -n "$MOVED_ENV" ]; then
  info "Previous state kept (delete once you have verified the restore):"
  [ -z "$MOVED_DATA" ] || echo "    $(rel "$MOVED_DATA")"
  [ -z "$MOVED_ENV" ]  || echo "    $MOVED_ENV"
  info "To undo:"
  undo_steps
fi
