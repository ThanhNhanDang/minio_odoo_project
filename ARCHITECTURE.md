# Architecture - MinIO Odoo Project

## System Overview

```
+------------------+       +------------------+       +------------------+
|   Odoo 17 Web    |<----->|  Go Client Svc   |<----->|   MinIO Server   |
|   (Browser/OWL)  |       |  (System Tray)   |       |  (S3-compatible) |
+------------------+       +------------------+       +------------------+
        |                          |
        |  JSON-RPC / HTTP         |  REST API (:9999)
        v                          v
+------------------+       +------------------+
| Odoo Backend     |       | Native File      |
| (Python/ORM)     |       | System (OS)      |
+------------------+       +------------------+
```

## Data Flow

### Upload Flow (Client -> MinIO -> Odoo)

```
1. User clicks "Upload" in Odoo Documents UI or Go Web UI
2. Go service opens native file picker (zenity)
3. Go service uploads files to MinIO bucket via S3 API
4. Go service sends metadata to Odoo via /minio/sync_metadata (JSON-RPC)
5. Odoo creates/updates documents.document with minio_object_name
6. Progress streamed via SSE (/api/upload/progress/:taskId)
```

### Download Flow (Odoo -> MinIO -> Browser)

```
1. User clicks document in Odoo Documents
2. Odoo controller /minio/api/download proxies request to MinIO
3. MinIO returns file stream
4. Odoo serves file to browser with correct MIME type
5. ZIP download available via /minio/api/download_zip
```

### Browse Flow (Odoo -> MinIO)

```
1. User opens MinIO Browser in Odoo
2. JS calls /minio/api/list?path=...
3. Odoo controller lists objects from MinIO bucket
4. Results rendered in custom OWL MinIO browser component
```

## Component Architecture

### Odoo Module (`documents_minio_sync`)

```
documents_minio_sync/
├── __manifest__.py          # Module declaration, Odoo 17
├── __init__.py
├── controllers/
│   └── main.py              # All HTTP/JSON endpoints
├── models/
│   ├── minio_config.py      # MinIO connection settings (singleton pattern)
│   ├── documents_document.py # Extends documents.document with MinIO fields
│   ├── minio_device.py      # Client device tracking & heartbeat
│   ├── minio_access_log.py  # Download/upload audit log
│   └── minio_service_log.py # Client error/warning log
├── security/
│   └── ir.model.access.csv  # ACL: manager full, user read-only on config
├── views/
│   ├── minio_config_views.xml
│   ├── minio_device_views.xml
│   ├── documents_document_views.xml
│   └── documents_kanban_views.xml
├── data/
│   └── minio_config.xml     # Default config record
└── static/src/
    ├── services/
    │   └── minio_service.js          # OWL service: MinIO API abstraction
    ├── components/
    │   └── download_progress_bar.js  # Progress bar component
    ├── js/
    │   ├── download_progress_service.js
    │   └── documents_inspector_patch.js
    └── views/
        ├── documents_minio_sync.js   # Main sync view
        ├── minio_browser.js          # File browser component
        ├── minio_login_dialog.js     # Auth dialog for Go service
        ├── minio_config_form_patch.js
        ├── minio_file_viewer_patch.js
        ├── minio_deletion_patch.js
        ├── minio_document_mixin_patch.js
        ├── minio_attachment_patch.js
        ├── minio_kanban_record_patch.js
        └── minio_device_list_patch.js
```

### Go Service (`service/`)

```
service/
├── cmd/minio-service/
│   └── main.go              # Entrypoint: wire dependencies, start tray + HTTP
├── internal/
│   ├── api/
│   │   └── server.go        # Gin HTTP router, all API handlers
│   ├── auth/
│   │   └── auth.go          # Odoo JSON-RPC session authentication
│   ├── config/
│   │   └── config.go        # Thread-safe config with file persistence
│   ├── minioclient/
│   │   └── client.go        # MinIO Go SDK wrapper (CRUD, list, delete)
│   ├── tasks/
│   │   └── manager.go       # Background task tracking + SSE pub/sub
│   ├── upload/
│   │   └── engine.go        # Multi-file upload pipeline + Odoo sync
│   ├── tray/
│   │   └── tray.go          # System tray icon + menu
│   └── updater/
│       └── updater.go       # Self-update: check, download, verify, apply
├── web/
│   ├── embed.go             # go:embed for static files
│   └── static/              # Standalone web UI (HTML/CSS/JS)
├── config.json              # Runtime configuration
├── go.mod
└── Makefile
```

