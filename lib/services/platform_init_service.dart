import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:home_widget/home_widget.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:window_manager/window_manager.dart';

import 'app_info_service.dart';
import 'app_logger.dart';
import 'background_service.dart';
import 'notification_service.dart';
import 'widget_background_callback.dart';

class PlatformInitService {
  static Future<void> init() async {
    if (Platform.isAndroid) {
      HomeWidget.registerInteractivityCallback(backgroundCallback);
    }

    if (Platform.isWindows) {
      try {
        await windowManager.ensureInitialized();
        WindowOptions windowOptions = const WindowOptions(
          size: Size(900, 600),
          center: true,
          skipTaskbar: false,
          title: "Люмен",
        );
        await windowManager.waitUntilReadyToShow(windowOptions, () async {
          await windowManager.show();
          await windowManager.focus();
          await windowManager.setPreventClose(true);
        });
      } catch (e) {
        AppLogger.e("Помилка Window Manager", tag: 'MAIN', error: e);
      }
    }
  }

  static Future<void> initBackgroundServices() async {
    if (Platform.isWindows) {
      try {
        final packageInfo = await AppInfoService.getPackageInfo();

        if (packageInfo.appName != "Lumen") {
          launchAtStartup.setup(
            appName: packageInfo.appName,
            appPath: Platform.resolvedExecutable,
          );
          await launchAtStartup.disable();
        }

        launchAtStartup.setup(
          appName: "Lumen",
          appPath: Platform.resolvedExecutable,
        );
      } catch (e) {
        AppLogger.e("Помилка автозапуску", tag: 'MAIN', error: e);
      }
    }

    try {
      final notificationService = NotificationService();
      await notificationService.init().timeout(const Duration(seconds: 4));
    } catch (e) {
      AppLogger.e("Помилка сповіщень", tag: 'MAIN', error: e);
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
