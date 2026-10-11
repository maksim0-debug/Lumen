import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/achievement.dart';
import 'package:lumen/services/achievement_service.dart';
import 'package:lumen/services/history_service.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _PathProvider extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  final String path;
  _PathProvider(this.path);
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'widget tracker persists always_visible and repeated entry is idempotent',
      () async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final directory =
        await Directory.systemTemp.createTemp('lumen_widget_achievement_');
    final previousProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _PathProvider(directory.path);
    final achievements = AchievementService();
    final unlocked = <AchievementDef>[];
    void listener(AchievementDef achievement) => unlocked.add(achievement);
    achievements.addAchievementListener(listener);
    try {
      expect(await achievements.isUnlocked('always_visible'), false);
      await achievements.trackWidgetOpen();
      await achievements.trackWidgetOpen();
      expect(await achievements.isUnlocked('always_visible'), true);
      final db = await HistoryService().database;
      final rows = await db.query('achievements',
          where: 'achievement_id = ?', whereArgs: ['always_visible']);
      expect(rows, hasLength(1));
      expect(rows.single['unlocked'], 1);
      expect(rows.single['progress'], 1.0);
      expect(rows.single['unlocked_at'], isNotNull);
      expect(unlocked.map((achievement) => achievement.id), ['always_visible']);
    } finally {
      achievements.removeAchievementListener(listener);
      await HistoryService().close();
      PathProviderPlatform.instance = previousProvider;
      await directory.delete(recursive: true);
    }
  });
}
