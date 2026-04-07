//go:build !(windows || darwin)

package tray

import (
	"sync"

	"minio-service/internal/config"
	"minio-service/internal/updater"
)

var (
	quitCh   = make(chan struct{})
	quitOnce sync.Once
)

// Run blocks the calling goroutine in headless mode (no system tray).
// onStart is called immediately; the function blocks until Quit is called,
// then invokes onStop.
func Run(cfg *config.Config, upd *updater.Updater, onStart func(), onStop func()) {
	if onStart != nil {
		go onStart()
	}

	// Block until Quit() is called.
	<-quitCh

	if onStop != nil {
		onStop()
	}
}

// Quit signals Run to unblock and return.
func Quit() {
	quitOnce.Do(func() {
		close(quitCh)
	})
}
