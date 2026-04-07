//go:build !windows

package startup

// IsEnabled reports whether auto-start is configured. (No-op on non-Windows.)
func IsEnabled() bool { return false }

// Enable sets up auto-start on login. (No-op on non-Windows.)
func Enable() error { return nil }

// Disable removes auto-start. (No-op on non-Windows.)
func Disable() error { return nil }
