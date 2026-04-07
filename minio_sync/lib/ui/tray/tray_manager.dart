import 'dart:io';
import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:screen_retriever/screen_retriever.dart';
import '../../utils/logger.dart';

class SystemTrayManager with TrayListener {
  static final SystemTrayManager _instance = SystemTrayManager._internal();
  factory SystemTrayManager() => _instance;
  SystemTrayManager._internal();

  Future<void> init() async {
    appLogger.i('Initializing Tray Manager');
    trayManager.addListener(this);
    
    // Use a placeholder icon for now (needs proper .ico or .png depending on platform)
    // You will need to put app_icon.ico in assets and configure pubspec
    // await trayManager.setIcon(Platform.isWindows ? 'assets/app_icon.ico' : 'assets/app_icon.png');
    
    // Fallback: Tooltip
    await trayManager.setToolTip('Odoo MinIO Sync');
  }

  @override
  void onTrayIconMouseDown() {
    _toggleWindow();
  }

  @override
  void onTrayIconRightMouseDown() async {
    // Show native context menu
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'settings', label: 'Settings'),
          MenuItem.separator(),
          MenuItem(key: 'exit', label: 'Quit'),
        ],
      )
    );
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'exit') {
      exit(0);
    } else if (menuItem.key == 'settings') {
      _toggleWindow();
    }
  }

  Future<void> _toggleWindow() async {
    bool isVisible = await windowManager.isVisible();
    if (isVisible) {
      await windowManager.hide();
    } else {
      await _positionWindow();
      await windowManager.show();
      await windowManager.focus();
    }
  }

  Future<void> _positionWindow() async {
    // Calculates cursor position to simulate WARP popup placement near the tray
    Offset cursorPosition = await screenRetriever.getCursorScreenPoint();
    Size windowSize = await windowManager.getSize();
    
    // Find absolute bounds (bottom right for typical Windows/Linux tray, top right for macOS)
    // Simply position it offset from cursor initially:
    double x = cursorPosition.dx - (windowSize.width / 2);
    double y = cursorPosition.dy - windowSize.height - 20;

    // In a real app we query Primary Display bounds to snap into corners properly
    Display primaryDisplay = await screenRetriever.getPrimaryDisplay();
    if (y < 0) { // e.g. MacOS menu bar at top
       y = cursorPosition.dy + 20;
    } 

    await windowManager.setPosition(Offset(x, y));
  }
}
