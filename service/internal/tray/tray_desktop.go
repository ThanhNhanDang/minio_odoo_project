//go:build windows || darwin

package tray

import (
	"context"
	_ "embed"
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"syscall"

	"fyne.io/systray"
	"github.com/rs/zerolog/log"

	"minio-service/internal/config"
	"minio-service/internal/notify"
	"minio-service/internal/startup"
	"minio-service/internal/updater"
)

//go:embed icon.ico
var iconICO []byte

//go:embed icon_new.png
var iconPNG []byte

// Run starts the system tray. It blocks the calling goroutine (must be main
// thread on most platforms). onStart is called once the tray is ready;
// onStop is called when the user chooses Quit.
func Run(cfg *config.Config, upd *updater.Updater, onStart func(), onStop func()) {
	log.Info().Msg("systray: initializing")
	systray.Run(func() {
		log.Info().Msg("systray: onReady called")
		onReady(cfg, upd, onStart, onStop)
	}, func() {
		log.Info().Msg("systray: onExit called")
		onExit()
	})
	log.Info().Msg("systray: Run returned")
}

func onReady(cfg *config.Config, upd *updater.Updater, onStart func(), onStop func()) {
	snap := cfg.Snapshot()

	log.Debug().Int("ico_bytes", len(iconICO)).Msg("systray: setting icon")
	systray.SetIcon(iconICO)
	systray.SetTooltip(fmt.Sprintf("MinIO Service v%s — AutoNSI", snap.Version))

	mStatus := systray.AddMenuItem("Status: Running", "Current service state")
	mStatus.Disable()

	systray.AddSeparator()

	mBrowser := systray.AddMenuItem("Open MinIO Browser", "Open in default browser")

	mStartup := systray.AddMenuItemCheckbox("Start with Windows", "Auto-start on login", startup.IsEnabled())

	mUpdate := systray.AddMenuItem("Check for Update", "Check for a newer version")
	if upd == nil {
		mUpdate.Disable()
	}

	systray.AddSeparator()

	mQuit := systray.AddMenuItem("Quit", "Stop the service and exit")

	if onStart != nil {
		go onStart()
	}

	// promptUpdate checks for a new version and shows a popup dialog.
	promptUpdate := func() {
		if upd == nil {
			return
		}
		info, err := upd.CheckForUpdate(context.Background())
		if err != nil {
			notify.ShowInfoDialog("MinIO Service", "Update check failed:\n"+err.Error())
			return
		}
		if !info.Available {
			notify.ShowInfoDialog("MinIO Service", "You are running the latest version (v"+snap.Version+")")
			return
		}

		if !notify.ShowUpdateDialog(snap.Version, info.Version) {
			log.Info().Str("version", info.Version).Msg("user chose Later — skipping update")
			return
		}

		notify.Toast("MinIO Service", "Downloading update...")
		if err := upd.Apply(context.Background(), info); err != nil {
			notify.Toast("MinIO Service", "Update failed: "+err.Error())
			return
		}

		log.Info().Str("version", info.Version).Msg("update applied, restarting")
		notify.Toast("MinIO Service",
			fmt.Sprintf("Updated to v%s! Restarting...", info.Version))

		exePath, err := os.Executable()
		if err != nil {
			notify.Toast("MinIO Service", "Restart failed: "+err.Error())
			return
		}
		cmd := exec.Command(exePath)
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		if err := cmd.Start(); err != nil {
			notify.Toast("MinIO Service", "Restart failed: "+err.Error())
			return
		}

		if onStop != nil {
			onStop()
		}
		systray.Quit()
	}

	go func() {
		for {
			select {
			case <-mBrowser.ClickedCh:
				openBrowser(buildBrowserURL(cfg))
			case <-mStartup.ClickedCh:
				if mStartup.Checked() {
					_ = startup.Disable()
					mStartup.Uncheck()
				} else {
					_ = startup.Enable()
					mStartup.Check()
				}
			case <-mUpdate.ClickedCh:
				go promptUpdate()
			case <-mQuit.ClickedCh:
				if onStop != nil {
					onStop()
				}
				systray.Quit()
				return
			}
		}
	}()
}

// Quit signals the tray to exit (unblocks Run).
func Quit() {
	systray.Quit()
}

func onExit() {}

// buildBrowserURL returns the local service web UI URL.
func buildBrowserURL(cfg *config.Config) string {
	snap := cfg.Snapshot()
	addr := snap.ListenAddr
	if addr == "" {
		addr = ":9999"
	}
	// addr is ":9999" or "0.0.0.0:9999" — normalize to localhost
	if strings.HasPrefix(addr, ":") {
		addr = "localhost" + addr
	}
	return "http://" + addr
}

// openBrowser opens url in the default system browser.
func openBrowser(url string) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", url)
		cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	case "darwin":
		cmd = exec.Command("open", url)
	default:
		cmd = exec.Command("xdg-open", url)
	}
	_ = cmd.Start()
}
