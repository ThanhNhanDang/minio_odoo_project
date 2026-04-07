//go:build !windows

package singleton

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
)

// Lock creates a PID lock file to prevent multiple instances.
func Lock(name string) (func(), error) {
	lockPath := filepath.Join(os.TempDir(), name+".lock")

	// Check if lock file exists and process is still running.
	if data, err := os.ReadFile(lockPath); err == nil {
		if pid, err := strconv.Atoi(string(data)); err == nil {
			if process, err := os.FindProcess(pid); err == nil {
				// On Unix, FindProcess always succeeds. Send signal 0 to check.
				if err := process.Signal(syscall.Signal(0)); err == nil {
					return nil, fmt.Errorf("singleton: another instance is already running (PID %d)", pid)
				}
			}
		}
	}

	// Write our PID.
	if err := os.WriteFile(lockPath, []byte(strconv.Itoa(os.Getpid())), 0o644); err != nil {
		return nil, fmt.Errorf("singleton: write lock file: %w", err)
	}

	release := func() {
		os.Remove(lockPath)
	}

	return release, nil
}
