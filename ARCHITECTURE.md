# Architecture - MinIO Odoo Project

## System Overview

```text
+------------------+       +-------------------+       +------------------+
|   Odoo 17 Web    |<----->| Flutter Client Svc|<----->|   MinIO Server   |
|   (Browser/OWL)  |       |   (System Tray)   |       |  (S3-compatible) |
+------------------+       +-------------------+       +------------------+
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

```text
1. User clicks "Upload" in Odoo Documents UI
2. Flutter service opens native file picker (via OS dialogs)
3. Flutter service queues the file in UploadQueue
4. Flutter service uploads files to MinIO bucket via S3 API
5. Flutter service sends metadata to Odoo via /minio/sync_metadata (JSON-RPC)
6. Odoo creates/updates documents.document with minio_object_name
7. Progress streamed/polled via /api/task/<id>
```

### Download Flow (Odoo -> MinIO -> Browser)

```text
1. User clicks document in Odoo Documents
2. Odoo controller /minio/api/download proxies request to MinIO
3. MinIO returns file stream
4. Odoo serves file to browser with correct MIME type
5. ZIP download available via /minio/api/download_zip
```

### Browse Flow (Odoo -> MinIO)

```text
1. User opens MinIO Browser in Odoo
2. JS calls /minio/api/list?path=...
3. Odoo controller lists objects from MinIO bucket
4. Results rendered in custom OWL MinIO browser component
```

## Component Architecture

### Odoo Module (`documents_minio_sync`)

```text
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
        ├── minio_login_dialog.js     # Auth dialog for Flutter service
        └── ...
```

### Flutter Service (`minio_sync/`)

```text
minio_sync/
├── lib/
│   ├── main.dart            # Application entrypoint & tray setup
│   ├── models/              # Data models (AppConfig, Task, etc.)
│   ├── server/              # Isolate HTTP Server (shelf/shelf_router)
│   ├── services/            # MinIO Client & App Business Logic
│   └── ui/                  # Settings UI & Desktop App Views
├── pubspec.yaml             # Dart dependencies
└── android/, ios/, windows/, macos/, linux/
```

## Model Diagram

```text
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

### Flutter Service API (REST)

| Route | Method | Purpose |
|-------|--------|---------|
| `/api/upload` | POST | Start/Queue file upload to MinIO |
| `/api/tasks` | GET | List all upload tasks |
| `/api/task/:id` | GET | Get single task status/progress |
| `/api/auth/login` | POST | Odoo session login |

## Communication Protocols

### Odoo <-> Flutter Service
- Flutter service fetches MinIO config from Odoo via `/minio/get_config` (JSON-RPC)
- Flutter service syncs upload metadata to Odoo via `/minio/sync_metadata` (JSON-RPC)
- Flutter service sends logs to Odoo via `/minio/log_access`, `/minio/log_service`

### Flutter Service <-> MinIO
- Direct S3 API calls via `minio_new` Dart SDK
- Operations: Upload, Download, List, Delete, BucketExists

### Browser <-> Flutter Service
- REST API calls from Odoo JS frontend to Flutter service at `localhost:9999`
- Polling for state updates of uploaded files

## Concurrency Model (Flutter Service)

- **Isolates**: The embedded HTTP Server runs in a separate Dart Isolate from the main UI, preventing network or file I/O operations from blocking the Desktop UI.
- **UploadQueue**: Upload tasks are processed sequentially using an asynchronous queue (FIFO).
- **Asynchronous Execution**: Deeply relies on `Stream` and `Future` logic for monitoring download/upload chunking and tracking progression dynamically.

## Security Architecture

```text
Odoo (auth='user')
  └── Session-based authentication
  └── ACL: ir.model.access.csv
      ├── minio.config: manager=CRUD, user=R
      ├── minio.device: manager=CRUD
      └── logs: user=CRU (no delete)

Flutter Service
  └── Odoo session cookie forwarded to sync calls
  └── CORS allowed from specific Odoo host ports 
  └── Localhost-only binding (127.0.0.1:9999) restricting network exposure
```

## Deployment

```text
Production Setup:
  MinIO Server (S3)  <------>  Odoo 17 Server
       ^                           ^
       |                           |
       +------ Flutter Service ----+
            (per OS workstation)
```

- MinIO server: standalone or clustered
- Odoo server: with `documents` + `documents_minio_sync` modules installed
- Flutter service: installed per client workstation, runs as system tray app natively via Windows, macOS, or Linux.
- `backend_endpoint` on `minio.config` allows split public/internal MinIO access
