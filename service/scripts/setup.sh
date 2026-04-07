#!/bin/bash
# Setup: download dependencies and prepare for build
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$(dirname "$SCRIPT_DIR")"

echo "==> Checking Go installation..."
if ! command -v go &> /dev/null; then
    echo "ERROR: Go is not installed. Download from https://go.dev/dl/"
    exit 1
fi

echo "==> Go version: $(go version)"

echo "==> Downloading dependencies..."
cd "$SERVICE_DIR"
go mod tidy

echo "==> Verifying build..."
go build ./...

echo ""
echo "Setup complete! Run './scripts/dev.sh' to start development server."
