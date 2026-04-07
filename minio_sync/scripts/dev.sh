#!/usr/bin/env bash
set -euo pipefail

echo "============================================"
echo "  MinIO Sync - Dev Mode"
echo "============================================"
echo ""

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

OS="$(uname -s)"
case "$OS" in
  Linux*)  DEVICE="linux" ;;
  Darwin*) DEVICE="macos" ;;
  *)       DEVICE="linux" ;;
esac

echo "[*] Running in debug mode on $DEVICE..."
echo "[*] Press Ctrl+C to stop, 'r' for hot reload, 'R' for hot restart"
echo ""

flutter run -d "$DEVICE"
