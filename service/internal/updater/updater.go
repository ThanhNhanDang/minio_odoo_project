package updater

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/rs/zerolog/log"
)

// ghRelease is the subset of the GitHub Releases API response we need.
type ghRelease struct {
	TagName string    `json:"tag_name"`
	Assets  []ghAsset `json:"assets"`
}

// ghAsset represents a single file attached to a GitHub release.
type ghAsset struct {
	Name               string `json:"name"`
	BrowserDownloadURL string `json:"browser_download_url"`
}

// UpdateInfo describes an available update.
type UpdateInfo struct {
	Version     string `json:"version"`
	DownloadURL string `json:"download_url"`
	Checksum    string `json:"checksum"`
	Available   bool   `json:"available"`
}

// Updater checks for and applies binary updates from GitHub Releases.
type Updater struct {
	currentVersion string
	repo           string // "owner/repo" format
	token          string // GitHub personal access token (for private repos)
}

// New creates an Updater. repo must be in "owner/repo" format
// (e.g. "ThanhNhanDang/minio_odoo_project"). token is optional —
// only required for private repositories.
func New(version, repo, token string) *Updater {
	return &Updater{
		currentVersion: version,
		repo:           repo,
		token:          token,
	}
}

// assetName returns the expected binary name for the current platform.
// Matches the naming convention from build.sh:
//
//	minio-service-{GOOS}-{GOARCH}[.exe]
func assetName() string {
	name := fmt.Sprintf("minio-service-%s-%s", runtime.GOOS, runtime.GOARCH)
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	return name
}

// CheckForUpdate calls the GitHub Releases API for the latest release,
// then looks for an asset matching the current OS/architecture.
// If no matching asset exists, Available is false — this means the release
// does not target this platform.
func (u *Updater) CheckForUpdate(ctx context.Context) (*UpdateInfo, error) {
	endpoint := fmt.Sprintf("https://api.github.com/repos/%s/releases/latest", u.repo)

	reqCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, fmt.Errorf("updater: build request: %w", err)
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "minio-service/"+u.currentVersion)
	if u.token != "" {
		req.Header.Set("Authorization", "Bearer "+u.token)
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("updater: fetch %s: %w", endpoint, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("updater: GitHub API returned HTTP %d", resp.StatusCode)
	}

	var release ghRelease
	if err := json.NewDecoder(resp.Body).Decode(&release); err != nil {
		return nil, fmt.Errorf("updater: decode release JSON: %w", err)
	}

	// Strip leading "v" from tag (v1.2.0 → 1.2.0).
	latestVersion := strings.TrimPrefix(release.TagName, "v")

	info := &UpdateInfo{
		Version: latestVersion,
	}

	// Find the asset matching this platform.
	want := assetName()
	for _, a := range release.Assets {
		if a.Name == want {
			info.DownloadURL = a.BrowserDownloadURL
			break
		}
	}

	// Try to find checksum from checksums.txt asset.
	for _, a := range release.Assets {
		if a.Name == "checksums.txt" {
			if cs, err := fetchChecksum(ctx, a.BrowserDownloadURL, want); err == nil {
				info.Checksum = cs
			}
			break
		}
	}

	// Available only if: version differs AND there is a binary for this platform.
	info.Available = latestVersion != "" &&
		latestVersion != u.currentVersion &&
		info.DownloadURL != ""

	log.Info().
		Str("current", u.currentVersion).
		Str("latest", latestVersion).
		Str("platform", fmt.Sprintf("%s/%s", runtime.GOOS, runtime.GOARCH)).
		Bool("asset_found", info.DownloadURL != "").
		Bool("available", info.Available).
		Msg("update check complete")

	return info, nil
}

// fetchChecksum downloads checksums.txt and extracts the SHA-256 for the
// given filename. Expected format per line: "<hex>  <filename>".
func fetchChecksum(ctx context.Context, url, filename string) (string, error) {
	reqCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}

	for _, line := range strings.Split(string(body), "\n") {
		// Format: "abc123def...  minio-service-windows-amd64.exe"
		parts := strings.Fields(line)
		if len(parts) == 2 && parts[1] == filename {
			return parts[0], nil
		}
	}
	return "", fmt.Errorf("checksum not found for %s", filename)
}

// Apply downloads the new binary, verifies its SHA-256 checksum, then performs
// an in-place replacement of the running executable. A process restart is
// required to activate the new binary.
func (u *Updater) Apply(ctx context.Context, info *UpdateInfo) error {
	if info == nil || info.DownloadURL == "" {
		return fmt.Errorf("updater: no download URL in update info")
	}

	// Determine the path of the running executable.
	exePath, err := os.Executable()
	if err != nil {
		return fmt.Errorf("updater: resolve executable path: %w", err)
	}

	// Download to a temp file in the same directory so rename is atomic
	// and works across drives on Windows.
	exeDir := filepath.Dir(exePath)
	tmpFile, err := os.CreateTemp(exeDir, "minio-service-update-*.tmp")
	if err != nil {
		return fmt.Errorf("updater: create temp file: %w", err)
	}
	tmpPath := tmpFile.Name()

	defer func() {
		// Best-effort cleanup of temp file on failure.
		if _, statErr := os.Stat(tmpPath); statErr == nil {
			_ = os.Remove(tmpPath)
		}
	}()

	log.Info().Str("url", info.DownloadURL).Str("tmp", tmpPath).Msg("downloading update")

	if err := u.download(ctx, info.DownloadURL, tmpFile); err != nil {
		tmpFile.Close()
		return err
	}
	tmpFile.Close()

	// Verify SHA-256 checksum if provided.
	if info.Checksum != "" {
		if err := verifyChecksum(tmpPath, info.Checksum); err != nil {
			return err
		}
		log.Info().Msg("checksum verified")
	}

	// Rename current exe to .old, then move new binary into place.
	oldPath := exePath + ".old"
	if err := os.Rename(exePath, oldPath); err != nil {
		return fmt.Errorf("updater: rename current exe to .old: %w", err)
	}

	if err := os.Rename(tmpPath, exePath); err != nil {
		// Attempt to restore the old binary before returning.
		_ = os.Rename(oldPath, exePath)
		return fmt.Errorf("updater: rename new binary to exe path: %w", err)
	}

	log.Info().
		Str("version", info.Version).
		Str("path", exePath).
		Msg("update applied — restart required to activate new version")

	return nil
}

// download streams the response body of url into dst.
func (u *Updater) download(ctx context.Context, url string, dst io.Writer) error {
	reqCtx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()

	req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, url, nil)
	if err != nil {
		return fmt.Errorf("updater: build download request: %w", err)
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("updater: download %s: %w", url, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		return fmt.Errorf("updater: download returned HTTP %d", resp.StatusCode)
	}

	if _, err := io.Copy(dst, resp.Body); err != nil {
		return fmt.Errorf("updater: write download: %w", err)
	}
	return nil
}

// verifyChecksum computes the SHA-256 of the file at path and compares it to
// the expected hex-encoded digest.
func verifyChecksum(path, expected string) error {
	f, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("updater: open for checksum: %w", err)
	}
	defer f.Close()

	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return fmt.Errorf("updater: compute checksum: %w", err)
	}

	got := hex.EncodeToString(h.Sum(nil))
	if !strings.EqualFold(got, expected) {
		return fmt.Errorf("updater: checksum mismatch: got %s, want %s", got, expected)
	}
	return nil
}
