import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'api/local_api_service.dart';
import 'desktop_sync_service.dart';
import 'app_logger.dart';

class DesktopTrayCoordinator with WindowListener, TrayListener {
  DesktopTrayCoordinator._();
  static final _instance = DesktopTrayCoordinator._();
  factory DesktopTrayCoordinator() => _instance;

  bool _initialized = false;

  Future<void> init() async {
    if (Platform.isWindows && !_initialized) {
      await _initTray();
      windowManager.addListener(this);
      trayManager.addListener(this);
      _initialized = true;
    }
  }

  void dispose() {
    DesktopSyncService().dispose();
    if (Platform.isWindows) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
      _initialized = false;
    }
    LocalApiService().stop();
  }

  Future<void> _initTray() async {
    if (Platform.isWindows) {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final iconPath = p.join(exeDir, 'app_icon.ico');
      await trayManager.setIcon(iconPath);
      Menu menu = Menu(items: [
        MenuItem(key: 'show_window', label: 'Відкрити'),
        MenuItem.separator(),
        MenuItem(key: 'exit_app', label: 'Закрити'),
      ]);
      await trayManager.setContextMenu(menu);
      await trayManager.setToolTip('Люмен');
    }
  }

  @override
  void onTrayIconMouseDown() => _showWindow();

  Future<void> _showWindow() async {
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (error, stack) {
      AppLogger.e('Cannot restore the window from the tray',
          tag: 'WindowsTray', error: error, stackTrace: stack);
    }
  }

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    if (menuItem.key == 'show_window') {
      await _showWindow();
    } else if (menuItem.key == 'exit_app') {
      DesktopSyncService().dispose();
      await LocalApiService().stop();
      windowManager.destroy();
    }
  }

  @override
  void onWindowClose() async {
    if (await windowManager.isPreventClose()) windowManager.hide();
  }
}
