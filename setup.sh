#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  OmniRoute — first-time setup (steps 1-3 in the README)
#    1. Create .env from .env.example
#    2. Generate random secrets for variables that are still empty,
#       and set PUID/PGID (container uid/gid) to the current user if empty
#    3. Create the data / logs / redis directories
#
#  Safe to re-run:
#    - Never overwrites values that already exist in .env
#    - Never deletes or modifies anything in data/, logs/, redis/
#    - If data already exists but .env/secrets are missing → stops instead of
#      generating new keys (a new key would break the encrypted API keys in the DB)
#
#  Usage:  ./setup.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

cd "$(dirname "$0")"

ENV_FILE=.env
EXAMPLE_FILE=.env.example

info()  { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[  ok ]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[ warn]\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

command -v openssl >/dev/null || die "openssl is required to generate secrets."
[ -f "$EXAMPLE_FILE" ] || die "$EXAMPLE_FILE not found."

# Read a variable's value from an env file (uncommented lines, last one wins)
get_env() {
  local key=$1 file=${2:-$ENV_FILE}
  grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 | cut -d= -f2- || true
}

# Set a variable ONLY IF it is currently empty; append it if there is no line for it
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

# Data paths: .env first, then .env.example, then the default
path_var() {
  local key=$1 default=$2 v
  v=$(get_env "$key" "$ENV_FILE")
  [ -n "$v" ] || v=$(get_env "$key" "$EXAMPLE_FILE")
  echo "${v:-$default}"
}

DATA_PATH=$(path_var DATA_PATH ./data)
DB_FILE="$DATA_PATH/storage.sqlite"
has_existing_data() { [ -f "$DB_FILE" ]; }

# ── Step 1: .env ─────────────────────────────────────────────────────────────
if [ -f "$ENV_FILE" ]; then
  ok "$ENV_FILE already exists — keeping it, only filling in empty values."
else
  if has_existing_data; then
    die "Existing data found ($DB_FILE) but $ENV_FILE is missing.
        Restore $ENV_FILE from a backup. Generating new secrets would break the encrypted data."
  fi
  cp "$EXAMPLE_FILE" "$ENV_FILE"
  ok "Created $ENV_FILE from $EXAMPLE_FILE."
fi
chmod 600 "$ENV_FILE"

# ── Step 2: secrets ──────────────────────────────────────────────────────────
rand_b64() { openssl rand -base64 "$1" | tr -d '\n'; }
rand_hex() { openssl rand -hex "$1"; }
rand_pw()  { openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-24; }

# Secrets tied to stored data: must never be regenerated once a DB exists
DATA_BOUND_SECRETS=(API_KEY_SECRET)
# INITIAL_PASSWORD only takes effect on the very first boot (empty DB)
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
    ok "$key already set — skipping."
    continue
  fi
  if has_existing_data; then
    if [[ " ${DATA_BOUND_SECRETS[*]} " == *" $key "* ]]; then
      die "$key is empty but data already exists ($DB_FILE).
        Restore the old value from a backed-up .env — not generating one, to avoid breaking data."
    fi
    if [[ " ${FIRST_BOOT_ONLY[*]} " == *" $key "* ]]; then
      warn "$key is empty but the DB is already initialized — skipping (only used on first boot)."
      continue
    fi
  fi
  value=$(${GENERATORS[$key]})
  set_env_if_empty "$key" "$value"
  ok "Generated $key."
  [ "$key" = INITIAL_PASSWORD ] && new_password=$value
done

# PUID/PGID: containers run as the user that owns data/, logs/, redis/
for pair in "PUID $(id -u)" "PGID $(id -g)"; do
  set -- $pair
  if [ -n "$(get_env "$1")" ]; then
    ok "$1 already set ($(get_env "$1")) — skipping."
  else
    set_env_if_empty "$1" "$2"
    ok "Set $1=$2 (current user)."
  fi
done
CONTAINER_UID=$(get_env PUID); CONTAINER_UID=${CONTAINER_UID:-1000}

# ── Step 3: directories ──────────────────────────────────────────────────────
for key_default in "DATA_PATH ./data" "LOG_PATH ./logs" "REDIS_DATA_PATH ./redis"; do
  set -- $key_default
  dir=$(path_var "$1" "$2")
  if [ -d "$dir" ]; then
    ok "Directory $dir already exists — data left untouched."
  else
    mkdir -p "$dir"
    ok "Created directory $dir."
  fi
  owner=$(stat -c %u "$dir")
  if [ "$owner" != "$CONTAINER_UID" ]; then
    warn "$dir is owned by uid $owner, but the containers run as PUID=$CONTAINER_UID → writes will fail."
    warn "  Fix: set PUID/PGID in $ENV_FILE to the owner, or: sudo chown -R $CONTAINER_UID:$(get_env PGID) $dir"
  fi
done

# ── Report variables present in .env.example but missing from .env ──────────
missing=$(comm -23 \
  <(grep -oE '^[A-Z_][A-Z0-9_]*=' "$EXAMPLE_FILE" | sort -u) \
  <(grep -oE '^[A-Z_][A-Z0-9_]*=' "$ENV_FILE" | sort -u) | tr -d '=' | tr '\n' ' ')
if [ -n "$missing" ]; then
  warn "Variables in $EXAMPLE_FILE that are missing from $ENV_FILE (defaults will be used):"
  warn "  $missing"
fi

echo
info "Done. Start with:  docker compose up -d"
if [ -n "$new_password" ]; then
  info "Initial dashboard password (INITIAL_PASSWORD in $ENV_FILE): $new_password"
fi
