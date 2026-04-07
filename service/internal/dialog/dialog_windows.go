//go:build windows

package dialog

import (
	"fmt"
	"os/exec"
	"strings"
	"syscall"
)

// dialogPowerShell creates a PowerShell process that hides only the console
// window but still allows GUI dialogs (COM IFileDialog, WinForms) to render.
// Using CREATE_NO_WINDOW here would prevent dialogs from showing.
func dialogPowerShell(args ...string) *exec.Cmd {
	cmd := exec.Command("powershell", args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{
		HideWindow: true,
	}
	return cmd
}

// utf8Preamble forces PowerShell to output UTF-8 so filenames with
// Unicode characters (e.g. accented letters, CJK, special symbols)
// survive the pipe to Go without being corrupted to '?'.
const utf8Preamble = `
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
`

// dpiPreamble sets DPI awareness + visual styles + foreground helpers.
const dpiPreamble = `
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()
Add-Type -TypeDefinition '
using System;
using System.Runtime.InteropServices;
public class WinHelper {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int pid);
}
'
[WinHelper]::SetProcessDPIAware() | Out-Null
[WinHelper]::AllowSetForegroundWindow(-1) | Out-Null
`

// pickFolder uses OpenFileDialog configured to select folders, giving the same
// modern Explorer UI as file picking (address bar, navigation pane, search).
func pickFolder() (string, error) {
	script := utf8Preamble + dpiPreamble + `
# Create a hidden topmost form as dialog owner so it appears in front
$form = New-Object System.Windows.Forms.Form
$form.TopMost = $true
$form.WindowState = 'Minimized'
$form.ShowInTaskbar = $false
$form.Show()
$form.Hide()

$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Title = "Select a folder to upload"
$dialog.ValidateNames = $false
$dialog.CheckFileExists = $false
$dialog.CheckPathExists = $true
$dialog.FileName = "Select Folder"
$dialog.Filter = "Folders|no.files"
$dialog.InitialDirectory = [Environment]::GetFolderPath("Desktop")
$result = $dialog.ShowDialog($form)
$form.Dispose()
if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
    Write-Output ([System.IO.Path]::GetDirectoryName($dialog.FileName))
}
`
	out, err := dialogPowerShell("-NoProfile", "-NonInteractive", "-Command", script).Output()
	if err != nil {
		// Check if it's just "no selection" (empty output, exit 0)
		if exitErr, ok := err.(*exec.ExitError); ok {
			_ = exitErr
			return "", nil // user canceled or error
		}
		return "", fmt.Errorf("folder dialog: %w", err)
	}

	path := strings.TrimSpace(string(out))
	if path == "" {
		return "", nil // user canceled
	}
	return path, nil
}

// pickFiles uses PowerShell's OpenFileDialog with DPI awareness
// so the dialog renders crisp on high-DPI screens.
func pickFiles() ([]string, error) {
	script := utf8Preamble + dpiPreamble + `
# Create a hidden topmost form as dialog owner so it appears in front
$form = New-Object System.Windows.Forms.Form
$form.TopMost = $true
$form.WindowState = 'Minimized'
$form.ShowInTaskbar = $false
$form.Show()
$form.Hide()

$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Title = "Select files to upload"
$dialog.Multiselect = $true
$dialog.Filter = "All files (*.*)|*.*"
$result = $dialog.ShowDialog($form)
$form.Dispose()
if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
    $dialog.FileNames | ForEach-Object { Write-Output $_ }
}
`
	out, err := dialogPowerShell("-NoProfile", "-NonInteractive", "-Command", script).Output()
	if err != nil {
		if _, ok := err.(*exec.ExitError); ok {
			return nil, nil
		}
		return nil, fmt.Errorf("file dialog: %w", err)
	}

	raw := strings.TrimSpace(string(out))
	if raw == "" {
		return nil, nil // user canceled
	}

	var paths []string
	for _, line := range strings.Split(raw, "\n") {
		p := strings.TrimSpace(line)
		if p != "" {
			paths = append(paths, p)
		}
	}
	return paths, nil
}
