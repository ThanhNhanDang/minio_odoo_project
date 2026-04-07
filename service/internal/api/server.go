package api

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"strings"

	"github.com/gin-contrib/cors"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/rs/zerolog/log"

	"minio-service/internal/auth"
	"minio-service/internal/config"
	"minio-service/internal/dialog"
	"minio-service/internal/minioclient"
	"minio-service/internal/tasks"
	"minio-service/internal/updater"
	"minio-service/internal/upload"
	"minio-service/web"
)

// Server is the HTTP API server.
type Server struct {
	router  *gin.Engine
	config  *config.Config
	minio   *minioclient.Client
	tasks   *tasks.Manager
	upload  *upload.Engine
	auth    *auth.Manager
	updater *updater.Updater
}

// New creates a new Server wired with the provided dependencies.
func New(cfg *config.Config, mc *minioclient.Client, tm *tasks.Manager, am *auth.Manager) *Server {
	s := &Server{
		config: cfg,
		minio:  mc,
		tasks:  tm,
		auth:   am,
	}
	s.router = gin.Default()
	s.setupCORS()
	s.registerRoutes()
	return s
}

// SetUploadEngine wires the upload engine after construction.
func (s *Server) SetUploadEngine(ue *upload.Engine) {
	s.upload = ue
}

// SetUpdater wires the updater after construction.
func (s *Server) SetUpdater(u *updater.Updater) {
	s.updater = u
}

// SetMinIOClient updates the MinIO client (e.g. after config change).
func (s *Server) SetMinIOClient(mc *minioclient.Client) {
	s.minio = mc
}

// ReconnectMinIO attempts to create a new MinIO client and upload engine from current config.
func (s *Server) ReconnectMinIO() error {
	snap := s.config.Snapshot()
	if snap.MinioEndpoint == "" {
		return fmt.Errorf("minio_endpoint not configured")
	}
	mc, err := minioclient.New(snap.MinioEndpoint, snap.MinioAccessKey, snap.MinioSecretKey, snap.MinioBucket, snap.MinioSecure)
	if err != nil {
		return err
	}
	s.minio = mc
	s.upload = upload.New(mc, s.tasks, s.config)
	return nil
}

// Router returns the underlying Gin engine (useful for testing).
func (s *Server) Router() *gin.Engine {
	return s.router
}

// Start begins listening on the address from config (default :9999).
func (s *Server) Start() error {
	addr := s.config.ListenAddr
	if addr == "" {
		addr = ":9999"
	}
	return s.router.Run(addr)
}

// setupCORS configures permissive CORS for the Odoo JS frontend.
func (s *Server) setupCORS() {
	s.router.Use(cors.New(cors.Config{
		AllowAllOrigins:  true,
		AllowMethods:     []string{"GET", "POST", "DELETE", "OPTIONS"},
		AllowHeaders:     []string{"Content-Type", "Authorization"},
		AllowCredentials: true,
	}))
}

// registerRoutes wires all API routes.
func (s *Server) registerRoutes() {
	// --- Static file serving (embedded web UI) ---
	staticSub, _ := fs.Sub(web.StaticFS, "static")
	fileServer := http.FileServer(http.FS(staticSub))

	// Auth middleware: protect all routes except login page and auth endpoints.
	s.router.Use(func(c *gin.Context) {
		path := c.Request.URL.Path

		// Allow: login page, auth endpoints, static assets (css/js/fonts)
		if path == "/login.html" ||
			strings.HasPrefix(path, "/api/auth/") ||
			strings.HasPrefix(path, "/css/") ||
			strings.HasPrefix(path, "/js/") ||
			strings.HasPrefix(path, "/fonts/") {
			c.Next()
			return
		}

		// If not authenticated, redirect to login page
		if !s.auth.IsAuthenticated() {
			if strings.HasPrefix(path, "/api/") {
				c.JSON(http.StatusUnauthorized, gin.H{"error": "not authenticated"})
				c.Abort()
				return
			}
			c.Redirect(http.StatusFound, "/login.html")
			c.Abort()
			return
		}

		c.Next()
	})

	// Serve index.html at root
	s.router.GET("/", func(c *gin.Context) {
		c.FileFromFS("index.html", http.FS(staticSub))
	})

	// Serve login.html
	s.router.GET("/login.html", func(c *gin.Context) {
		c.FileFromFS("login.html", http.FS(staticSub))
	})

	// Serve static assets (css, js, fonts, images)
	s.router.NoRoute(func(c *gin.Context) {
		fileServer.ServeHTTP(c.Writer, c.Request)
	})

	api := s.router.Group("/api")

	// Upload & task management
	api.POST("/upload", s.handleUpload)
	api.GET("/upload/progress/:taskId", s.handleUploadProgress)
	api.GET("/tasks", s.handleListTasks)
	api.GET("/task/:id", s.handleGetTask)
	api.DELETE("/task/:id", s.handleDeleteTask)
	api.POST("/task/:id/cancel", s.handleCancelTask)

	// Auth (stub — wired in U7)
	api.POST("/auth/login", s.handleAuthLogin)
	api.POST("/auth/logout", s.handleAuthLogout)
	api.GET("/auth/status", s.handleAuthStatus)

	// Config & system
	api.POST("/config/auto_set", s.handleConfigAutoSet)
	api.GET("/system/status", s.handleSystemStatus)
	api.GET("/system/update_check", s.handleUpdateCheck)
	api.POST("/system/update", s.handleApplyUpdate)
	api.GET("/bucket", s.handleBucket)

	// File operations
	api.GET("/list", s.handleList)
	api.POST("/delete", s.handleDelete)
	api.POST("/pick_sync", s.handlePickSync)
	api.POST("/download_async", s.handleDownloadAsync)
}

