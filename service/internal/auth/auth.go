package auth

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"
)

// Manager handles Odoo session authentication.
type Manager struct {
	mu            sync.RWMutex
	sessionID     string
	odooURL       string
	odooDB        string
	uid           int
	authenticated bool
}

// New creates a new auth Manager.
func New() *Manager {
	return &Manager{}
}

// jsonRPCRequest is the Odoo JSON-RPC request envelope.
type jsonRPCRequest struct {
	JSONRPC string         `json:"jsonrpc"`
	Method  string         `json:"method"`
	Params  map[string]any `json:"params"`
}

// jsonRPCResult is the partial structure of an Odoo JSON-RPC response.
type jsonRPCResult struct {
	JSONRPC string `json:"jsonrpc"`
	Result  struct {
		UID      int    `json:"uid"`
		SessionID string `json:"session_id"`
	} `json:"result"`
	Error *struct {
		Message string `json:"message"`
	} `json:"error"`
}

// Login authenticates against Odoo and stores the session.
func (m *Manager) Login(odooURL, db, username, password string) error {
	payload := jsonRPCRequest{
		JSONRPC: "2.0",
		Method:  "call",
		Params: map[string]any{
			"db":       db,
			"login":    username,
			"password": password,
		},
	}

	data, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("auth: marshal login payload: %w", err)
	}

	endpoint := strings.TrimSuffix(odooURL, "/") + "/web/session/authenticate"

	client := &http.Client{Timeout: 30 * time.Second}
	req, err := http.NewRequest(http.MethodPost, endpoint, bytes.NewReader(data))
	if err != nil {
		return fmt.Errorf("auth: build login request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("auth: login request to %s: %w", endpoint, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		return fmt.Errorf("auth: login returned HTTP %d", resp.StatusCode)
	}

	var result jsonRPCResult
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return fmt.Errorf("auth: decode login response: %w", err)
	}

	if result.Error != nil {
		return fmt.Errorf("auth: odoo error: %s", result.Error.Message)
	}

	if result.Result.UID == 0 {
		return fmt.Errorf("auth: login failed — invalid credentials")
	}

	// Extract session_id from Set-Cookie header.
	sessionID := ""
	for _, cookie := range resp.Cookies() {
		if cookie.Name == "session_id" {
			sessionID = cookie.Value
			break
		}
	}

	// Fall back to session_id in the result body if cookie is absent.
	if sessionID == "" {
		sessionID = result.Result.SessionID
	}

	m.mu.Lock()
	m.sessionID = sessionID
	m.odooURL = odooURL
	m.odooDB = db
	m.uid = result.Result.UID
	m.authenticated = true
	m.mu.Unlock()

	return nil
}

// Logout clears the stored session.
func (m *Manager) Logout() {
	m.mu.Lock()
	m.sessionID = ""
	m.odooURL = ""
	m.odooDB = ""
	m.uid = 0
	m.authenticated = false
	m.mu.Unlock()
}

// IsAuthenticated reports whether a valid session is held.
func (m *Manager) IsAuthenticated() bool {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.authenticated
}

// Status returns a snapshot of the current auth state for API responses.
func (m *Manager) Status() map[string]interface{} {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return map[string]interface{}{
		"authenticated": m.authenticated,
		"uid":           m.uid,
		"odoo_url":      m.odooURL,
		"odoo_db":       m.odooDB,
	}
}

// SessionCookie returns the raw session_id value suitable for use in a Cookie header.
func (m *Manager) SessionCookie() string {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if m.sessionID == "" {
		return ""
	}
	return "session_id=" + m.sessionID
}

// OdooURL returns the Odoo base URL for the current session.
func (m *Manager) OdooURL() string {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.odooURL
}

// MinioConfig holds the MinIO configuration returned by Odoo.
type MinioConfig struct {
	Endpoint  string `json:"endpoint"`
	AccessKey string `json:"access_key"`
	SecretKey string `json:"secret_key"`
	Bucket    string `json:"bucket_name"`
	Alias     string `json:"alias"`
}

// FetchMinioConfig calls Odoo's /minio/get_config endpoint using the current
// session and returns the MinIO configuration. This allows the Go service to
// auto-provision itself from Odoo on first login — no manual config.json editing.
func (m *Manager) FetchMinioConfig(clientID, hostname string) (*MinioConfig, error) {
	m.mu.RLock()
	url := m.odooURL
	cookie := m.sessionID
	m.mu.RUnlock()

	if url == "" || cookie == "" {
		return nil, fmt.Errorf("auth: not authenticated — login first")
	}

	payload := jsonRPCRequest{
		JSONRPC: "2.0",
		Method:  "call",
		Params: map[string]any{
			"client_id": clientID,
			"hostname":  hostname,
		},
	}

	data, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("auth: marshal get_config: %w", err)
	}

	endpoint := strings.TrimSuffix(url, "/") + "/minio/get_config"
	client := &http.Client{Timeout: 30 * time.Second}
	req, err := http.NewRequest(http.MethodPost, endpoint, bytes.NewReader(data))
	if err != nil {
		return nil, fmt.Errorf("auth: build get_config request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Cookie", "session_id="+cookie)

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("auth: get_config request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("auth: get_config returned HTTP %d", resp.StatusCode)
	}

	var rpcResp struct {
		Result struct {
			Status string      `json:"status"`
			Data   MinioConfig `json:"data"`
			Msg    string      `json:"message"`
		} `json:"result"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&rpcResp); err != nil {
		return nil, fmt.Errorf("auth: decode get_config: %w", err)
	}

	if rpcResp.Result.Status != "success" {
		return nil, fmt.Errorf("auth: get_config error: %s", rpcResp.Result.Msg)
	}

	return &rpcResp.Result.Data, nil
}
