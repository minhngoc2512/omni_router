# OmniRoute — triển khai bằng Docker Compose

Cấu hình chạy [OmniRoute](https://github.com/diegosouzapw/OmniRoute) (AI gateway gom nhiều LLM provider về một endpoint OpenAI-compatible) bằng image chính thức `diegosouzapw/omniroute`, lưu toàn bộ dữ liệu ngay trong thư mục dự án.

## Cấu trúc

```
.
├── docker-compose.yml   # service omniroute + redis
├── setup.sh             # script cài đặt lần đầu (chạy lại an toàn)
├── backup.sh            # backup .env + data/ thành file .zip
├── .env.example         # mẫu cấu hình (commit)
├── .env                 # cấu hình thật + secret (KHÔNG commit)
├── data/                # SQLite DB, backup tự động, server.env   (tự tạo, không commit)
├── logs/                # app.log                                   (tự tạo, không commit)
├── redis/               # dữ liệu Redis                             (tự tạo, không commit)
└── backups/             # file backup .zip                          (tự tạo, không commit)
```

| Service           | Image                              | Port                                      |
| ----------------- | ---------------------------------- | ----------------------------------------- |
| `omniroute`       | `diegosouzapw/omniroute:latest`    | `20128` dashboard + API, `20132` live WS  |
| `omniroute-redis` | `redis:8-alpine`                   | chỉ trong mạng nội bộ compose             |

## Yêu cầu

- Docker Engine + Docker Compose v2
- User chạy lệnh có **uid 1000** (image chạy bằng user `node` uid 1000). Nếu uid khác, xem [Xử lý sự cố](#xử-lý-sự-cố).

## Cài đặt lần đầu

```bash
./setup.sh               # tạo .env, sinh secret, tạo thư mục data/logs/redis
docker compose up -d
docker compose ps        # chờ omniroute chuyển sang (healthy)
```

`setup.sh` thực hiện:

1. Tạo `.env` từ `.env.example` (chỉ khi chưa có) và `chmod 600`
2. Sinh ngẫu nhiên các secret **đang trống**: `INITIAL_PASSWORD`, `JWT_SECRET`, `API_KEY_SECRET`, `OMNIROUTE_WS_BRIDGE_SECRET`, `MACHINE_ID_SALT`
3. Tạo thư mục theo `DATA_PATH`, `LOG_PATH`, `REDIS_DATA_PATH` (tránh Docker tạo với owner root) và cảnh báo nếu owner khác uid 1000

Có thể chạy lại bất cứ lúc nào, script tự kiểm tra trạng thái:

- Không ghi đè giá trị đã có trong `.env`, không xoá hay sửa dữ liệu trong `data/`, `logs/`, `redis/`
- Nếu đã có DB (`data/storage.sqlite`) mà **thiếu `.env`** hoặc **`API_KEY_SECRET` trống** → dừng và báo lỗi, vì sinh key mới sẽ làm hỏng API key đã mã hoá. Hãy khôi phục `.env` từ backup.
- Bỏ qua `INITIAL_PASSWORD` nếu DB đã khởi tạo (biến này chỉ dùng ở lần chạy đầu)
- Liệt kê các biến có trong `.env.example` nhưng `.env` chưa có (sau khi pull bản cấu hình mới)

Mở http://localhost:20128 và đăng nhập bằng `INITIAL_PASSWORD` trong `.env`. Sau đó nên đổi mật khẩu tại **Settings → Security**.

## Sử dụng

Vì `REQUIRE_API_KEY=true`, cần tạo API key tại **Dashboard → API Keys** trước khi gọi API:

```bash
curl http://localhost:20128/v1/chat/completions \
  -H "Authorization: Bearer <API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model": "<provider>/<model>", "messages": [{"role": "user", "content": "Hello"}]}'
```

Base URL cho các client OpenAI-compatible: `http://localhost:20128/v1`

## Cấu hình (`.env`)

| Nhóm       | Biến                                                              | Ghi chú                                                                         |
| ---------- | ----------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Image      | `OMNIROUTE_IMAGE_TAG`                                             | `latest` hoặc pin phiên bản (vd `3.8.50`)                                        |
| RAM        | `OMNIROUTE_MEMORY_MB`, `CONTAINER_MEM_LIMIT`                      | Dùng cho coding agent (Claude Code, Codex…) nên `8192` / `10g`                   |
| Port       | `BIND_ADDRESS`, `PORT`, `LIVE_WS_PORT`                            | `127.0.0.1` = chỉ máy local; `0.0.0.0` = mở ra LAN                               |
| URL public | `NEXT_PUBLIC_BASE_URL`, `LIVE_WS_ALLOWED_ORIGINS`                 | Sửa khi truy cập qua domain/IP khác localhost                                   |
| Auth       | `INITIAL_PASSWORD`, `JWT_SECRET`, `API_KEY_SECRET`, `REQUIRE_API_KEY`, `AUTH_COOKIE_SECURE` | `AUTH_COOKIE_SECURE=true` khi chạy sau HTTPS              |
| Dữ liệu    | `DATA_PATH`, `REDIS_DATA_PATH`                                    | Đường dẫn trên host                                                              |
| Log        | `LOG_PATH`, `APP_LOG_LEVEL`, `APP_LOG_MAX_FILE_SIZE`, `APP_LOG_RETENTION_DAYS`, `DOCKER_LOG_MAX_SIZE` | Log file app + giới hạn `docker logs`   |

Sau khi sửa `.env`, áp dụng bằng `docker compose up -d` (compose tự tạo lại container khi cấu hình thay đổi).

Danh sách đầy đủ các biến môi trường: [.env.example gốc của OmniRoute](https://github.com/diegosouzapw/OmniRoute/blob/main/.env.example).

### Mở ra ngoài / chạy sau reverse proxy

1. Để `BIND_ADDRESS=127.0.0.1` nếu reverse proxy (nginx, Caddy…) chạy trên cùng máy; đổi `0.0.0.0` nếu cần truy cập trực tiếp qua LAN.
2. `NEXT_PUBLIC_BASE_URL=https://your-domain`
3. Thêm `https://your-domain` vào `LIVE_WS_ALLOWED_ORIGINS`
4. `AUTH_COOKIE_SECURE=true`

## Vận hành

```bash
docker compose logs -f omniroute                # log stdout
tail -f logs/app.log                            # log file của app
docker compose restart omniroute                # restart
docker compose down                             # dừng (dữ liệu giữ nguyên)
docker compose pull && docker compose up -d     # cập nhật image mới
```

## Xoay vòng log & giới hạn dung lượng

Mọi thứ ghi ra đĩa đều có giới hạn (theo cấu hình mặc định trong `.env.example`):

| Nguồn                          | Vị trí               | Cơ chế                                                                                   | Tối đa khoảng   |
| ------------------------------ | -------------------- | ---------------------------------------------------------------------------------------- | --------------- |
| Log ứng dụng                   | `logs/app*.log`      | Kiểm tra mỗi phút: > `APP_LOG_MAX_FILE_SIZE` → đổi tên, tạo file mới; giữ `APP_LOG_MAX_FILES` file | (10+1) × 50M ≈ **550 MB** |
| `docker logs` (stdout)         | `/var/lib/docker/…`  | Docker json-file tự xoay: `DOCKER_LOG_MAX_SIZE` × `DOCKER_LOG_MAX_FILE` mỗi container     | 2 × 100 MB      |
| Backup DB tự động              | `data/db_backups/`   | Tối đa 1 bản/giờ; giữ `DB_BACKUP_MAX_FILES` bản, xoá bản cũ hơn `DB_BACKUP_RETENTION_DAYS` | 5 × kích thước DB |
| Log request/call               | trong SQLite `data/` | Xoá sau `CALL_LOG_RETENTION_DAYS` ngày, cắt bớt khi vượt `*_TABLE_MAX_ROWS` dòng          | theo số dòng    |

Ghi chú:

- File log đã xoay cũ hơn `APP_LOG_RETENTION_DAYS` chỉ bị xoá **khi khởi động**. Trong lúc chạy, dung lượng được giới hạn bằng số file (`APP_LOG_MAX_FILES`).
- Mỗi bản backup là bản sao đầy đủ của DB. Khi DB lớn lên, hãy giảm `DB_BACKUP_MAX_FILES`.
- Không cần `logrotate` bên ngoài. Nếu dùng thêm thì **không** dùng `copytruncate`, vì OmniRoute tự đổi tên file.

Xem dung lượng đang dùng:

```bash
du -sh data data/db_backups logs redis
docker system df -v | grep omniroute
```

## Backup & khôi phục

> ⚠️ **Không xoá `data/server.env`.** Lần chạy đầu, OmniRoute tự sinh key mã hoá DB (`STORAGE_ENCRYPTION_KEY`) và lưu vào file này. Mất file → không đọc được DB. Tương tự, đổi `API_KEY_SECRET` sau khi đã có dữ liệu sẽ làm hỏng các key đã lưu.

Dùng `backup.sh` để nén `.env`, `docker-compose.yml` và `data/` thành một file `.zip`. **Không cần dừng container.**

```bash
./backup.sh                          # → backups/omniroute-backup-YYYYmmdd-HHMMSS.zip
./backup.sh --with-logs              # kèm thư mục logs/
./backup.sh -o /mnt/nas/omniroute -k 30   # thư mục đích khác, giữ 30 bản
```

- DB được snapshot bằng SQLite online backup API, nên bản backup nhất quán ngay cả khi app đang ghi. Snapshot được kiểm tra bằng `PRAGMA quick_check`, file zip được kiểm tra bằng `unzip -t`.
- Không đưa `data/db_backups/` vào zip (đó là các bản sao DB do OmniRoute tự tạo).
- Chỉ giữ `BACKUP_KEEP` bản mới nhất trong `BACKUP_DIR` (cấu hình ở mục 6 của `.env`).
- File zip có quyền `600`, thư mục backup có quyền `700`. **File zip chứa secret**, nên hãy cất ở nơi an toàn và copy ra ngoài máy này. `backups/` và `*.zip` đã có trong `.gitignore`.

Chạy tự động hằng ngày lúc 3h sáng (`crontab -e`):

```cron
0 3 * * * /đường/dẫn/omni_router/backup.sh >> /đường/dẫn/omni_router/logs/backup.log 2>&1
```

### Khôi phục

```bash
docker compose down
mv data data.old                     # giữ bản hiện tại phòng khi cần
unzip -o backups/omniroute-backup-XXXXXXXX-XXXXXX.zip -x BACKUP_INFO.txt
docker compose up -d
```

> Luôn khôi phục vào thư mục `data/` **trống** (vì vậy mới `mv data data.old`). Nếu các file `storage.sqlite-wal`/`-shm` cũ vẫn còn cạnh DB vừa khôi phục, SQLite có thể áp dụng nhầm chúng và làm hỏng DB.

Ngoài ra OmniRoute tự backup SQLite vào `data/db_backups/` mỗi lần khởi động (tắt bằng `DISABLE_SQLITE_AUTO_BACKUP=true`).

## Xử lý sự cố

- **Lỗi permission denied trên `data/`, `logs/`, `redis/`**: thư mục bị tạo với owner root hoặc uid của bạn khác 1000. Sửa bằng `sudo chown -R 1000:1000 data logs redis`.
- **Container `unhealthy` / bị OOM khi dùng coding agent**: tăng `OMNIROUTE_MEMORY_MB` và `CONTAINER_MEM_LIMIT` (limit luôn lớn hơn heap).
- **Dashboard realtime không cập nhật khi truy cập qua domain/IP khác**: thêm origin đó vào `LIVE_WS_ALLOWED_ORIGINS`.
- **Gọi `/v1/*` trả 401 `AUTH_002`**: thiếu header `Authorization: Bearer <API_KEY>` (do `REQUIRE_API_KEY=true`).

## Tham khảo

- Repo: https://github.com/diegosouzapw/OmniRoute
- Docker guide: https://github.com/diegosouzapw/OmniRoute/blob/main/docs/guides/DOCKER_GUIDE.md
# omni_router
