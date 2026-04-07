#!/usr/bin/env bash
set -euo pipefail

echo "============================================"
echo "  MinIO Sync - Setup"
echo "============================================"
echo ""

# Check Flutter
echo "[1/2] Checking Flutter installation..."
if ! command -v flutter &>/dev/null; then
    echo "[ERROR] Flutter not found in PATH"
    echo "        Install: https://flutter.dev/docs/get-started/install"
    exit 1
fi
flutter --version
echo "[OK] Flutter found"

# Get dependencies
echo "[2/2] Getting dependencies..."
cd "$(dirname "$0")/.."
flutter pub get

echo ""
echo "============================================"
echo "  SETUP COMPLETE"
echo "============================================"
echo "  Run 'scripts/dev.sh' to start development"
echo "  Run 'scripts/build.sh' to build release"
echo "============================================"
