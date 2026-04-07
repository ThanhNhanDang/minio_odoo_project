package upload

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/rs/zerolog/log"

	"minio-service/internal/config"
	"minio-service/internal/minioclient"
	"minio-service/internal/tasks"
)

// Engine handles file uploads to MinIO and Odoo metadata sync.
type Engine struct {
	minio  *minioclient.Client
	tasks  *tasks.Manager
	config *config.Config
}

// New creates a new upload engine.
func New(mc *minioclient.Client, tm *tasks.Manager, cfg *config.Config) *Engine {
	return &Engine{
		minio:  mc,
		tasks:  tm,
		config: cfg,
	}
}

// Run executes the upload. paths are local filesystem paths (files or directories).
// remotePath is the MinIO prefix. taskID tracks progress.
// cookie is an optional Odoo session cookie forwarded to sync_metadata.
// odooFolderID is the Odoo documents.folder ID to create documents in.
func (e *Engine) Run(ctx context.Context, taskID string, paths []string, remotePath string, cookie string, odooFolderID int) error {
	cancelCh := e.tasks.CancelChan(taskID)

	// --- Phase 1: collect all files to upload with their relative paths ---
	type fileEntry struct {
		localPath string
		relPath   string // relative path from the uploaded root (preserves folder structure)
	}
	var files []fileEntry
	for _, p := range paths {
		info, err := os.Stat(p)
		if err != nil {
			log.Warn().Str("task", taskID).Str("path", p).Err(err).Msg("stat failed, skipping path")
			continue
		}
		if info.IsDir() {
			dirName := filepath.Base(p) // top-level folder name
			if err := filepath.Walk(p, func(fp string, fi os.FileInfo, werr error) error {
				if werr != nil {
					log.Warn().Str("task", taskID).Str("path", fp).Err(werr).Msg("walk error, skipping")
					return nil
				}
				if !fi.IsDir() {
					// Compute relative path from the parent of the uploaded dir.
					// e.g. uploaded dir = C:\Docs\Reports => rel = Reports/Q1/sales.pdf
					rel, _ := filepath.Rel(filepath.Dir(p), fp)
					relForward := filepath.ToSlash(rel)
					// If Rel fails, fallback to dirName/basename
					if relForward == "" || relForward == "." {
						relForward = dirName + "/" + filepath.Base(fp)
					}
					files = append(files, fileEntry{localPath: fp, relPath: relForward})
				}
				return nil
			}); err != nil {
				log.Error().Str("task", taskID).Str("dir", p).Err(err).Msg("walk failed")
			}
		} else {
			files = append(files, fileEntry{localPath: p, relPath: filepath.Base(p)})
		}
	}

	total := len(files)
	if total == 0 {
		log.Info().Str("task", taskID).Msg("no files to upload")
		e.tasks.UpdateProgress(taskID, 100, "no files found")
		return nil
	}

	// Calculate total bytes for per-byte progress tracking
	var totalBytes int64
	for _, fe := range files {
		if fi, err := os.Stat(fe.localPath); err == nil {
			totalBytes += fi.Size()
		}
	}

	log.Info().Str("task", taskID).Int("total", total).Int64("total_bytes", totalBytes).Str("remote", remotePath).Msg("starting upload")

	// --- Phase 2: upload each file ---
	type uploadedFile struct {
		objectName  string
		size        int64
		contentType string
		relPath     string
	}
	uploaded := make([]uploadedFile, 0, total)

	prefix := strings.TrimSuffix(remotePath, "/")
	var bytesUploaded int64

	// onProgress is called by the progressReader as bytes are streamed to MinIO
	onProgress := func(n int64) {
		bytesUploaded += n
		var pct float64
		if totalBytes > 0 {
			pct = math.Floor(float64(bytesUploaded) / float64(totalBytes) * 100)
			if pct > 100 {
				pct = 100
			}
		}
		e.tasks.UpdateProgress(taskID, pct,
			fmt.Sprintf("%s / %s", formatBytes(bytesUploaded), formatBytes(totalBytes)))
	}

	for i, fe := range files {
		// Check for cancellation before each file.
		select {
		case <-cancelCh:
			log.Info().Str("task", taskID).Msg("upload canceled")
			return fmt.Errorf("upload canceled")
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		objectName, size, contentType, err := e.uploadFileWithProgress(ctx, taskID, fe.localPath, prefix, fe.relPath, onProgress)
		if err != nil {
			log.Error().Str("task", taskID).Str("file", fe.localPath).Err(err).Msg("upload failed, continuing")
			// Account for skipped file size so progress doesn't jump backwards
			if fi, serr := os.Stat(fe.localPath); serr == nil {
				bytesUploaded += fi.Size()
			}
			e.tasks.UpdateProgress(taskID, math.Floor(float64(bytesUploaded)/float64(totalBytes)*100),
				fmt.Sprintf("error on %s", filepath.Base(fe.localPath)))
			continue
		}

		uploaded = append(uploaded, uploadedFile{objectName: objectName, size: size, contentType: contentType, relPath: fe.relPath})
		e.tasks.UpdateProgress(taskID, math.Floor(float64(bytesUploaded)/float64(totalBytes)*100),
			fmt.Sprintf("uploaded %d/%d: %s", i+1, total, filepath.Base(fe.localPath)))
	}

	// Store uploaded object paths on the task so the JS frontend can create
	// documents.document records (JS has a valid Odoo session, Go may not).
	uploadedPaths := make([]string, 0, len(uploaded))
	for _, uf := range uploaded {
		uploadedPaths = append(uploadedPaths, uf.objectName)
	}
	if t := e.tasks.Get(taskID); t != nil {
		t.UploadedPaths = uploadedPaths
	}

	// --- Phase 3: best-effort sync metadata to Odoo (may fail if no session) ---
	cfg := e.config.Snapshot()
	if cfg.OdooURL != "" && cookie != "" {
		for _, uf := range uploaded {
			select {
			case <-cancelCh:
				log.Info().Str("task", taskID).Msg("sync canceled")
				return fmt.Errorf("upload canceled during sync")
			case <-ctx.Done():
				return ctx.Err()
			default:
			}

			if err := e.syncMetadata(ctx, cfg.OdooURL, uf.objectName, uf.size, uf.contentType, odooFolderID, cookie, uf.relPath); err != nil {
				log.Error().Str("task", taskID).Str("object", uf.objectName).Err(err).Msg("odoo sync failed (JS will handle)")
			}
		}
	} else {
		if cookie == "" {
			log.Info().Str("task", taskID).Msg("no Odoo session — skipping server-side sync, JS frontend will create documents")
		} else {
			log.Warn().Str("task", taskID).Msg("odoo_url not configured, skipping metadata sync")
		}
	}

	log.Info().Str("task", taskID).Int("uploaded", len(uploaded)).Int("total", total).Strs("paths", uploadedPaths).Msg("upload run complete")

	// If no files were successfully uploaded, report as error
	if len(uploaded) == 0 && total > 0 {
		return fmt.Errorf("all %d file(s) failed to upload", total)
	}
	// If some files failed, report partial failure
	failed := total - len(uploaded)
	if failed > 0 {
		return fmt.Errorf("%d of %d file(s) failed to upload", failed, total)
	}
	return nil
}

// progressReader wraps an io.Reader and calls onProgress with the number of
// bytes read on each Read call. This enables per-byte upload progress tracking.
type progressReader struct {
	reader     io.Reader
	onProgress func(n int64)
}

func (pr *progressReader) Read(p []byte) (int, error) {
	n, err := pr.reader.Read(p)
	if n > 0 {
		pr.onProgress(int64(n))
	}
	return n, err
}

// uploadFileWithProgress opens and streams a single file to MinIO with byte-level
// progress reporting via the onProgress callback.
func (e *Engine) uploadFileWithProgress(ctx context.Context, taskID, localPath, prefix, relPath string, onProgress func(int64)) (string, int64, string, error) {
	f, err := os.Open(localPath)
	if err != nil {
		return "", 0, "", fmt.Errorf("open %s: %w", localPath, err)
	}
	defer f.Close()

	fi, err := f.Stat()
	if err != nil {
		return "", 0, "", fmt.Errorf("stat %s: %w", localPath, err)
	}

	objectName := buildObjectName(prefix, relPath)
	contentType := detectContentType(localPath)

	log.Debug().
		Str("task", taskID).
		Str("local", localPath).
		Str("object", objectName).
		Int64("size", fi.Size()).
		Msg("uploading file")

	reader := &progressReader{reader: f, onProgress: onProgress}
	if err := e.minio.Upload(ctx, objectName, reader, fi.Size(), contentType); err != nil {
		return "", 0, "", fmt.Errorf("minio upload %s: %w", objectName, err)
	}

	return objectName, fi.Size(), contentType, nil
}

// formatBytes returns a human-readable byte count (e.g. "1.5 GB").
func formatBytes(b int64) string {
	const unit = 1024
	if b < unit {
		return fmt.Sprintf("%d B", b)
	}
	div, exp := int64(unit), 0
	for n := b / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %s", float64(b)/float64(div), []string{"KB", "MB", "GB", "TB"}[exp])
}

// buildObjectName constructs the MinIO object key from a prefix and a relative path.
// It preserves folder structure (e.g. prefix + "Reports/Q1/sales.pdf").
func buildObjectName(prefix, relPath string) string {
	// Normalize to forward slashes for MinIO
	rel := strings.ReplaceAll(relPath, "\\", "/")
	if prefix == "" {
		return rel
	}
	return prefix + "/" + rel
}

// detectContentType returns a best-effort MIME type from the file extension.
func detectContentType(path string) string {
	ext := strings.ToLower(filepath.Ext(path))
	switch ext {
	case ".pdf":
		return "application/pdf"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".png":
		return "image/png"
	case ".gif":
		return "image/gif"
	case ".svg":
		return "image/svg+xml"
	case ".mp4":
		return "video/mp4"
	case ".mp3":
		return "audio/mpeg"
	case ".json":
		return "application/json"
	case ".xml":
		return "application/xml"
	case ".txt":
		return "text/plain"
	case ".html", ".htm":
		return "text/html"
	case ".csv":
		return "text/csv"
	case ".zip":
		return "application/zip"
	default:
		return "application/octet-stream"
	}
}

// jsonRPCBody is the Odoo JSON-RPC envelope.
type jsonRPCBody struct {
	JSONRPC string         `json:"jsonrpc"`
	Method  string         `json:"method"`
	Params  map[string]any `json:"params"`
}

// syncMetadata posts file metadata to Odoo's /minio/sync_metadata endpoint.
// Sends minio_path, size, mimetype, filename, and odoo_folder_id so Odoo can
// create a documents.document record if one doesn't exist yet.
func (e *Engine) syncMetadata(ctx context.Context, odooURL, objectName string, size int64, contentType string, odooFolderID int, cookie string, relPath string) error {
	// Extract filename from the object path.
	parts := strings.Split(objectName, "/")
	filename := parts[len(parts)-1]

	params := map[string]any{
		"minio_path": objectName,
		"size":       size,
		"mimetype":   contentType,
		"filename":   filename,
	}
	if odooFolderID > 0 {
		params["odoo_folder_id"] = odooFolderID
	}
	if relPath != "" {
		params["rel_path"] = relPath
	}

	hasCookie := cookie != ""
	log.Info().
		Str("object", objectName).
		Str("filename", filename).
		Str("mimetype", contentType).
		Int64("size", size).
		Int("odoo_folder_id", odooFolderID).
		Bool("has_cookie", hasCookie).
		Str("odoo_url", odooURL).
		Msg("syncMetadata: sending to Odoo")

	body := jsonRPCBody{
		JSONRPC: "2.0",
		Method:  "call",
		Params:  params,
	}

	data, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("marshal sync body: %w", err)
	}

	endpoint := strings.TrimSuffix(odooURL, "/") + "/minio/sync_metadata"

	reqCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(reqCtx, http.MethodPost, endpoint, bytes.NewReader(data))
	if err != nil {
		return fmt.Errorf("build sync request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if cookie != "" {
		req.Header.Set("Cookie", cookie)
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		log.Error().Err(err).Str("endpoint", endpoint).Msg("syncMetadata: request failed")
		return fmt.Errorf("sync request to %s: %w", endpoint, err)
	}
	defer resp.Body.Close()

	// Read response body for debugging
	respBody, _ := io.ReadAll(resp.Body)

	if resp.StatusCode >= 400 {
		log.Error().
			Int("http_status", resp.StatusCode).
			Str("object", objectName).
			Str("response", string(respBody)).
			Msg("syncMetadata: Odoo returned error")
		return fmt.Errorf("sync returned HTTP %d for %s", resp.StatusCode, objectName)
	}

	log.Info().
		Int("http_status", resp.StatusCode).
		Str("object", objectName).
		Str("response", string(respBody)).
		Msg("syncMetadata: Odoo response")

	return nil
}
