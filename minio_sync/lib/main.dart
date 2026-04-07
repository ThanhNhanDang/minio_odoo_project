import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'utils/platform_utils.dart';
import 'utils/logger.dart';
import 'services/config_service.dart';
import 'ui/tray/tray_manager.dart';
import 'ui/popup/popup_window.dart';
import 'server/api_server.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Initialize Configuration
  await ConfigService.initialize();
  
  if (PlatformUtils.isDesktop) {
    // 2. Initialize Window Manager
    await windowManager.ensureInitialized();
    WindowOptions windowOptions = const WindowOptions(
      size: Size(360, 600),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: true, // Crucial for tray-only apps
      titleBarStyle: TitleBarStyle.hidden,
      alwaysOnTop: true,
    );
    
    // Start hidden, only show when clicking tray
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.hide();
    });

    // 3. Initialize Tray
    await SystemTrayManager().init();

    // 4. Start HTTP Server in Isolate
    final ReceivePort receivePort = ReceivePort();
    final config = ServerConfig(9999, receivePort.sendPort);
    await Isolate.spawn(startApiServer, config);
    appLogger.i('Spawning API Server on port 9999');

    // 5. Hide window when losing focus
    windowManager.addListener(_WindowListener());
  } else {
    // Mobile Background Service INIT here
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
        scaffoldBackgroundColor: Colors.transparent, // Enables host OS transparency
      ),
      home: PlatformUtils.isDesktop 
          ? const PopupWindow() 
          : const Center(child: Text('Mobile UI Pending')), // Placeholder for Home Mobile
    );
  }
}
