import 'package:flutter/widgets.dart';
import 'achievement_service.dart';
import 'app_logger.dart';
import 'android_fetch_diagnostics.dart';
import 'parser_service.dart';
import 'widget_service.dart';

@pragma('vm:entry-point')
Future<void> backgroundCallback(Uri? uri) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (uri?.host == 'refresh') {
    await AndroidFetchDiagnostics.instance.run(
        source: 'widget_refresh',
        execution: 'widget_background',
        action: () async {
          AppLogger.d("Refresh triggered from widget", tag: 'Background');
          // Трекер для ачівки "Завжди перед очима"
          try {
            AchievementService().trackWidgetOpen();
          } catch (_) {}
          final widgetService = WidgetService();
          try {
            final parser = ParserService.background();
            final allSchedules = await parser.fetchAllSchedules();
            if (allSchedules.isNotEmpty) {
              AndroidFetchDiagnostics.current?.event('widget_fetch_result', {
                'groups': allSchedules.length,
              });
              await widgetService.updateWidget(allSchedules);
            } else {
              AndroidFetchDiagnostics.current?.event(
                  'widget_fetch_result', {'groups': 0},
                  level: AppLogLevel.warning);
              await widgetService.clearAllLoadingStates();
            }
          } catch (e) {
            AndroidFetchDiagnostics.current?.event(
                'widget_fetch_error', AndroidFetchDiagnostics.errorFields(e),
                level: AppLogLevel.error);
            AppLogger.e("Error refreshing widget", tag: 'Background', error: e);

            await widgetService.clearAllLoadingStates();
          }
        });
  }
}
