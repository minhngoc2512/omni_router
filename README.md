# OmniRoute — Docker Compose deployment

Runs [OmniRoute](https://github.com/diegosouzapw/OmniRoute) (an AI gateway that unifies many LLM providers behind a single OpenAI-compatible endpoint) using the official `diegosouzapw/omniroute` image, with all data stored inside the project directory.

## Layout

```
.
├── docker-compose.yml   # omniroute + redis services
├── setup.sh             # first-time setup script (safe to re-run)
├── backup.sh            # back up .env + data/ into a .zip file
├── update.sh            # update the image to a new version + restart
├── restore.sh           # restore .env + data/ from a backup .zip
├── .env.example         # configuration template (committed)
├── .env                 # real configuration + secrets (NOT committed)
├── data/                # SQLite DB, automatic backups, server.env   (created at runtime, not committed)
├── logs/                # app.log                                     (created at runtime, not committed)
├── redis/               # Redis data                                  (created at runtime, not committed)
└── backups/             # .zip backup files                           (created at runtime, not committed)
```

| Service           | Image                           | Port                                     |
| ----------------- | ------------------------------- | ---------------------------------------- |
| `omniroute`       | `diegosouzapw/omniroute:latest` | `20128` dashboard + API, `20132` live WS |
| `omniroute-redis` | `redis:8-alpine`                | internal compose network only            |

## Requirements

- Docker Engine + Docker Compose v2
- `openssl`, `zip`, `unzip`, `python3` (used by the scripts)
- The user running the commands should have **uid 1000** (the image runs as user `node`, uid 1000). If your uid differs, see [Troubleshooting](#troubleshooting).

## First-time setup

```bash
./setup.sh               # create .env, generate secrets, create data/logs/redis directories
docker compose up -d
docker compose ps        # wait until omniroute is (healthy)
```

`setup.sh` does the following:

1. Creates `.env` from `.env.example` (only if it does not exist yet) and runs `chmod 600` on it
2. Generates random values for secrets that are **empty**: `INITIAL_PASSWORD`, `JWT_SECRET`, `API_KEY_SECRET`, `OMNIROUTE_WS_BRIDGE_SECRET`, `MACHINE_ID_SALT`
3. Creates the directories from `DATA_PATH`, `LOG_PATH`, `REDIS_DATA_PATH` (so Docker does not create them as root) and warns if their owner is not uid 1000

It can be re-run at any time; the script checks the current state first:

- It never overwrites existing values in `.env` and never deletes or modifies anything in `data/`, `logs/`, `redis/`
- If a DB already exists (`data/storage.sqlite`) but **`.env` is missing** or **`API_KEY_SECRET` is empty** → it stops with an error, because generating a new key would break the encrypted API keys. Restore `.env` from a backup instead.
- It skips `INITIAL_PASSWORD` if the DB is already initialized (this variable is only used on first boot)
- It lists variables present in `.env.example` but missing from `.env` (e.g. after pulling a newer config template)

Open http://localhost:20128 and log in with `INITIAL_PASSWORD` from `.env`. Then change the password under **Settings → Security**.

## Usage

Because `REQUIRE_API_KEY=true`, create an API key under **Dashboard → API Keys** before calling the API:

```bash
curl http://localhost:20128/v1/chat/completions \
  -H "Authorization: Bearer <API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model": "<provider>/<model>", "messages": [{"role": "user", "content": "Hello"}]}'
```

Base URL for OpenAI-compatible clients: `http://localhost:20128/v1`

## Configuration (`.env`)

| Group      | Variables                                                                                             | Notes                                                       |
| ---------- | ----------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| Image      | `OMNIROUTE_IMAGE_TAG`                                                                                 | `latest` or a pinned version (e.g. `3.8.50`)                |
| RAM        | `OMNIROUTE_MEMORY_MB`, `CONTAINER_MEM_LIMIT`                                                          | For coding agents (Claude Code, Codex…) use `8192` / `10g`  |
| Ports      | `BIND_ADDRESS`, `PORT`, `LIVE_WS_PORT`                                                                | `127.0.0.1` = local machine only; `0.0.0.0` = open to LAN   |
| Public URL | `NEXT_PUBLIC_BASE_URL`, `LIVE_WS_ALLOWED_ORIGINS`                                                     | Change when accessing via a domain/IP other than localhost  |
| Auth       | `INITIAL_PASSWORD`, `JWT_SECRET`, `API_KEY_SECRET`, `REQUIRE_API_KEY`, `AUTH_COOKIE_SECURE`           | Set `AUTH_COOKIE_SECURE=true` when served over HTTPS        |
| Data       | `DATA_PATH`, `REDIS_DATA_PATH`                                                                        | Host paths                                                  |
| Logs       | `LOG_PATH`, `APP_LOG_LEVEL`, `APP_LOG_MAX_FILE_SIZE`, `APP_LOG_RETENTION_DAYS`, `DOCKER_LOG_MAX_SIZE` | App log file + `docker logs` limits                         |
| Backup     | `BACKUP_DIR`, `BACKUP_KEEP`                                                                           | Used by `backup.sh`                                         |

After editing `.env`, apply it with `docker compose up -d` (compose recreates the container when its configuration changes).

Full list of environment variables: [upstream OmniRoute .env.example](https://github.com/diegosouzapw/OmniRoute/blob/main/.env.example).

### Exposing it / running behind a reverse proxy

1. Keep `BIND_ADDRESS=127.0.0.1` if the reverse proxy (nginx, Caddy…) runs on the same host; use `0.0.0.0` for direct LAN access.
2. `NEXT_PUBLIC_BASE_URL=https://your-domain`
3. Add `https://your-domain` to `LIVE_WS_ALLOWED_ORIGINS`
4. `AUTH_COOKIE_SECURE=true`

## Operations

```bash
docker compose logs -f omniroute                # stdout logs
tail -f logs/app.log                            # app log file
docker compose restart omniroute                # restart
docker compose down                             # stop (data is kept)
docker compose up -d                            # apply changes to .env / docker-compose.yml
./update.sh                                     # update to a new version (see below)
```

## Updating

Use `update.sh`. It backs up, pulls the image, restarts and waits for the container to become healthy:

```bash
./update.sh --check          # show the running version & latest stable versions on Docker Hub (changes nothing)
./update.sh                  # update to the newest image for the tag in .env (default: latest)
./update.sh 3.8.50           # switch to a specific version — also used to roll back
```

What the script does:

1. `docker compose pull` for the tag. If the pull fails (e.g. the tag does not exist) it stops immediately and **changes nothing**.
2. If the image did not change → reports "already up to date" and **does not restart the container**.
3. Runs `./backup.sh` before updating, since a new version may migrate the DB. If the backup fails, it stops.
4. If a specific version was given → writes it to `OMNIROUTE_IMAGE_TAG` in `.env`.
5. `docker compose up -d` → waits for healthy (up to 240s, configurable via the `HEALTH_TIMEOUT` environment variable).
6. If it does not become healthy → prints the last 50 log lines plus the commands to roll back and to restore the backup.

Options: `--no-backup` skips step 3; `--force` recreates the container even if the image did not change.

**Which tag to use?** `latest` always follows the newest stable release — convenient, but it can upgrade unintentionally whenever `docker compose pull` runs. For production, **pin a specific version** (`./update.sh 3.8.50`) and upgrade deliberately after reading the [release notes](https://github.com/diegosouzapw/OmniRoute/releases).

**Rolling back:** run `./update.sh <old-version>` (the script prints this command after every update). If the new version has already migrated the DB and the old version will not start, restore the backup the script created right before the update: `./restore.sh --latest` (see [Restore](#restore)).

Manual update (without the script):

```bash
./backup.sh
docker compose pull
docker compose up -d
docker compose ps            # wait for (healthy)
docker image prune           # remove old unused images
```

## Log rotation & disk usage limits

Everything written to disk is bounded (with the defaults from `.env.example`):

| Source                 | Location              | Mechanism                                                                                                    | Approx. maximum           |
| ---------------------- | --------------------- | ------------------------------------------------------------------------------------------------------------ | ------------------------- |
| App log                | `logs/app*.log`       | Checked every minute: > `APP_LOG_MAX_FILE_SIZE` → renamed, new file created; keeps `APP_LOG_MAX_FILES` files | (10+1) × 50M ≈ **550 MB** |
| `docker logs` (stdout) | `/var/lib/docker/…`   | Docker json-file rotation: `DOCKER_LOG_MAX_SIZE` × `DOCKER_LOG_MAX_FILE` per container                       | 2 × 100 MB                |
| Automatic DB backups   | `data/db_backups/`    | At most 1 per hour; keeps `DB_BACKUP_MAX_FILES` copies, deletes those older than `DB_BACKUP_RETENTION_DAYS`  | 5 × DB size               |
| Request/call logs      | inside SQLite `data/` | Deleted after `CALL_LOG_RETENTION_DAYS` days, trimmed when exceeding `*_TABLE_MAX_ROWS` rows                 | bounded by row count      |

Notes:

- Rotated log files older than `APP_LOG_RETENTION_DAYS` are only deleted **at startup**. While running, disk usage is bounded by the file count (`APP_LOG_MAX_FILES`).
- Each DB backup is a full copy of the DB. As the DB grows, lower `DB_BACKUP_MAX_FILES`.
- No external `logrotate` is needed. If you add one anyway, do **not** use `copytruncate`, since OmniRoute rotates by renaming the file.

Check current usage:

```bash
du -sh data data/db_backups logs redis backups
docker system df -v | grep omniroute
```

## Backup & restore

> ⚠️ **Do not delete `data/server.env`.** On first boot OmniRoute generates the DB encryption key (`STORAGE_ENCRYPTION_KEY`) and stores it in this file. Lose it → the DB can no longer be read. Likewise, changing `API_KEY_SECRET` once data exists breaks the stored keys.

Use `backup.sh` to archive `.env`, `docker-compose.yml` and `data/` into a single `.zip` file. **No need to stop the container.**

```bash
./backup.sh                               # → backups/omniroute-backup-YYYYmmdd-HHMMSS.zip
./backup.sh --with-logs                   # also include logs/
./backup.sh -o /mnt/nas/omniroute -k 30   # different destination, keep 30 backups
```

- The DB is snapshotted via the SQLite online backup API, so the backup is consistent even while the app is writing. The snapshot is verified with `PRAGMA quick_check` and the zip with `unzip -t`.
- `data/db_backups/` is not included (those are OmniRoute's own DB copies).
- Only the newest `BACKUP_KEEP` backups are kept in `BACKUP_DIR` (section 6 of `.env`).
- Zip files are mode `600` and the backup directory is `700`. **The zip contains secrets**, so store it somewhere safe and copy it off this machine. `backups/` and `*.zip` are already in `.gitignore`.

Run it daily at 3 AM (`crontab -e`):

```cron
0 3 * * * /path/to/omni_router/backup.sh >> /path/to/omni_router/logs/backup.log 2>&1
```

### Restore

Use `restore.sh`:

```bash
./restore.sh --list                  # list backups in BACKUP_DIR (newest first)
./restore.sh --latest                # restore the newest backup
./restore.sh backups/omniroute-backup-YYYYmmdd-HHMMSS.zip
./restore.sh <file.zip> --keep-env   # keep the current .env (only if the data-bound secrets match)
./restore.sh <file.zip> --yes        # no confirmation prompt (required when not run interactively)
```

What the script does:

1. **Verifies before touching anything**: the zip must pass `unzip -t`, contain `data/storage.sqlite` (and `.env`), and the DB snapshot must pass `PRAGMA quick_check`. If any check fails, nothing is changed.
2. Shows what it is about to do and asks for confirmation.
3. Stops the `omniroute` container.
4. **Deletes nothing**: renames the current data dir and `.env` to `data.pre-restore-<timestamp>` / `.env.pre-restore-<timestamp>`, then puts the backup's `data/` into a fresh directory (so no stale `storage.sqlite-wal`/`-shm` can be applied to the restored DB).
5. Restores `.env` from the backup, because `API_KEY_SECRET` must match the restored DB. With `--keep-env` it keeps the current `.env`, but refuses if `API_KEY_SECRET` / `STORAGE_ENCRYPTION_KEY` differ from the backup.
6. Starts the stack and waits until it is healthy. If it is not, it prints the logs and the exact commands to undo the restore.

`logs/` and `docker-compose.yml` inside the zip are not restored (the compose file is tracked in git). Once you have verified the restore, delete the `*.pre-restore-*` directories/files to free up space.

Manual restore (without the script):

```bash
docker compose down
mv data data.old                     # keep the current data just in case
unzip -o backups/omniroute-backup-XXXXXXXX-XXXXXX.zip .env 'data/*'
docker compose up -d
```

> Always restore into an **empty** `data/` directory (hence `mv data data.old`). If stale `storage.sqlite-wal`/`-shm` files are left next to the restored DB, SQLite may apply them and corrupt the DB.

OmniRoute also backs up SQLite to `data/db_backups/` on startup (disable with `DISABLE_SQLITE_AUTO_BACKUP=true`).

## Troubleshooting

- **Permission denied on `data/`, `logs/`, `redis/`**: the directories were created as root or your uid is not 1000. Fix with `sudo chown -R 1000:1000 data logs redis`.
- **Container `unhealthy` / OOM when using coding agents**: increase `OMNIROUTE_MEMORY_MB` and `CONTAINER_MEM_LIMIT` (the limit must always be larger than the heap).
- **Realtime dashboard does not update when accessed via another domain/IP**: add that origin to `LIVE_WS_ALLOWED_ORIGINS`.
- **`/v1/*` returns 401 `AUTH_002`**: the `Authorization: Bearer <API_KEY>` header is missing (because `REQUIRE_API_KEY=true`).

## References

- Repo: https://github.com/diegosouzapw/OmniRoute
- Docker guide: https://github.com/diegosouzapw/OmniRoute/blob/main/docs/guides/DOCKER_GUIDE.md
