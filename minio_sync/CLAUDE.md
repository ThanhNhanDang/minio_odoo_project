# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**minio_sync** is a cross-platform Flutter application that provides a background file sync service for Odoo + MinIO integration. On desktop, it runs as a **system tray app** with an embedded HTTP API server (port 9999) in a separate Dart Isolate. On mobile, it's a placeholder for future background service integration.

This is one component of the larger `minio_odoo_project` — the native client that handles file uploads to MinIO object storage on behalf of the Odoo web UI.

## Tech Stack

- **Framework:** Flutter (Dart SDK >=3.3.0 <4.0.0)
- **HTTP Server:** shelf + shelf_router (runs in Isolate on desktop)
- **MinIO Client:** minio_new package
- **Desktop:** window_manager, tray_manager, screen_retriever
- **Mobile:** flutter_foreground_task, flutter_local_notifications
- **Config:** JSON file on desktop, SharedPreferences on mobile

## Development Commands

```bash
# Run in debug mode (desktop)
flutter run -d windows
flutter run -d macos
flutter run -d linux

# Run in debug mode (mobile)
flutter run -d android
flutter run -d ios

# Build release
flutter build windows
flutter build apk
flutter build ios

# Analyze code
flutter analyze

# Run tests
flutter test

# Run single test file
flutter test test/widget_test.dart

# Get dependencies
flutter pub get
```

## Architecture

### Platform-Dependent Execution

`main.dart` branches on `PlatformUtils.isDesktop`:

- **Desktop:** Initializes a transparent, borderless 360x600 window (hidden by default), spawns an HTTP server Isolate on port 9999, sets up system tray. Window shows/hides on tray icon click, auto-hides on blur.
- **Mobile:** Renders `HomeScreen` placeholder. No HTTP server — background service planned.

### Embedded HTTP API (Desktop Only)

Runs in a **separate Dart Isolate** via `Isolate.spawn(startApiServer, config)` — does not block the UI thread. Binds to `127.0.0.1:9999`.

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/upload` | POST | Queue file upload task |
| `/api/tasks` | GET | List all upload tasks |
| `/api/task/<id>` | GET | Get single task status/progress |
| `/api/auth/login` | POST | Auth stub (not implemented) |

The Odoo web frontend calls these endpoints to trigger uploads and poll progress.

### Upload Pipeline

```
POST /api/upload → UploadHandler → UploadQueue.addTask() → _processQueue()
                                                              ↓
                                          MinioService.uploadFile() (stream with progress tracking)
                                                              ↓
                                          UploadTask.updateProgress() → broadcast StreamController
                                                              ↓
                                          GET /api/task/<id> returns current percent/status
```

- `UploadQueue` processes tasks **sequentially** (FIFO)
- Progress tracked per-chunk via stream interception in `MinioService.uploadFile()`
- Tasks have lifecycle: `pending → uploading → done | error | canceled`

### Config System (Repository Pattern)

`ConfigService` selects backend at startup:
- **Desktop:** `JsonConfigRepository` — reads/writes `config.json` next to the executable
- **Mobile:** `PrefsConfigRepository` — uses SharedPreferences

Two config models: `AppConfig` (Odoo URL, DB, client ID, listen address) and `MinioConfig` (endpoint, credentials, bucket, SSL flag).

### Key Design Decisions

- **Isolate for HTTP server:** Prevents file I/O and network operations from blocking the UI thread. The server has its own `MinioService` and `UploadQueue` instances — no shared mutable state with the main isolate.
- **Localhost-only binding:** The API server binds to `127.0.0.1`, not `0.0.0.0`. Only the local machine can reach it.
- **Window auto-hide on blur:** The popup behaves like a tray popover — clicking away dismisses it automatically via `WindowListener.onWindowBlur`.
- **CORS allows all origins:** The server accepts requests from any origin (`*`) because the Odoo web UI runs on a different port.

## Relationship to Parent Project

This Flutter app replaces/complements the Go service at `../service/`. Both serve the same purpose (local HTTP API for upload operations), but this Flutter version targets cross-platform (desktop + mobile) while the Go version is desktop-only with system tray.

The Odoo module at `../documents_minio_sync/` calls `localhost:9999` API endpoints from its JavaScript frontend to trigger uploads and track progress.


