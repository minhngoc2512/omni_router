#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  OmniRoute — update the image and restart Docker Compose
#
#  Usage:
#    ./update.sh --check        # only show the current version & newer versions on Docker Hub
#    ./update.sh                # pull the newest image for the tag in .env (default latest)
#    ./update.sh 3.8.50         # switch to a specific version (written to OMNIROUTE_IMAGE_TAG)
#    ./update.sh --no-backup    # skip the backup step
#    ./update.sh --force        # recreate the container even if the image did not change
#
#  Steps: backup (./backup.sh) → docker compose pull → up -d → wait for healthy.
#  .env is only modified (OMNIROUTE_IMAGE_TAG) when a tag is given and the pull succeeds.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

cd "$(dirname "$0")"
ENV_FILE=.env
IMAGE_REPO=diegosouzapw/omniroute
SERVICE=omniroute
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-240}   # seconds

info() { printf '\033[1;34m[update]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[  ok  ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[ warn ]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error ]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

get_env() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true; }

set_env() {
  local key=$1 value=$2
  if grep -qE "^${key}=" "$ENV_FILE"; then
    KEY="$key" VALUE="$value" awk '
      BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VALUE"] }
      index($0, k "=") == 1 { print k "=" v; next }
      { print }
    ' "$ENV_FILE" > "$ENV_FILE.tmp" && cat "$ENV_FILE.tmp" > "$ENV_FILE" && rm -f "$ENV_FILE.tmp"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

# OmniRoute version inside an image (reads package.json, no running container needed)
image_version() {
  docker run --rm --entrypoint node "$1" -p 'require("/app/package.json").version' 2>/dev/null || echo "?"
}

# The service's container (found via compose, independent of container_name)
container_id() { docker compose ps -q "$SERVICE" 2>/dev/null | head -n1; }
container_image_id() {
  local cid; cid=$(container_id)
  [ -z "$cid" ] || docker inspect "$cid" --format '{{.Image}}' 2>/dev/null || true
}

# ── Arguments ────────────────────────────────────────────────────────────────
CHECK_ONLY=false; DO_BACKUP=true; FORCE=false; NEW_TAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check)     CHECK_ONLY=true ;;
    --no-backup) DO_BACKUP=false ;;
    --force)     FORCE=true ;;
    -h|--help)   usage 0 ;;
    -*)          warn "Invalid argument: $1"; usage 1 ;;
    *)           [ -z "$NEW_TAG" ] || die "Only one tag may be given."; NEW_TAG=$1 ;;
  esac
  shift
done
[ -z "$NEW_TAG" ] || [[ "$NEW_TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]] || die "Invalid tag: $NEW_TAG"

[ -f "$ENV_FILE" ] || die "$ENV_FILE not found — run ./setup.sh first."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 (docker compose) is required."

CUR_TAG=$(get_env OMNIROUTE_IMAGE_TAG); CUR_TAG=${CUR_TAG:-latest}
TAG=${NEW_TAG:-$CUR_TAG}

CUR_ID=$(container_image_id)
CUR_VER="(not running)"
if [ -n "$CUR_ID" ]; then
  CUR_VER=$(docker exec "$(container_id)" node -p 'require("/app/package.json").version' 2>/dev/null || image_version "$CUR_ID")
fi

# ── --check: read-only, changes nothing ──────────────────────────────────────
if $CHECK_ONLY; then
  info "Running: $CUR_VER (tag in .env: $CUR_TAG)"
  info "Latest stable versions on Docker Hub:"
  curl -fsS "https://hub.docker.com/v2/repositories/$IMAGE_REPO/tags?page_size=100&ordering=last_updated" \
    | python3 -c '
import json, re, sys
tags = json.load(sys.stdin)["results"]
stable = [t for t in tags if re.fullmatch(r"\d+\.\d+\.\d+", t["name"])]
stable.sort(key=lambda t: tuple(map(int, t["name"].split("."))), reverse=True)
for t in stable[:5]:
    print("    %-10s %s" % (t["name"], t["last_updated"][:10]))
' || warn "Could not fetch the tag list from Docker Hub."
  exit 0
fi

# ── 1. Pull the image ────────────────────────────────────────────────────────
info "Pulling image $IMAGE_REPO:$TAG …"
OMNIROUTE_IMAGE_TAG=$TAG docker compose pull --quiet \
  || die "Pull failed (does tag '$TAG' exist?). Nothing was changed."
NEW_ID=$(docker image inspect "$IMAGE_REPO:$TAG" --format '{{.Id}}')
NEW_VER=$(image_version "$IMAGE_REPO:$TAG")

if [ "$NEW_ID" = "$CUR_ID" ] && ! $FORCE; then
  [ -z "$NEW_TAG" ] || [ "$NEW_TAG" = "$CUR_TAG" ] || set_env OMNIROUTE_IMAGE_TAG "$NEW_TAG"
  ok "Already on the newest image for tag '$TAG' ($CUR_VER) — nothing to update."
  info "Container not restarted. (Use --force to recreate it, e.g. to apply changes in .env.)"
  exit 0
fi
info "Version: $CUR_VER → $NEW_VER"

# ── 2. Back up before updating (a new version may migrate the DB) ────────────
BACKUP_FILE=""
if $DO_BACKUP && [ -n "$CUR_ID" ]; then
  info "Backing up before the update …"
  ./backup.sh || die "Backup failed — update aborted. (Use --no-backup to skip.)"
  BACKUP_DIR=$(get_env BACKUP_DIR); BACKUP_DIR=${BACKUP_DIR:-./backups}
  BACKUP_FILE=$(ls -1t "$BACKUP_DIR"/omniroute-backup-*.zip 2>/dev/null | head -n1 || true)
elif ! $DO_BACKUP; then
  warn "Skipping backup as requested (--no-backup)."
fi

# ── 3. Write the new tag to .env & restart ───────────────────────────────────
if [ -n "$NEW_TAG" ] && [ "$NEW_TAG" != "$CUR_TAG" ]; then
  set_env OMNIROUTE_IMAGE_TAG "$NEW_TAG"
  ok "OMNIROUTE_IMAGE_TAG: $CUR_TAG → $NEW_TAG (in $ENV_FILE)"
fi

info "Restarting with the new image …"
if $FORCE; then
  docker compose up -d --force-recreate "$SERVICE"
  docker compose up -d
else
  docker compose up -d
fi

# ── 4. Wait for healthy ──────────────────────────────────────────────────────
info "Waiting for the container to become healthy (up to ${HEALTH_TIMEOUT}s) …"
status=starting
for ((i = 0; i < HEALTH_TIMEOUT; i += 3)); do
  status=$(docker inspect "$(container_id)" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || echo missing)
  case "$status" in healthy|unhealthy|exited|dead|missing) break ;; esac
  sleep 3
done

if [ "$status" != "healthy" ]; then
  warn "Container is not healthy (status: $status). Last 50 log lines:"
  docker compose logs --tail 50 "$SERVICE" || true
  cat >&2 <<EOF

Roll back to the previous version ($CUR_VER):
  ./update.sh $CUR_VER --no-backup
If the new version already migrated the DB and the old version will not start, restore the backup:
  docker compose down && mv data data.failed
  unzip -o ${BACKUP_FILE:-backups/<backup-file>.zip} -x BACKUP_INFO.txt
  docker compose up -d
EOF
  exit 1
fi

ok "OmniRoute $NEW_VER is running (healthy)."
[ -z "$BACKUP_FILE" ] || info "Pre-update backup: $BACKUP_FILE"
info "Roll back if needed: ./update.sh $CUR_VER"
info "Free up space from old images: docker image prune"
