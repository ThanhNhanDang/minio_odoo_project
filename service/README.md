# MinIO Odoo Service (Go)

Cross-platform HTTP service that provides a file management Web UI and REST API for MinIO, integrated with Odoo.

## Prerequisites

- [Go 1.22+](https://go.dev/dl/)
- MinIO server (or Odoo with MinIO module configured)

## Quick Start

```bash
cd service

# Download dependencies
go mod tidy

# Run in development mode
go run ./cmd/minio-service

# Or with flags
go run ./cmd/minio-service --port 5555 --config /path/to/config.json --no-browser
```

The service starts at `http://localhost:5555` serving both API and Web UI on the same port.

## Build

```bash
# Build for current platform
make build

# Cross-compile for all platforms
make build-all

# Individual targets
make build-windows    # Windows amd64
make build-linux      # Linux amd64
make build-linux-arm64  # Linux arm64
make build-android    # Android arm64
```

Binaries are output to `build/` directory.

## Configuration

Config file location:
- **Windows**: `%LOCALAPPDATA%\MinIOTray\config.json`
- **Linux/macOS**: `~/.minio-tray/config.json`

```json
{
  "odoo": {
    "url": "http://localhost:8069",
    "db": "odoo",
    "username": "admin",
    "password": "admin"
  },
  "minio": {
    "endpoint": "localhost:9000",
    "access_key": "minioadmin",
    "secret_key": "minioadmin",
    "alias": "odoo-minio",
    "secure": false
  },
  "default_bucket": "odoo-documents",
  "client_id": "auto-generated-uuid"
}
```

You can also configure via the Web UI login dialog or the `/api/config/auto_set` endpoint.

## Architecture

```
Single binary (port 5555)
├── GET  /              → Embedded Web UI (index.html)
├── GET  /css/*         → Embedded CSS
├── GET  /js/*          → Embedded JS
├── GET  /api/*         → REST API handlers
└── GET  /api/upload/progress/* → SSE streams
```

Key packages:
- `internal/api` — HTTP router (chi), all API handlers, middleware
- `internal/config` — Configuration management, Odoo JSON-RPC auth
- `internal/minio` — MinIO Go SDK wrapper (replaces mc CLI)
- `internal/task` — Background task management with goroutines
- `internal/platform` — Platform-specific file dialogs (Windows/Linux/Android)
- `internal/updater` — GitHub release auto-update checker
- `web/` — Embedded static files (Bootstrap 5 SPA)

## API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | /api/bucket | Current bucket info |
| GET | /api/list?path= | File listing |
| GET | /api/tree | Folder tree |
| GET | /api/download?path= | Download/preview file |
| POST | /api/upload | Upload files (multipart or JSON) |
| GET | /api/upload/progress/{id} | SSE progress stream |
| POST | /api/delete | Delete file/folder |
| POST | /api/download_zip | Download as ZIP |
| POST | /api/sync | Sync local path |
| POST | /api/pick_sync | Open file picker + sync |
| GET/DELETE | /api/task/{id} | Task status/cleanup |
| POST | /api/task/{id}/cancel | Cancel running task |
| GET | /api/tasks | All tasks |
| POST | /api/auth/login | Odoo login |
| POST | /api/auth/logout | Logout |
| GET | /api/auth/status | Auth status |
| GET | /api/system/status | System info + version |
| POST | /api/config/auto_set | Update Odoo URL/DB |
| GET | /api/system/update_check | Check for updates |
| POST | /api/system/update | Trigger update |

## Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--port` | 5555 | HTTP server port |
| `--config` | (auto) | Path to config.json |
| `--no-browser` | false | Skip auto-opening browser |
| `--version` | - | Print version and exit |
