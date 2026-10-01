import 'dart:async';
import 'package:flutter/material.dart';

import 'services/app_info_service.dart';
import 'services/app_logger.dart';
import 'services/platform_init_service.dart';
import 'app.dart';

export 'services/widget_background_callback.dart' show backgroundCallback;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Логування версії додатку у фоні (не блокуємо показ вікна та рендеринг UI)
  unawaited(AppInfoService.getAppVersion().then((version) {
    AppLogger.i("========================================", tag: 'MAIN');
    AppLogger.i("ВЕРСІЯ ДОДАТКУ: $version", tag: 'MAIN');
    AppLogger.i("========================================", tag: 'MAIN');
  }));

  await PlatformInitService.init();

  // Не блокуємо рендеринг інтерфейсу запуском повільних нативних сервісів
  unawaited(PlatformInitService.initBackgroundServices());

  runApp(const LumenApp());
}
