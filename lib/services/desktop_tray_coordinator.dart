import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'api/local_api_service.dart';

class DesktopTrayCoordinator with WindowListener, TrayListener {
  Future<void> init() async {
    if (Platform.isWindows) {
      windowManager.addListener(this);
      trayManager.addListener(this);
      await _initTray();
    }
  }

  void dispose() {
    if (Platform.isWindows) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
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
  void onTrayIconMouseDown() => windowManager.show();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    if (menuItem.key == 'show_window') {
      windowManager.show();
      windowManager.focus();
    } else if (menuItem.key == 'exit_app') {
      await LocalApiService().stop();
      windowManager.destroy();
    }
  }

  @override
  void onWindowClose() async {
    if (await windowManager.isPreventClose()) windowManager.hide();
  }
}
