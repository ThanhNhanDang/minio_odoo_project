# MinIO Sync Client (Flutter)

A cross-platform Flutter application that acts as a background file sync service for the Odoo + MinIO integration.

## Overview

This application runs as a system tray app on desktop environments (Windows, macOS, Linux). It exposes a local HTTP API (port 9999) that the Odoo browser frontend communicates with to orchestrate file uploads directly to MinIO, bypassing the Odoo server.

## Features

- **System Tray Integration**: Quietly runs in the background.
- **Isolate HTTP Server**: Provides a `/api/` REST interface for Odoo.
- **Upload Queue**: Sequentially uploads files with progress tracking.
- **Cross-Platform**: Designed to compile natively for all desktop platforms.

## Development

```bash
# Get dependencies
flutter pub get

# Run on windows
flutter run -d windows

# Build for release
flutter build windows
```

## Giải đáp thắc mắc: Triển khai ứng dụng trên Windows (Installer)

Bạn có để lại câu hỏi: *"chỉ cần đem thư mục Release qua máy khác là dược à, không có install builder để người ta cài lên máy à"*.

**Trường hợp 1: Chạy Portable (Không cần cài đặt)**
Đúng, bạn chỉ cần nén toàn bộ thư mục `build\windows\x64\runner\Release` thành file ZIP. Người dùng mang sang máy khác, giải nén và chạy trực tiếp file `minio_sync.exe` là được (không cần cài đặt gì thêm). Thư mục này đã bao gồm tất cả các thư viện `.dll` cần thiết của hệ sinh thái Flutter / Windows.

**Trường hợp 2: Đóng gói thành Installer (Khuyên dùng)**
Nếu bạn muốn tạo một bộ cài đặt chuyên nghiệp (`.exe` hoặc `.msi`) để:
1. Tự động thêm biểu tượng ra Desktop.
2. Tạo menu trong Start hoặc Uninstaller trong Control Panel.
3. Cho phép ứng dụng tự chạy ngầm cùng lúc với quá trình Windows khởi động (Startup).

Khuyến nghị bạn nên dùng công cụ **Inno Setup** (miễn phí) hoặc tích hợp sẵn thư viện `innosetup` vào Flutter.
Bạn có thể viết một script `.iss` đơn giản trỏ đến thư mục `Release` để tạo file cài.

Ví dụ tham khảo thư viện hỗ trợ tự tạo MSIX/EXE installer:
```bash
flutter pub add dev:flutter_windows_installer
```