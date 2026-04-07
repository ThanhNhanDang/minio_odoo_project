//go:build windows

package notify

import (
	"os/exec"
	"strings"
	"syscall"

	"github.com/rs/zerolog/log"
)

// Toast shows a Windows balloon notification using PowerShell + WinForms NotifyIcon.
// This works reliably on Windows 10/11 without needing a registered App ID.
func Toast(title, message string) {
	// Escape single quotes for PowerShell string
	t := strings.ReplaceAll(title, "'", "''")
	m := strings.ReplaceAll(message, "'", "''")

	script := `
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
$toastXml = @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>` + t + `</text>
      <text>` + m + `</text>
    </binding>
  </visual>
</toast>
"@
$xml.LoadXml($toastXml)
$toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("MinIO Service").Show($toast)
`
	cmd := exec.Command("powershell", "-NoProfile", "-NonInteractive", "-Command", script)
	cmd.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: 0x08000000,
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		log.Error().Err(err).Str("output", string(out)).Msg("notify: Toast powershell failed")
	} else {
		log.Debug().Str("title", title).Msg("notify: Toast displayed successfully")
	}
}

// ShowInfoDialog shows a Windows MessageBox with an OK button.
// Unlike Toast, this always appears in the foreground.
func ShowInfoDialog(title, message string) {
	t := strings.ReplaceAll(title, "'", "''")
	m := strings.ReplaceAll(message, "'", "''")

	script := `
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.MessageBox]::Show('` + m + `', '` + t + `', 'OK', 'Information') | Out-Null
`
	cmd := exec.Command("powershell", "-NoProfile", "-NonInteractive", "-Command", script)
	cmd.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: 0x08000000,
	}
	_ = cmd.Run()
}

// ShowUpdateDialog shows a Windows MessageBox with "Update & Restart" (Yes)
// and "Later" (No) buttons. Returns true if the user chose to update.
func ShowUpdateDialog(currentVersion, newVersion string) bool {
	cv := strings.ReplaceAll(currentVersion, "'", "''")
	nv := strings.ReplaceAll(newVersion, "'", "''")

	script := `
Add-Type -AssemblyName System.Windows.Forms
$msg = "A new version is available!`+"`n`n"+`Current version: v` + cv + "`n" + `New version: v` + nv + "`n`n" + `Would you like to update and restart now?"
$result = [System.Windows.Forms.MessageBox]::Show($msg, 'MinIO Service Update', 'YesNo', 'Information')
if ($result -eq 'Yes') { Write-Output 'YES' } else { Write-Output 'NO' }
`
	cmd := exec.Command("powershell", "-NoProfile", "-NonInteractive", "-Command", script)
	cmd.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: 0x08000000,
	}
	out, err := cmd.Output()
	if err != nil {
		return false
	}
	return strings.TrimSpace(string(out)) == "YES"
}
