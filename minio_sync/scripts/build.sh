#!/usr/bin/env bash
set -euo pipefail

echo "============================================"
echo "  MinIO Sync - Flutter Build"
echo "============================================"

VERSION="${1:-1.0.0}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/release"

echo "[*] Version: $VERSION"
echo "[*] Project: $PROJECT_DIR"
echo ""

# Clean
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

cd "$PROJECT_DIR"

# Dependencies
echo "[1/3] Getting dependencies..."
flutter pub get

# Analyze
echo "[2/3] Analyzing code..."
flutter analyze --no-fatal-infos || true

# Detect platform and build
echo "[3/3] Building release..."
OS="$(uname -s)"
case "$OS" in
  Linux*)
    flutter build linux --release
    BUILD_OUT="$PROJECT_DIR/build/linux/x64/release/bundle"
    cp -r "$BUILD_OUT/"* "$OUTPUT_DIR/"
    cp "$BUILD_OUT/minio_sync" "$OUTPUT_DIR/minio-sync-linux-amd64"
    ;;
  Darwin*)
    flutter build macos --release
    BUILD_OUT="$PROJECT_DIR/build/macos/Build/Products/Release"
    cp -r "$BUILD_OUT/"* "$OUTPUT_DIR/"
    cp "$BUILD_OUT/minio_sync" "$OUTPUT_DIR/minio-sync-darwin-amd64" 2>/dev/null || true
    ;;
  *)
    echo "[ERROR] Unsupported platform: $OS"
    exit 1
    ;;
esac

# Config template
cat > "$OUTPUT_DIR/config.json" << EOF
{
  "minio_endpoint": "",
  "minio_access_key": "",
  "minio_secret_key": "",
  "minio_bucket": "odoo-documents",
  "odoo_url": "",
  "odoo_db": "",
  "listen_addr": ":9999",
  "update_url": "ThanhNhanDang/minio_odoo_project",
  "version": "$VERSION"
}
EOF

echo ""
echo "============================================"
echo "  BUILD COMPLETE"
echo "============================================"
ls -lh "$OUTPUT_DIR/"minio-sync-* 2>/dev/null || ls -lh "$OUTPUT_DIR/minio_sync"
echo "  Output: $OUTPUT_DIR"
echo "============================================"
