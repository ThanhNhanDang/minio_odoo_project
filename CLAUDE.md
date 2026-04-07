# MinIO Odoo Project - CLAUDE.md

## Project Overview

This is a **MinIO + Odoo 17 Documents integration** project that provides two-way file synchronization between Odoo's Document Management System (DMS) and MinIO object storage.

## Tech Stack

| Layer | Technology |
|-------|-----------|
| **Odoo Module** | Python 3.10+, Odoo 17 Enterprise (documents module) |
| **Client Service** | Go 1.25, Gin HTTP framework, System Tray (systray) |
| **Frontend** | Odoo OWL components, vanilla JS (embedded web UI) |
| **Storage** | MinIO S3-compatible object storage |
| **Communication** | JSON-RPC (Odoo standard), REST API (Go service), SSE (progress) |

## Module Structure

```
minio_odoo_project/
  documents/              # Odoo Enterprise documents module (base dependency)
  documents_minio_sync/   # Custom Odoo module - MinIO integration
  service/                # Go client service (system tray + HTTP API)
  auto_backup_ym/         # Standalone Python backup tool (Flask)
  docs/                   # Architecture & migration documentation
```

## Key Components

### 1. `documents_minio_sync` (Odoo Module)
- **Models**: `minio.config`, `minio.device`, `minio.access.log`, `minio.service.log`
- **Inherits**: `documents.document` (adds `minio_object_name`, `minio_synced`, `minio_last_sync`)
- **Controllers**: `/minio/get_config`, `/minio/api/list`, `/minio/api/download`, `/minio/api/delete`, `/minio/api/download_zip`, `/minio/sync_metadata`, `/minio/log_access`, `/minio/log_service`
- **JS Frontend**: MinIO browser, download progress bar, document inspector patch, login dialog

### 2. `service/` (Go Client Service)
- **Entry**: `cmd/minio-service/main.go`
- **Packages**: `internal/api`, `internal/auth`, `internal/config`, `internal/minioclient`, `internal/tasks`, `internal/upload`, `internal/tray`, `internal/updater`
- **Listens on**: `:9999` (configurable)
- **System tray**: Windows/macOS/Linux with systray library

## Development Commands

```bash
# Go service
cd service
go mod tidy
go run ./cmd/minio-service

# Build service
make build              # Current platform
make build-all          # Cross-compile

# Odoo (from Odoo root)
python odoo-bin -d minio --addons-path=addons -u documents_minio_sync
```

## Configuration

- **Go service**: `service/config.json` (next to executable)
- **Odoo module**: `minio.config` model (Settings > MinIO Configuration)
- **Default bucket**: `odoo-documents` / `autonsi-documents`

## Important Conventions

- Odoo module follows Odoo 17 conventions (NOT Odoo 19)
- Go service uses `zerolog` for logging, `gin` for HTTP
- MinIO URLs in Odoo are always rewritten to internal `/minio/api/download?path=...` format
- Device tracking via `client_id` (UUID) registered on first connection
- All Odoo controllers use `auth='user'` except where noted

## Security Notes

- MinIO credentials stored in `minio.config` model (not hardcoded)
- Go service authenticates to Odoo via JSON-RPC session
- CSRF disabled on some POST routes (`csrf=False`) - known technical debt
- `sudo()` used in device registration and log creation

## Memory Management (MANDATORY)

After every code change, feature addition, bug fix, or architectural update in this project, you MUST update the project memory at `~/.claude/projects/D--workspaces-projects-odoo17-minio/memory/` to preserve context for future sessions.

**What to update:**
- New models, fields, or API endpoints added
- Architectural decisions and their rationale
- Bug fixes with root cause context
- Configuration changes or new dependencies
- Integration changes between Odoo module, Go service, or MinIO

**How:**
1. Check existing memory files in the memory directory
2. Update relevant memory file or create a new one if the topic is new
3. Update `MEMORY.md` index if a new file was created

This ensures continuity across sessions and prevents re-discovery of already-known context.

## Testing

```bash
# Odoo tests
python odoo-bin -d test_db --test-enable --test-tags=documents_minio_sync --stop-after-init

# Go tests
cd service && go test ./...
```
