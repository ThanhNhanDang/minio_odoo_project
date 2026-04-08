# MinIO Odoo Project - CLAUDE.md

## Project Overview

This is a **MinIO + Odoo 17 Documents integration** project that provides two-way file synchronization between Odoo's Document Management System (DMS) and MinIO object storage.

## Tech Stack

| Layer | Technology |
|-------|-----------|
| **Odoo Module** | Python 3.10+, Odoo 17 Enterprise (documents module) |
| **Client Service** | Flutter (Dart >=3.3.0), minio_new package, shelf HTTP server |
| **Frontend** | Odoo OWL components, vanilla JS (embedded web UI) |
| **Storage** | MinIO S3-compatible object storage |
| **Communication** | JSON-RPC (Odoo standard), REST API (Flutter service), SSE (progress) |

## Module Structure

```
minio_odoo_project/
  documents/              # Odoo Enterprise documents module (base dependency)
  documents_minio_sync/   # Custom Odoo module - MinIO integration
  minio_sync/             # Flutter client service (system tray + HTTP API, cross-platform)
  auto_backup_ym/         # Standalone Python backup tool (Flask)
  docs/                   # Architecture & migration documentation
```

## Key Components

### 1. `documents_minio_sync` (Odoo Module)
- **Models**: `minio.config`, `minio.device`, `minio.access.log`, `minio.service.log`
- **Inherits**: `documents.document` (adds `minio_object_name`, `minio_synced`, `minio_last_sync`)
- **Controllers**: `/minio/get_config`, `/minio/api/list`, `/minio/api/download`, `/minio/api/delete`, `/minio/api/download_zip`, `/minio/sync_metadata`, `/minio/log_access`, `/minio/log_service`
- **JS Frontend**: MinIO browser, download progress bar, document inspector patch, login dialog

### 2. `minio_sync/` (Flutter Client Service)
- **Framework**: Flutter (Dart >=3.3.0 <4.0.0)
- **HTTP Server**: shelf + shelf_router (runs in Isolate on desktop, port 9999)
- **MinIO Client**: minio_new package (v1.0.2)
- **Desktop**: window_manager, tray_manager (system tray app)
- **Mobile**: flutter_foreground_task (placeholder for future)
- **Upload Pipeline**: POST /api/upload → UploadQueue (FIFO) → MinioService.uploadFile() → sync_metadata to Odoo

## Development Commands

```bash
# Flutter service
cd minio_sync
flutter pub get
flutter run -d windows          # Desktop debug
flutter build windows           # Desktop release
flutter analyze                 # Lint
flutter test                    # Tests

# Odoo (from Odoo root)
python odoo-bin -d minio --addons-path=addons -u documents_minio_sync
```

## Configuration

- **Flutter service**: `config.json` (desktop, next to executable) or SharedPreferences (mobile)
- **Odoo module**: `minio.config` model (Settings > MinIO Configuration)
- **Default bucket**: `odoo-documents` / `autonsi-documents`

## Important Conventions

- Odoo module follows Odoo 17 conventions (NOT Odoo 19)
- Flutter service uses shelf for HTTP, minio_new for S3 operations
- MinIO URLs in Odoo are always rewritten to internal `/minio/api/download?path=...` format
- Device tracking via `client_id` (UUID) registered on first connection
- All Odoo controllers use `auth='user'` except where noted
- Flutter HTTP server runs in a separate Dart Isolate (non-blocking UI)
- Flutter server binds to `127.0.0.1:9999` (localhost only)

## Security Notes

- MinIO credentials stored in `minio.config` model (not hardcoded)
- Flutter service authenticates to Odoo via JSON-RPC session cookie
- CSRF disabled on some POST routes (`csrf=False`) - known technical debt
- `sudo()` used in device registration and log creation

## Memory Management (MANDATORY)

After every code change, feature addition, bug fix, or architectural update in this project, you MUST update the project memory at `~/.claude/projects/D--workspaces-projects-odoo17-demo-minio-documents/memory/` to preserve context for future sessions.

**What to update:**
- New models, fields, or API endpoints added
- Architectural decisions and their rationale
- Bug fixes with root cause context
- Configuration changes or new dependencies
- Integration changes between Odoo module, Flutter service, or MinIO

**How:**
1. Check existing memory files in the memory directory
2. Update relevant memory file or create a new one if the topic is new
3. Update `MEMORY.md` index if a new file was created

This ensures continuity across sessions and prevents re-discovery of already-known context.

## Testing

```bash
# Odoo tests
python odoo-bin -d test_db --test-enable --test-tags=documents_minio_sync --stop-after-init

# Flutter tests
cd minio_sync && flutter test
```
