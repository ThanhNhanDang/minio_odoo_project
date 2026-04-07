//go:build !windows

package notify

// Toast is a no-op on non-Windows platforms.
func Toast(title, message string) {}

// ShowInfoDialog is a no-op on non-Windows platforms.
func ShowInfoDialog(title, message string) {}

// ShowUpdateDialog always returns true on headless platforms (auto-update).
func ShowUpdateDialog(currentVersion, newVersion string) bool { return true }
