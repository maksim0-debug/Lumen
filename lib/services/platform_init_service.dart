import 'dart:async';
import 'dart:io';
import 'package:window_manager/window_manager.dart';

import 'api/local_api_service.dart';
import 'app_logger.dart';
import 'background_service.dart';
import 'desktop_sync_service.dart';
import 'desktop_tray_coordinator.dart';
import 'fcm_service.dart';
import 'notification_service.dart';
import 'windows_startup_service.dart';

class PlatformInitService {
  static Future<void> init([List<String> arguments = const []]) async {
    if (Platform.isWindows) {
      try {
        await windowManager.ensureInitialized();
        WindowOptions windowOptions = const WindowOptions(
          skipTaskbar: false,
          title: "Люмен",
        );
        await windowManager.waitUntilReadyToShow(windowOptions);
        try {
          await WindowsStartupService.instance.initialize();
        } catch (e) {
          AppLogger.e('Cannot initialize Windows startup registration',
              tag: 'MAIN', error: e);
        }
        bool trayAvailable = false;
        try {
          await DesktopTrayCoordinator().init();
          trayAvailable = true;
        } catch (e) {
          AppLogger.e('Cannot initialize Windows tray', tag: 'MAIN', error: e);
        }
        await windowManager.setPreventClose(trayAvailable);
        await WindowsStartupService.instance.showInitialWindow(
            arguments: arguments, trayAvailable: trayAvailable);
      } catch (e) {
        AppLogger.e("Помилка Window Manager", tag: 'MAIN', error: e);
        try {
          await windowManager.show();
          await windowManager.focus();
        } catch (fallbackError) {
          AppLogger.e('Cannot show Windows startup recovery window',
              tag: 'MAIN', error: fallbackError);
        }
      }
    }
  }

  static Future<void> initBackgroundServices() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      try {
        await LocalApiService().init();
      } catch (e) {
        AppLogger.e("Помилка ініціалізації Local REST API",
            tag: 'MAIN', error: e);
      }

      try {
        await DesktopSyncService().init();
      } catch (e) {
        AppLogger.e("Помилка ініціалізації DesktopSyncService",
            tag: 'MAIN', error: e);
      }
    }

    try {
      final notificationService = NotificationService();
      await notificationService.init().timeout(const Duration(seconds: 4));
    } catch (e) {
      AppLogger.e("Помилка сповіщень", tag: 'MAIN', error: e);
    }

    if (Platform.isAndroid || Platform.isIOS) {
      try {
        await FcmService().init();
      } catch (e) {
        AppLogger.e("Помилка ініціалізації FCM", tag: 'MAIN', error: e);
      }
    }

    if (Platform.isAndroid) {
      try {
        final bgManager = BackgroundManager();
        await bgManager.init().timeout(const Duration(seconds: 4));
        bgManager.registerPeriodicTask();
      } catch (e) {
        AppLogger.e("Помилка Background", tag: 'MAIN', error: e);
      }
    }
  }
}