// ensureMinIO tries to reconnect if not connected. Returns true if ready.
func (s *Server) ensureMinIO() bool {
	if s.upload != nil && s.minio != nil {
		return true
	}
	// Attempt lazy reconnection from current config
	return s.ReconnectMinIO() == nil
}

// resolveOdooCookie returns the best available Odoo session cookie.
// Priority: Go service's own session > browser-forwarded session.
func (s *Server) resolveOdooCookie(browserSession string) string {
	if cookie := s.auth.SessionCookie(); cookie != "" {
		log.Info().Str("source", "go_auth").Msg("resolveOdooCookie: using Go service session")
		return cookie
	}
	if browserSession != "" {
		log.Info().Str("source", "browser").Int("session_len", len(browserSession)).Msg("resolveOdooCookie: using browser session")
		return "session_id=" + browserSession
	}
	log.Warn().Msg("resolveOdooCookie: NO session available — Odoo sync will fail")
	return ""
}

// ---------------------------------------------------------------------------
// Upload & task handlers
// ---------------------------------------------------------------------------

type uploadRequest struct {
	Paths        []string `json:"paths"`
	Path         string   `json:"path"`
	TaskID       string   `json:"task_id"`
	OdooFolderID int      `json:"odoo_folder_id"`
	Type         string   `json:"type"`
	TaskName     string   `json:"task_name"`
	OdooSession  string   `json:"odoo_session"`
}

func (s *Server) handleUpload(c *gin.Context) {
	if !s.ensureMinIO() {
		c.JSON(http.StatusServiceUnavailable, gin.H{"success": false, "error": "MinIO not connected. Please configure minio_endpoint, minio_access_key, minio_secret_key in config.json and restart the service."})
		return
	}

	var req uploadRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": fmt.Sprintf("invalid request: %s", err.Error())})
		return
	}

	taskID := req.TaskID
	if taskID == "" {
		taskID = uuid.New().String()
	}

	paths := req.Paths
	if len(paths) == 0 && req.Path != "" {
		paths = []string{req.Path}
	}

	taskName := req.TaskName
	if taskName == "" {
		taskName = fmt.Sprintf("upload %d file(s)", len(paths))
	}

	t := s.tasks.Create(taskID, taskName)
	t.RemotePath = req.Path
	t.OdooFolderID = req.OdooFolderID
	t.Type = req.Type
	if len(paths) > 0 {
		t.Path = paths[0]
	}

	cookie := s.resolveOdooCookie(req.OdooSession)
	ue := s.upload

	go func() {
		err := ue.Run(context.Background(), taskID, paths, req.Path, cookie, req.OdooFolderID)
		if task := s.tasks.Get(taskID); task != nil {
			task.RemotePath = req.Path
		}
		s.tasks.Complete(taskID, err)
	}()

	c.JSON(http.StatusOK, gin.H{"success": true, "task_id": taskID})
}

