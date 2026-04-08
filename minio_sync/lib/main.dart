import 'dart:io' show Directory, File, Platform, Process, ProcessSignal, pid, exit;
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';
import 'package:launch_at_startup/launch_at_startup.dart';

import 'utils/platform_utils.dart';
import 'utils/logger.dart';
import 'services/config_service.dart';
import 'ui/tray/tray_manager.dart';
import 'ui/popup/popup_window.dart';
import 'server/api_server.dart';

/// Held in main isolate so popup can kill/restart the server isolate.
Isolate? serverIsolate;

/// Lock file path — stored next to the executable.
String get _lockFilePath =>
    p.join(p.dirname(Platform.resolvedExecutable), '.minio_sync.lock');

/// Acquire a lock file with the current PID.
/// Returns true if we got the lock, false if another instance is alive.
bool acquireLock() {
  final lockFile = File(_lockFilePath);
  try {
    if (lockFile.existsSync()) {
      final content = lockFile.readAsStringSync().trim();
      final existingPid = int.tryParse(content);
      if (existingPid != null && _isProcessRunning(existingPid)) {
        return false; // another instance is alive
      }
      // Stale lock file (process no longer running) — overwrite it
    }
    lockFile.writeAsStringSync('$pid');
    return true;
  } catch (e) {
    appLogger.e('Lock file error: $e');
    return true; // on error, allow startup rather than blocking
  }
}

/// Remove lock file on exit.
void releaseLock() {
  try {
    final lockFile = File(_lockFilePath);
    if (lockFile.existsSync()) {
      final content = lockFile.readAsStringSync().trim();
      if (content == '$pid') {
        lockFile.deleteSync();
      }
    }
  } catch (_) {}
}

/// Check if a process with the given PID is still running.
bool _isProcessRunning(int targetPid) {
  try {
    if (Platform.isWindows) {
      final result = Process.runSync('tasklist', ['/FI', 'PID eq $targetPid', '/NH']);
      return result.stdout.toString().contains('$targetPid');
    } else {
      // Unix: send signal 0 to check if process exists
      return Process.runSync('kill', ['-0', '$targetPid']).exitCode == 0;
    }
  } catch (_) {
    return false;
  }
}

Future<void> spawnServer() async {
  if (serverIsolate != null) return; // already running
  final receivePort = ReceivePort();
  final config = ServerConfig(9999, receivePort.sendPort);
  serverIsolate = await Isolate.spawn(startApiServer, config);
  appLogger.i('API Server spawned on port 9999');
}

void killServer() {
  serverIsolate?.kill(priority: Isolate.immediate);
  serverIsolate = null;
  appLogger.i('API Server stopped');
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await ConfigService.initialize();

  if (PlatformUtils.isDesktop) {
    // Detect first run BEFORE acquireLock() creates the lock file
    final isFirstRun = !File(_lockFilePath).existsSync();

    // Single-instance check via lock file + PID
    if (!acquireLock()) {
      appLogger.i('Another instance is already running (lock file), exiting.');
      exit(0);
    }
    // Clean up lock file when process exits
    ProcessSignal.sigint.watch().listen((_) { releaseLock(); exit(0); });

    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(
      size: Size(360, 640),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: true,
      titleBarStyle: TitleBarStyle.hidden,
      alwaysOnTop: true,
    );

    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.hide();
    });

    // Auto-startup: enable by default on first run.
    // User can toggle off via UI — that choice is persisted in the registry.
    launchAtStartup.setup(
      appName: 'MinIO Sync',
      appPath: Platform.resolvedExecutable,
    );
    if (isFirstRun) {
      await launchAtStartup.enable();
      appLogger.i('First run: auto-startup enabled');
    }

    await SystemTrayManager().init();
    await spawnServer();

    windowManager.addListener(_WindowListener());
  }

  runApp(const MinioSyncApp());
}

class _WindowListener with WindowListener {
  @override
  void onWindowBlur() {
    windowManager.hide();
  }
}

class MinioSyncApp extends StatelessWidget {
  const MinioSyncApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MinIO Sync',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.transparent,
      ),
      home: PlatformUtils.isDesktop
          ? const PopupWindow()
          : const Center(child: Text('Mobile UI Pending')),
    );
  }
}
