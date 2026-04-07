package tasks

import (
	"sync"
	"time"
)

// Status represents the current state of a task.
type Status string

const (
	StatusPending  Status = "pending"
	StatusRunning  Status = "running"
	StatusSuccess  Status = "success"
	StatusFailed   Status = "failed"
	StatusCanceled Status = "canceled"
)

// Task represents a tracked operation (upload, download, etc.).
type Task struct {
	ID         string    `json:"id"`
	ExternalID string    `json:"externalId,omitempty"`
	Name       string    `json:"name"`
	Status     Status    `json:"status"`
	Percent    float64   `json:"percent"`
	Info       string    `json:"info,omitempty"`
	Error      string    `json:"error,omitempty"`
	CreatedAt  time.Time `json:"created_at"`
	UpdatedAt  time.Time `json:"updated_at"`

	// Metadata for Odoo frontend sync
	RemotePath    string   `json:"remote_path,omitempty"`
	OdooFolderID  int      `json:"odoo_folder_id,omitempty"`
	Type          string   `json:"type,omitempty"` // "file" or "folder"
	Path          string   `json:"path,omitempty"` // display name
	UploadedPaths []string `json:"uploaded_paths,omitempty"` // MinIO object keys of uploaded files

	cancel chan struct{}
}

// Manager tracks all active and completed tasks.
type Manager struct {
	mu    sync.RWMutex
	tasks map[string]*Task
	// subscribers get notified of progress updates per task
	subs map[string][]chan ProgressEvent
}

// ProgressEvent is sent to SSE subscribers.
type ProgressEvent struct {
	TaskID  string  `json:"task_id"`
	Percent float64 `json:"percent"`
	Status  string  `json:"status"`
	Info    string  `json:"info,omitempty"`
}

// NewManager creates a new task manager.
func NewManager() *Manager {
	return &Manager{
		tasks: make(map[string]*Task),
		subs:  make(map[string][]chan ProgressEvent),
	}
}

// Create registers a new task.
func (m *Manager) Create(id, name string) *Task {
	m.mu.Lock()
	defer m.mu.Unlock()

	t := &Task{
		ID:        id,
		Name:      name,
		Status:    StatusPending,
		CreatedAt: time.Now(),
		UpdatedAt: time.Now(),
		cancel:    make(chan struct{}),
	}
	m.tasks[id] = t
	return t
}

// Get returns a task by ID.
func (m *Manager) Get(id string) *Task {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.tasks[id]
}

// List returns all tasks.
func (m *Manager) List() []*Task {
	m.mu.RLock()
	defer m.mu.RUnlock()

	result := make([]*Task, 0, len(m.tasks))
	for _, t := range m.tasks {
		result = append(result, t)
	}
	return result
}

// UpdateProgress updates task percent and notifies subscribers.
func (m *Manager) UpdateProgress(id string, percent float64, info string) {
	m.mu.Lock()
	t, ok := m.tasks[id]
	if !ok {
		m.mu.Unlock()
		return
	}
	t.Percent = percent
	t.Info = info
	t.Status = StatusRunning
	t.UpdatedAt = time.Now()

	evt := ProgressEvent{
		TaskID:  id,
		Percent: percent,
		Status:  string(StatusRunning),
		Info:    info,
	}

	subs := m.subs[id]
	m.mu.Unlock()

	// Non-blocking send to all subscribers
	for _, ch := range subs {
		select {
		case ch <- evt:
		default:
		}
	}
}

// Complete marks task as finished.
func (m *Manager) Complete(id string, err error) {
	m.mu.Lock()
	t, ok := m.tasks[id]
	if !ok {
		m.mu.Unlock()
		return
	}

	if err != nil {
		t.Status = StatusFailed
		t.Error = err.Error()
	} else {
		t.Status = StatusSuccess
		t.Percent = 100
	}
	t.UpdatedAt = time.Now()

	evt := ProgressEvent{
		TaskID:  id,
		Percent: t.Percent,
		Status:  string(t.Status),
	}

	subs := m.subs[id]
	m.mu.Unlock()

	for _, ch := range subs {
		select {
		case ch <- evt:
		default:
		}
		close(ch)
	}

	// Clean up subs
	m.mu.Lock()
	delete(m.subs, id)
	m.mu.Unlock()
}

// Cancel requests cancellation of a task.
func (m *Manager) Cancel(id string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()

	t, ok := m.tasks[id]
	if !ok || t.Status != StatusRunning {
		return false
	}

	t.Status = StatusCanceled
	t.UpdatedAt = time.Now()
	close(t.cancel)
	return true
}

// CancelChan returns the cancellation channel for a task.
func (m *Manager) CancelChan(id string) <-chan struct{} {
	m.mu.RLock()
	defer m.mu.RUnlock()

	t, ok := m.tasks[id]
	if !ok {
		ch := make(chan struct{})
		close(ch)
		return ch
	}
	return t.cancel
}

// Subscribe returns a channel that receives progress events for a task.
func (m *Manager) Subscribe(id string) chan ProgressEvent {
	m.mu.Lock()
	defer m.mu.Unlock()

	ch := make(chan ProgressEvent, 32)
	m.subs[id] = append(m.subs[id], ch)
	return ch
}

// Delete removes a task from tracking.
func (m *Manager) Delete(id string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()

	if _, ok := m.tasks[id]; !ok {
		return false
	}
	delete(m.tasks, id)
	delete(m.subs, id)
	return true
}