## Model Diagram

```
minio.config (singleton)
├── endpoint, access_key, secret_key, bucket_name
├── backend_endpoint (internal network)
└── client_service_url

documents.document (inherited)
├── minio_object_name (Char, indexed)
├── minio_synced (Boolean)
└── minio_last_sync (Datetime)

minio.device
├── client_id (unique UUID)
├── user_id -> res.users
├── status (online/offline)
├── log_ids -> minio.service.log (One2many)
└── access_log_ids -> minio.access.log (One2many)

minio.access.log
├── name (operation type)
├── device_id -> minio.device
├── user_id -> res.users
└── status (success/failed/warning)

minio.service.log
├── device_id -> minio.device
├── level (info/warning/error)
└── message, details
```

## API Endpoints

### Odoo Controllers (Python)

| Route | Type | Auth | Purpose |
|-------|------|------|---------|
| `/minio/get_config` | JSON | user | Get active MinIO config + auto-register device |
| `/minio/api/list` | HTTP | user | List MinIO objects at path |
| `/minio/api/download` | HTTP | user | Proxy file download from MinIO |
| `/minio/api/delete` | HTTP | user | Delete file/folder in MinIO |
| `/minio/api/download_zip` | HTTP | user | Download multiple files as ZIP |
| `/minio/api/bucket` | HTTP | user | Get bucket info |
| `/minio/sync_metadata` | JSON | user | Update document after upload |
| `/minio/log_access` | JSON | user | Receive access logs from client |
| `/minio/log_service` | JSON | user | Receive error logs from client |

### Go Service API (REST)

| Route | Method | Purpose |
|-------|--------|---------|
| `/api/upload` | POST | Start file upload to MinIO |
| `/api/upload/progress/:taskId` | GET | SSE progress stream |
| `/api/list` | GET | List MinIO objects |
| `/api/delete` | POST | Delete objects |
| `/api/pick_sync` | POST | Open file picker + upload |
| `/api/download_async` | POST | Start async download |
| `/api/tasks` | GET | List all tasks |
| `/api/task/:id` | GET/DELETE | Get/delete task |
| `/api/task/:id/cancel` | POST | Cancel running task |
| `/api/auth/login` | POST | Odoo session login |
| `/api/auth/logout` | POST | Clear session |
| `/api/auth/status` | GET | Auth state |
| `/api/config/auto_set` | POST | Update Odoo URL/DB |
| `/api/system/status` | GET | Service health + version |
| `/api/bucket` | GET | Bucket info |

## Communication Protocols

### Odoo <-> Go Service
- Go service fetches MinIO config from Odoo via `/minio/get_config` (JSON-RPC)
- Go service syncs upload metadata to Odoo via `/minio/sync_metadata` (JSON-RPC)
- Go service sends logs to Odoo via `/minio/log_access`, `/minio/log_service`
- Odoo sends device check signals via `bus.bus` (long-polling)

### Go Service <-> MinIO
- Direct S3 API calls via `minio-go/v7` SDK
- Operations: Upload, Download, List, Delete, BucketExists

### Browser <-> Go Service
- REST API calls from Odoo JS frontend to Go service at `:9999`
- SSE for real-time upload progress

## Concurrency Model (Go Service)

- **Config**: `sync.RWMutex` protected, atomic updates via `Update()` + `Snapshot()`
- **Tasks**: Mutex-protected map, SSE via buffered channels (32 capacity)
- **Upload**: Per-file goroutine with cancellation via `context.Context` + cancel channel
- **Auth**: RWMutex-protected session state
- **Tray**: Runs on main thread (OS requirement), HTTP server in background goroutine

## Security Architecture

```
Odoo (auth='user')
  └── Session-based authentication
  └── ACL: ir.model.access.csv
      ├── minio.config: manager=CRUD, user=R
      ├── minio.device: manager=CRUD
      └── logs: user=CRU (no delete)

Go Service
  └── Odoo session cookie forwarded to sync calls
  └── CORS: AllowAllOrigins (permissive for dev)
  └── No standalone auth (relies on Odoo session)
```

## Deployment

```
Production Setup:
  MinIO Server (S3)  <------>  Odoo 17 Server
       ^                           ^
       |                           |
       +---- Go Service (per workstation, system tray) ----+
```

- MinIO server: standalone or clustered
- Odoo server: with `documents` + `documents_minio_sync` modules installed
- Go service: installed per client workstation, runs as system tray app
- `backend_endpoint` on `minio.config` allows split public/internal MinIO access