func (s *Server) handleUploadProgress(c *gin.Context) {
	taskID := c.Param("taskId")

	c.Header("Content-Type", "text/event-stream")
	c.Header("Cache-Control", "no-cache")
	c.Header("Connection", "keep-alive")
	c.Header("X-Accel-Buffering", "no")

	ch := s.tasks.Subscribe(taskID)

	c.Stream(func(w io.Writer) bool {
		evt, ok := <-ch
		if !ok {
			return false
		}

		data, err := json.Marshal(map[string]any{
			"percent": evt.Percent,
			"status":  evt.Status,
			"info":    evt.Info,
		})
		if err != nil {
			return false
		}

		fmt.Fprintf(w, "data: %s\n\n", data)
		return true
	})
}

func (s *Server) handleListTasks(c *gin.Context) {
	list := s.tasks.List()
	if list == nil {
		list = []*tasks.Task{}
	}
	c.JSON(http.StatusOK, list)
}

func (s *Server) handleGetTask(c *gin.Context) {
	id := c.Param("id")
	t := s.tasks.Get(id)
	if t == nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "task not found"})
		return
	}
	c.JSON(http.StatusOK, t)
}

func (s *Server) handleDeleteTask(c *gin.Context) {
	id := c.Param("id")
	s.tasks.Delete(id)
	c.JSON(http.StatusOK, gin.H{"success": true})
}

func (s *Server) handleCancelTask(c *gin.Context) {
	id := c.Param("id")
	s.tasks.Cancel(id)
	c.JSON(http.StatusOK, gin.H{"success": true})
}

// ---------------------------------------------------------------------------
// Auth handlers (stubs — wired in U7)
// ---------------------------------------------------------------------------

type loginRequest struct {
	URL      string `json:"url"`
	DB       string `json:"db"`
	Username string `json:"username"`
	Password string `json:"password"`
}

func (s *Server) handleAuthLogin(c *gin.Context) {
	var req loginRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": fmt.Sprintf("invalid request: %s", err.Error())})
		return
	}

	if err := s.auth.Login(req.URL, req.DB, req.Username, req.Password); err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"success": false, "error": err.Error()})
		return
	}

	// Update config with Odoo URL/DB
	_ = s.config.Update(func(cfg *config.Config) {
		cfg.OdooURL = req.URL
		cfg.OdooDB = req.DB
	})

	// Auto-provision: fetch MinIO config from Odoo on first login
	snap := s.config.Snapshot()
	provisioned := false
	if snap.MinioEndpoint == "" || snap.MinioAccessKey == "" {
		mc, err := s.auth.FetchMinioConfig(snap.ClientID, snap.Hostname)
		if err != nil {
			log.Warn().Err(err).Msg("auto-provision: failed to fetch MinIO config from Odoo")
		} else if mc.Endpoint != "" {
			_ = s.config.Update(func(cfg *config.Config) {
				cfg.MinioEndpoint = mc.Endpoint
				cfg.MinioAccessKey = mc.AccessKey
				cfg.MinioSecretKey = mc.SecretKey
				if mc.Bucket != "" {
					cfg.MinioBucket = mc.Bucket
				}
			})
			log.Info().
				Str("endpoint", mc.Endpoint).
				Str("bucket", mc.Bucket).
				Msg("auto-provision: MinIO config loaded from Odoo")
			provisioned = true
		}
	}

	// Reconnect MinIO if provisioned or if not yet connected
	if provisioned || s.minio == nil {
		if err := s.ReconnectMinIO(); err != nil {
			log.Warn().Err(err).Msg("auto-provision: MinIO reconnect failed")
		} else {
			log.Info().Msg("auto-provision: MinIO connected successfully")
		}
	}

	c.JSON(http.StatusOK, gin.H{"success": true, "provisioned": provisioned})
}

func (s *Server) handleAuthLogout(c *gin.Context) {
	s.auth.Logout()
	c.JSON(http.StatusOK, gin.H{"success": true})
}

func (s *Server) handleAuthStatus(c *gin.Context) {
	c.JSON(http.StatusOK, s.auth.Status())
}

// ---------------------------------------------------------------------------
// Config & system handlers
// ---------------------------------------------------------------------------

type autoSetRequest struct {
	URL            string `json:"url"`
	DB             string `json:"db"`
	MinioEndpoint  string `json:"minio_endpoint"`
	MinioAccessKey string `json:"minio_access_key"`
	MinioSecretKey string `json:"minio_secret_key"`
	MinioBucket    string `json:"minio_bucket"`
	MinioSecure    bool   `json:"minio_secure"`
}

