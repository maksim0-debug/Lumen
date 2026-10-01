import 'package:flutter/widgets.dart';
import 'achievement_service.dart';
import 'app_logger.dart';
import 'parser_service.dart';
import 'widget_service.dart';

@pragma('vm:entry-point')
Future<void> backgroundCallback(Uri? uri) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (uri?.host == 'refresh') {
    AppLogger.d("Refresh triggered from widget", tag: 'Background');
    // Трекер для ачівки "Завжди перед очима"
    try {
      AchievementService().trackWidgetOpen();
    } catch (_) {}
    final widgetService = WidgetService();
    try {
      final parser = ParserService();
      final allSchedules = await parser.fetchAllSchedules();
      if (allSchedules.isNotEmpty) {
        await widgetService.updateWidget(allSchedules);
      } else {
        await widgetService.clearAllLoadingStates();
      }
    } catch (e) {
      AppLogger.e("Error refreshing widget", tag: 'Background', error: e);

      await widgetService.clearAllLoadingStates();
    }
  }
}
