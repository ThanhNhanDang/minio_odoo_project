package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"

	"github.com/google/uuid"
)

// Config holds all application configuration.
type Config struct {
	mu sync.RWMutex

	// MinIO settings
	MinioEndpoint  string `json:"minio_endpoint"`
	MinioAccessKey string `json:"minio_access_key"`
	MinioSecretKey string `json:"minio_secret_key"`
	MinioBucket    string `json:"minio_bucket"`
	MinioSecure    bool   `json:"minio_secure"`

	// Odoo settings
	OdooURL string `json:"odoo_url"`
	OdooDB  string `json:"odoo_db"`

	// Service settings
	ClientID   string `json:"client_id"`
	ListenAddr string `json:"listen_addr"`
	Hostname   string `json:"hostname"`

	// Auto-update
	UpdateURL   string `json:"update_url"`
	GitHubToken string `json:"github_token"`
	Version     string `json:"version"`

	filePath string
}

// DefaultConfig returns config with sensible defaults.
func DefaultConfig() *Config {
	hostname, _ := os.Hostname()
	return &Config{
		MinioEndpoint: "localhost:9000",
		MinioBucket:   "odoo-documents",
		ListenAddr:    ":9999",
		ClientID:      uuid.New().String(),
		Hostname:      hostname,
		UpdateURL:     "ThanhNhanDang/minio_odoo_project",
		Version:       "1.0.0",
	}
}

// Load reads config from a JSON file. Creates default if missing.
func Load(path string) (*Config, error) {
	cfg := DefaultConfig()
	cfg.filePath = path

	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			// Create default config file
			return cfg, cfg.Save()
		}
		return nil, err
	}

	if err := json.Unmarshal(data, cfg); err != nil {
		return nil, err
	}

	// Ensure client_id exists
	if cfg.ClientID == "" {
		cfg.ClientID = uuid.New().String()
		_ = cfg.Save()
	}

	return cfg, nil
}

// Save writes current config to disk.
func (c *Config) Save() error {
	c.mu.RLock()
	defer c.mu.RUnlock()

	dir := filepath.Dir(c.filePath)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}

	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}

	return os.WriteFile(c.filePath, data, 0o644)
}

// Update applies changes atomically and saves.
func (c *Config) Update(fn func(cfg *Config)) error {
	c.mu.Lock()
	fn(c)
	c.mu.Unlock()
	return c.Save()
}

// Snapshot returns a read-only copy of current config values.
func (c *Config) Snapshot() Config {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return Config{
		MinioEndpoint:  c.MinioEndpoint,
		MinioAccessKey: c.MinioAccessKey,
		MinioSecretKey: c.MinioSecretKey,
		MinioBucket:    c.MinioBucket,
		MinioSecure:    c.MinioSecure,
		OdooURL:        c.OdooURL,
		OdooDB:         c.OdooDB,
		ClientID:       c.ClientID,
		ListenAddr:     c.ListenAddr,
		Hostname:       c.Hostname,
		UpdateURL:      c.UpdateURL,
		GitHubToken:    c.GitHubToken,
		Version:        c.Version,
	}
}
