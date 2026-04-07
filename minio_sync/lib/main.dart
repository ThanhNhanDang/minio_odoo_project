import 'dart:io' show Platform;
import 'dart:isolate';
import 'package:flutter/material.dart';
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

    // Auto-startup registration
    launchAtStartup.setup(
      appName: 'MinIO Sync',
      appPath: Platform.resolvedExecutable,
    );

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
