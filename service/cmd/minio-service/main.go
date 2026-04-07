package main

import (
	"context"
	"fmt"
	stdlog "log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"

	"minio-service/internal/api"
	"minio-service/internal/auth"
	"minio-service/internal/config"
	"minio-service/internal/minioclient"
	"minio-service/internal/notify"
	"minio-service/internal/singleton"
	"minio-service/internal/startup"
	"minio-service/internal/tasks"
	"minio-service/internal/tray"
	"minio-service/internal/updater"
	"minio-service/internal/upload"
)

// version is set at build time via -ldflags "-X main.version=X.Y.Z".
var version string

func main() {
	hideConsoleWindow()

	// 0. Single-instance guard — prevent duplicate tray icons.
	release, err := singleton.Lock("Global\\MinIOServiceAutoNSI")
	if err != nil {
		fmt.Fprintf(os.Stderr, "minio-service: %s\n", err)
		os.Exit(1)
	}
	defer release()

	// 1. Locate config.json next to the executable.
	exePath, err := os.Executable()
	if err != nil {
		// Fallback to working directory.
		exePath = "."
	}
	cfgPath := filepath.Join(filepath.Dir(exePath), "config.json")

	// 2. Load config (creates defaults if missing).
	cfg, err := config.Load(cfgPath)
	if err != nil {
		// Fatal before zerolog is fully configured — write to stderr directly.
		log.Fatal().Err(err).Str("path", cfgPath).Msg("failed to load config")
	}

	// 2b. Sync build-time version into config (so updater compares correctly).
	if version != "" {
		snap := cfg.Snapshot()
		if snap.Version != version {
			_ = cfg.Update(func(c *config.Config) {
				c.Version = version
			})
		}
	}

	// 3. Init zerolog — write to log file (no console window in -H windowsgui mode).
	logPath := filepath.Join(filepath.Dir(cfgPath), "minio-service.log")
	logFile, logErr := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if logErr != nil {
		// Fallback to stderr if log file cannot be opened.
		log.Logger = log.Output(zerolog.ConsoleWriter{Out: os.Stderr})
	} else {
		log.Logger = log.Output(zerolog.ConsoleWriter{Out: logFile, NoColor: true})
		// Redirect Go's standard log to the same file so third-party libraries
		// (e.g. energye/systray) that use log.Printf are captured too.
		stdlog.SetOutput(logFile)
	}
	zerolog.SetGlobalLevel(zerolog.DebugLevel)

	// 3b. Auto-enable startup with Windows on first run.
	if !startup.IsEnabled() {
		if err := startup.Enable(); err != nil {
			log.Warn().Err(err).Msg("failed to register startup shortcut")
		} else {
			log.Info().Msg("registered startup shortcut — service will auto-start with Windows")
		}
	}

	snap := cfg.Snapshot()
	log.Info().
		Str("version", snap.Version).
		Str("listen", snap.ListenAddr).
		Str("config", cfgPath).
		Msg("starting minio-service")

	// 4. Create MinIO client — non-fatal if unreachable.
	var mc *minioclient.Client
	mc, err = minioclient.New(
		snap.MinioEndpoint,
		snap.MinioAccessKey,
		snap.MinioSecretKey,
		snap.MinioBucket,
		snap.MinioSecure,
	)
	if err != nil {
		log.Warn().Err(err).Msg("MinIO client init failed — service will run without MinIO until configured via /api/config/auto_set")
		mc = nil
	}

	// 5. Create task manager.
	tm := tasks.NewManager()

	// 6. Create upload engine (requires a valid MinIO client; may be nil).
	var ue *upload.Engine
	if mc != nil {
		ue = upload.New(mc, tm, cfg)
	}

	// 7. Create auth manager.
	am := auth.New()

	// 7b. Create updater (nil-safe if UpdateURL is empty).
	var upd *updater.Updater
	if snap.UpdateURL != "" {
		upd = updater.New(snap.Version, snap.UpdateURL, snap.GitHubToken)
		log.Info().Str("update_url", snap.UpdateURL).Msg("updater initialized")
	}

	// 8. Create HTTP API server.
	srv := api.New(cfg, mc, tm, am)

	// 9. Wire upload engine into server.
	if ue != nil {
		srv.SetUploadEngine(ue)
	}

	// 9b. Wire updater into server.
	if upd != nil {
		srv.SetUpdater(upd)
	}

	// 10. Start HTTP server in a background goroutine.
	serverErr := make(chan error, 1)
	go func() {
		log.Info().Str("addr", snap.ListenAddr).Msg("HTTP server starting")
		if err := srv.Start(); err != nil {
			serverErr <- err
		}
	}()

	// Handle OS signals for graceful shutdown (used when not running with tray).
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	// onStop triggers a clean shutdown regardless of who calls it (tray Quit or OS signal).
	shutdownCh := make(chan struct{})
	onStop := func() {
		select {
		case <-shutdownCh:
			// Already shutting down.
		default:
			close(shutdownCh)
		}
	}

	// Watch for OS signal (Ctrl+C) and call systray.Quit to unblock main thread.
	go func() {
		select {
		case sig := <-sigCh:
			log.Info().Str("signal", sig.String()).Msg("received signal, shutting down")
			onStop()
			tray.Quit()
		case <-shutdownCh:
		}
	}()

	// 11. Background update checker — runs every 6 hours.
	if upd != nil {
		go func() {
			// First check after 30 seconds (let the service fully start).
			timer := time.NewTimer(30 * time.Second)
			for {
				select {
				case <-timer.C:
					info, err := upd.CheckForUpdate(context.Background())
					if err != nil {
						log.Warn().Err(err).Msg("background update check failed")
					} else if info.Available {
						log.Info().
							Str("latest", info.Version).
							Str("current", snap.Version).
							Msg("new version available")
						// Show popup dialog — user can choose "Update & Restart" or "Later"
						if notify.ShowUpdateDialog(snap.Version, info.Version) {
							notify.Toast("MinIO Service", "Downloading update...")
							if err := upd.Apply(context.Background(), info); err != nil {
								log.Error().Err(err).Msg("background update apply failed")
								notify.Toast("MinIO Service", "Update failed: "+err.Error())
							} else {
								log.Info().Str("version", info.Version).Msg("update applied via background check, restarting")
								notify.Toast("MinIO Service", fmt.Sprintf("Updated to v%s! Restarting...", info.Version))
								// Restart: launch new exe then exit
								if exePath, err := os.Executable(); err == nil {
									cmd := exec.Command(exePath)
									cmd.Stdout = os.Stdout
									cmd.Stderr = os.Stderr
									_ = cmd.Start()
								}
								onStop()
								tray.Quit()
								return
							}
						} else {
							log.Info().Str("version", info.Version).Msg("user chose Later via background check")
						}
					}
					// Next check in 6 hours.
					timer.Reset(6 * time.Hour)
				case <-shutdownCh:
					timer.Stop()
					return
				}
			}
		}()
	}

	// 12. Run system tray — blocks the main thread (required by systray).
	// onStart fires once the tray icon is ready.
	tray.Run(cfg, upd,
		func() {
			log.Info().Str("addr", snap.ListenAddr).Msg("service started")

			// If the server errored immediately, log and shut down.
			select {
			case err := <-serverErr:
				log.Error().Err(err).Msg("HTTP server failed to start")
				notify.Toast("MinIO Service", "Failed to start: "+err.Error())
				onStop()
				tray.Quit()
			default:
				// Show Windows notification on successful start
				go notify.Toast("MinIO Service", "Service is running on "+snap.ListenAddr)
			}
		},
		onStop,
	)

	// After tray exits, perform graceful shutdown.
	log.Info().Msg("tray exited, shutting down")

	_, cancel := context.WithCancel(context.Background())
	cancel() // Signal any in-flight operations to stop.

	log.Info().Msg("shutdown complete")
}
