VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")
COMMIT  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
DATE    ?= $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")
MODULE  := github.com/anthropics/minio-odoo-service
LDFLAGS := -s -w \
	-X '$(MODULE)/internal/version.Version=$(VERSION)' \
	-X '$(MODULE)/internal/version.CommitSHA=$(COMMIT)' \
	-X '$(MODULE)/internal/version.BuildDate=$(DATE)'

BINARY  := minio-service
OUTDIR  := build

.PHONY: all build clean dev tidy test
.PHONY: build-windows build-linux build-linux-arm64 build-android

all: build

tidy:
	cd service && go mod tidy

test:
	cd service && go test ./...

dev:
	cd service && go run ./cmd/minio-service

build:
	cd service && CGO_ENABLED=0 go build -ldflags "$(LDFLAGS)" -o ../$(OUTDIR)/$(BINARY)$(shell go env GOEXE) ./cmd/minio-service

build-windows:
	cd service && GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -ldflags "$(LDFLAGS)" -o ../$(OUTDIR)/$(BINARY)-windows-amd64.exe ./cmd/minio-service

build-linux:
	cd service && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -ldflags "$(LDFLAGS)" -o ../$(OUTDIR)/$(BINARY)-linux-amd64 ./cmd/minio-service

build-linux-arm64:
	cd service && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -ldflags "$(LDFLAGS)" -o ../$(OUTDIR)/$(BINARY)-linux-arm64 ./cmd/minio-service

build-android:
	cd service && GOOS=android GOARCH=arm64 CGO_ENABLED=0 go build -ldflags "$(LDFLAGS)" -o ../$(OUTDIR)/$(BINARY)-android-arm64 ./cmd/minio-service

build-all: build-windows build-linux build-linux-arm64 build-android

clean:
	rm -rf $(OUTDIR)
