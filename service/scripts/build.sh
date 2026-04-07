#!/bin/bash
# Build for all platforms
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
SERVICE_DIR="$(dirname "$SCRIPT_DIR")"
OUTDIR="$PROJECT_DIR/build"

VERSION="${VERSION:-$(git -C "$PROJECT_DIR" describe --tags --always --dirty 2>/dev/null || echo "dev")}"
COMMIT="${COMMIT:-$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")}"
DATE="${DATE:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"
MODULE="github.com/anthropics/minio-odoo-service"
LDFLAGS="-s -w -X '${MODULE}/internal/version.Version=${VERSION}' -X '${MODULE}/internal/version.CommitSHA=${COMMIT}' -X '${MODULE}/internal/version.BuildDate=${DATE}'"

mkdir -p "$OUTDIR"
cd "$SERVICE_DIR"

build_target() {
    local GOOS=$1 GOARCH=$2 SUFFIX=$3
    echo "==> Building ${GOOS}/${GOARCH}..."
    CGO_ENABLED=0 GOOS=$GOOS GOARCH=$GOARCH go build -ldflags "$LDFLAGS" -o "$OUTDIR/minio-service-${GOOS}-${GOARCH}${SUFFIX}" ./cmd/minio-service
    echo "    -> build/minio-service-${GOOS}-${GOARCH}${SUFFIX}"
}

case "${1:-all}" in
    windows)
        build_target windows amd64 .exe
        ;;
    linux)
        build_target linux amd64 ""
        build_target linux arm64 ""
        ;;
    android)
        build_target android arm64 ""
        ;;
    current)
        echo "==> Building for current platform..."
        CGO_ENABLED=0 go build -ldflags "$LDFLAGS" -o "$OUTDIR/minio-service" ./cmd/minio-service
        echo "    -> build/minio-service"
        ;;
    all)
        build_target windows amd64 .exe
        build_target linux amd64 ""
        build_target linux arm64 ""
        build_target android arm64 ""
        ;;
    *)
        echo "Usage: $0 [windows|linux|android|current|all]"
        exit 1
        ;;
esac

echo ""
echo "Build complete! Binaries in: $OUTDIR/"
ls -la "$OUTDIR/"
