#!/bin/bash
# Run the service in development mode with auto-rebuild
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$(dirname "$SCRIPT_DIR")"

PORT="${1:-5555}"

cd "$SERVICE_DIR"

echo "==> Building minio-service..."
go build -o ../build/minio-service ./cmd/minio-service

echo "==> Starting on http://localhost:${PORT}"
../build/minio-service --port "$PORT" "$@"
