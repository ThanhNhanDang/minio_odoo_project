//go:build windows

package startup

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

const shortcutName = "MinIO Service.lnk"

// startupDir returns the Windows Startup folder path.
func startupDir() string {
	appData := os.Getenv("APPDATA")
	if appData == "" {
		return ""
	}
	return filepath.Join(appData, "Microsoft", "Windows", "Start Menu", "Programs", "Startup")
}

// IsEnabled checks whether the startup shortcut exists.
func IsEnabled() bool {
	dir := startupDir()
	if dir == "" {
		return false
	}
	_, err := os.Stat(filepath.Join(dir, shortcutName))
	return err == nil
}

// Enable creates a shortcut in the Windows Startup folder pointing to the
// current executable. Uses PowerShell to create a .lnk file.
func Enable() error {
	dir := startupDir()
	if dir == "" {
		return fmt.Errorf("startup: cannot determine APPDATA")
	}

	exePath, err := os.Executable()
	if err != nil {
		return fmt.Errorf("startup: cannot get executable path: %w", err)
	}
	exePath, _ = filepath.Abs(exePath)
	workDir := filepath.Dir(exePath)
	lnkPath := filepath.Join(dir, shortcutName)

	// PowerShell script to create a .lnk shortcut
	script := fmt.Sprintf(`
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut('%s')
$sc.TargetPath = '%s'
$sc.WorkingDirectory = '%s'
$sc.Description = 'MinIO Service for Odoo Documents'
$sc.Save()
`, strings.ReplaceAll(lnkPath, "'", "''"),
		strings.ReplaceAll(exePath, "'", "''"),
		strings.ReplaceAll(workDir, "'", "''"))

	cmd := exec.Command("powershell", "-NoProfile", "-NonInteractive", "-Command", script)
	cmd.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: 0x08000000, // CREATE_NO_WINDOW
	}
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("startup: create shortcut failed: %w\n%s", err, string(out))
	}

	return nil
}

// Disable removes the startup shortcut.
func Disable() error {
	dir := startupDir()
	if dir == "" {
		return nil
	}
	lnkPath := filepath.Join(dir, shortcutName)
	if err := os.Remove(lnkPath); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("startup: remove shortcut: %w", err)
	}
	return nil
}