func (s *Server) handleConfigAutoSet(c *gin.Context) {
	var req autoSetRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": fmt.Sprintf("invalid request: %s", err.Error())})
		return
	}

	snap := s.config.Snapshot()
	changed := snap.OdooURL != req.URL || snap.OdooDB != req.DB
	provisioned := false

	// Update Odoo URL/DB
	if changed {
		_ = s.config.Update(func(cfg *config.Config) {
			cfg.OdooURL = req.URL
			cfg.OdooDB = req.DB
		})
	}

	// Apply MinIO config from JS frontend — always update if provided
	if req.MinioEndpoint != "" {
		needsUpdate := snap.MinioEndpoint != req.MinioEndpoint ||
			snap.MinioAccessKey != req.MinioAccessKey ||
			snap.MinioSecretKey != req.MinioSecretKey ||
			snap.MinioBucket != req.MinioBucket
		if needsUpdate || snap.MinioEndpoint == "" {
			_ = s.config.Update(func(cfg *config.Config) {
				cfg.MinioEndpoint = req.MinioEndpoint
				cfg.MinioAccessKey = req.MinioAccessKey
				cfg.MinioSecretKey = req.MinioSecretKey
				if req.MinioBucket != "" {
					cfg.MinioBucket = req.MinioBucket
				}
				cfg.MinioSecure = req.MinioSecure
			})
			log.Info().
				Str("endpoint", req.MinioEndpoint).
				Str("bucket", req.MinioBucket).
				Msg("auto-provision: MinIO config applied from Odoo frontend")
			provisioned = true
		}
	}

	// Reconnect MinIO if provisioned or not yet connected
	if provisioned || s.minio == nil || s.upload == nil {
		if err := s.ReconnectMinIO(); err != nil {
			log.Warn().Err(err).Msg("auto-provision: MinIO reconnect failed")
		} else if provisioned {
			log.Info().Msg("auto-provision: MinIO connected successfully")
		}
	}

	c.JSON(http.StatusOK, gin.H{"changed": changed, "provisioned": provisioned})
}

func (s *Server) handleSystemStatus(c *gin.Context) {
	snap := s.config.Snapshot()
	minioConnected := s.minio != nil && s.minio.Connected(c.Request.Context())

	c.JSON(http.StatusOK, gin.H{
		"client_id":      snap.ClientID,
		"status":         "running",
		"version":        snap.Version,
		"hostname":       snap.Hostname,
		"minio_connected": minioConnected,
		"odoo_connected": false,
	})
}

func (s *Server) handleUpdateCheck(c *gin.Context) {
	if s.updater == nil {
		c.JSON(http.StatusOK, gin.H{
			"update_available": false,
			"error":            "updater not configured",
		})
		return
	}

	info, err := s.updater.CheckForUpdate(c.Request.Context())
	if err != nil {
		c.JSON(http.StatusOK, gin.H{
			"update_available": false,
			"error":            err.Error(),
		})
		return
	}

	snap := s.config.Snapshot()
	c.JSON(http.StatusOK, gin.H{
		"update_available": info.Available,
		"latest_version":   info.Version,
		"current_version":  snap.Version,
		"download_url":     info.DownloadURL,
	})
}

func (s *Server) handleApplyUpdate(c *gin.Context) {
	if s.updater == nil {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "error": "updater not configured"})
		return
	}

	info, err := s.updater.CheckForUpdate(c.Request.Context())
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"success": false, "error": fmt.Sprintf("update check failed: %s", err.Error())})
		return
	}

	if !info.Available {
		c.JSON(http.StatusOK, gin.H{"success": true, "message": "already up to date"})
		return
	}

	if err := s.updater.Apply(c.Request.Context(), info); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"success": false, "error": fmt.Sprintf("update failed: %s", err.Error())})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"success": true,
		"message": fmt.Sprintf("updated to %s — restart required", info.Version),
		"version": info.Version,
	})
}

func (s *Server) handleBucket(c *gin.Context) {
	snap := s.config.Snapshot()
	c.JSON(http.StatusOK, gin.H{
		"bucket": snap.MinioBucket,
		"alias":  "minio",
	})
}

// ---------------------------------------------------------------------------
// File operation handlers
// ---------------------------------------------------------------------------

