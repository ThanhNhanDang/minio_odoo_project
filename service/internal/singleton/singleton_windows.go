//go:build windows

package singleton

import (
	"fmt"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	kernel32        = windows.NewLazySystemDLL("kernel32.dll")
	createMutexW    = kernel32.NewProc("CreateMutexW")
	releaseMutex    = kernel32.NewProc("ReleaseMutex")
	closeHandleProc = kernel32.NewProc("CloseHandle")
)

const errorAlreadyExists = 183

// Lock attempts to acquire a system-wide named mutex.
// Returns a release function on success, or an error if another instance holds the lock.
func Lock(name string) (func(), error) {
	mutexName, err := syscall.UTF16PtrFromString(name)
	if err != nil {
		return nil, fmt.Errorf("singleton: invalid mutex name: %w", err)
	}

	// CreateMutexW returns (handle, _, lastError).
	// lastErr (3rd return) is the errno set by the syscall — must be captured
	// from the same Call, NOT from a separate GetLastError call.
	handle, _, lastErr := createMutexW.Call(
		0,
		0,
		uintptr(unsafe.Pointer(mutexName)),
	)

	if handle == 0 {
		return nil, fmt.Errorf("singleton: CreateMutex failed: %v", lastErr)
	}

	// If the mutex already existed, another instance owns it.
	if lastErr == syscall.Errno(errorAlreadyExists) {
		closeHandleProc.Call(handle)
		return nil, fmt.Errorf("singleton: another instance is already running")
	}

	release := func() {
		releaseMutex.Call(handle)
		closeHandleProc.Call(handle)
	}

	return release, nil
}
