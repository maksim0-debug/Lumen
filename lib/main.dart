import 'dart:async';
import 'package:flutter/material.dart';

import 'services/app_logger.dart';
import 'services/platform_init_service.dart';
import 'app.dart';

export 'services/widget_background_callback.dart' show backgroundCallback;

void main() async {
  AppLogger.i("========================================", tag: 'MAIN');
  AppLogger.i("ВЕРСІЯ ДОДАТКУ: 2.3.4 (Fix Saving & UI)", tag: 'MAIN');
  AppLogger.i("========================================", tag: 'MAIN');
  WidgetsFlutterBinding.ensureInitialized();

  await PlatformInitService.init();

  // Не блокуємо рендеринг інтерфейсу запуском повільних нативних сервісів
  unawaited(PlatformInitService.initBackgroundServices());

  runApp(const LumenApp());
}