func (s *Server) handleList(c *gin.Context) {
	if !s.ensureMinIO() {
		c.JSON(http.StatusOK, []minioclient.ObjectInfo{})
		return
	}
	path := c.Query("path")
	items, err := s.minio.ListObjects(c.Request.Context(), path)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("list failed: %s", err.Error())})
		return
	}
	if items == nil {
		items = []minioclient.ObjectInfo{}
	}
	c.JSON(http.StatusOK, items)
}

type deleteRequest struct {
	Path     string `json:"path"`
	IsFolder bool   `json:"is_folder"`
}

func (s *Server) handleDelete(c *gin.Context) {
	if !s.ensureMinIO() {
		c.JSON(http.StatusServiceUnavailable, gin.H{"success": false, "error": "MinIO not connected"})
		return
	}
	var req deleteRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": fmt.Sprintf("invalid request: %s", err.Error())})
		return
	}

	var err error
	if req.IsFolder {
		err = s.minio.DeleteRecursive(c.Request.Context(), req.Path)
	} else {
		err = s.minio.Delete(c.Request.Context(), req.Path)
	}

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("delete failed: %s", err.Error())})
		return
	}

	c.JSON(http.StatusOK, gin.H{"success": true})
}

type pickSyncRequest struct {
	Type         string `json:"type"`
	CurrentPath  string `json:"current_path"`
	OdooFolderID int    `json:"odoo_folder_id"`
	TaskName     string `json:"task_name"`
	OdooSession  string `json:"odoo_session"`
}

func (s *Server) handlePickSync(c *gin.Context) {
	var req pickSyncRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "error": fmt.Sprintf("invalid request: %s", err.Error())})
		return
	}

	// Open native file/folder picker dialog
	var selected []string

	switch req.Type {
	case "folder":
		path, err := dialog.PickFolder()
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"success": false, "error": fmt.Sprintf("folder picker failed: %s", err.Error())})
			return
		}
		if path == "" {
			c.JSON(http.StatusOK, gin.H{"success": false, "canceled": true})
			return
		}
		selected = []string{path}

	default: // "file" or unspecified
		paths, err := dialog.PickFiles()
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"success": false, "error": fmt.Sprintf("file picker failed: %s", err.Error())})
			return
		}
		if len(paths) == 0 {
			c.JSON(http.StatusOK, gin.H{"success": false, "canceled": true})
			return
		}
		selected = paths
	}

	// Start upload task with the selected paths
	if !s.ensureMinIO() {
		c.JSON(http.StatusServiceUnavailable, gin.H{"success": false, "error": "MinIO not connected. Please configure minio_endpoint, minio_access_key, minio_secret_key in config.json and restart the service."})
		return
	}

	taskID := uuid.New().String()
	taskName := req.TaskName
	if taskName == "" {
		taskName = fmt.Sprintf("upload %d file(s)", len(selected))
	}

	remotePath := req.CurrentPath
	taskType := req.Type
	if taskType == "" {
		taskType = "file"
	}

	t := s.tasks.Create(taskID, taskName)
	t.RemotePath = remotePath
	t.OdooFolderID = req.OdooFolderID
	t.Type = taskType
	t.Path = selected[0] // display path

	cookie := s.resolveOdooCookie(req.OdooSession)
	ue := s.upload

	go func() {
		err := ue.Run(context.Background(), taskID, selected, remotePath, cookie, req.OdooFolderID)
		// Set remote_path on the task for the JS frontend to pick up
		if task := s.tasks.Get(taskID); task != nil {
			task.RemotePath = remotePath
		}
		s.tasks.Complete(taskID, err)
	}()

	c.JSON(http.StatusOK, gin.H{
		"success": true,
		"task_id": taskID,
		"paths":   selected,
	})
}

type downloadAsyncRequest struct {
	Paths []string `json:"paths"`
}

func (s *Server) handleDownloadAsync(c *gin.Context) {
	var req downloadAsyncRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": fmt.Sprintf("invalid request: %s", err.Error())})
		return
	}

	taskID := uuid.New().String()
	s.tasks.Create(taskID, fmt.Sprintf("download %d file(s)", len(req.Paths)))

	// Download task body is wired in a later unit; mark complete immediately for now.
	go func() {
		s.tasks.Complete(taskID, nil)
	}()

	c.JSON(http.StatusOK, gin.H{"task_id": taskID})
}
