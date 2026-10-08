import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:lumen/models/emergency_status.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/models/schedule_view_mode.dart';
import 'package:lumen/services/emergency_status_service.dart';
import 'package:lumen/ui/state/home_notifier.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'emergency updates independently in archive view and keeps schedule forecasts available',
      () async {
    SharedPreferences.setMockInitialValues({'notify_emergency_outages': false});
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    final statusService = EmergencyStatusService.forTesting(() async => db);
    final container = ProviderContainer(overrides: [
      homeNotifierProvider.overrideWith(
          () => HomeNotifier(emergencyStatusService: statusService)),
    ]);
    try {
      final notifier = container.read(homeNotifierProvider.notifier);
      final schedule = DailySchedule.fromEncodedString('1' * 24);
      notifier.state = notifier.state.copyWith(
          viewMode: ScheduleViewMode.history,
          historySchedule: schedule,
          currentDisplaySchedule: schedule,
          isLoading: false);
      final now = DateTime.now().millisecondsSinceEpoch;
      await statusService.observe(EmergencyObservation(true, now,
          isPossible: true,
          noticeText: 'Аварійні відключення у Бучанському районі.'));
      await Future<void>.delayed(Duration.zero);
      final active = container.read(homeNotifierProvider);
      expect(active.isEmergencyActive, true);
      expect(active.isEmergencyStatusStale, false);
      expect(active.isEmergencyPossible, true);
      expect(active.emergencyNoticeText,
          'Аварійні відключення у Бучанському районі.');
      expect(active.viewMode, ScheduleViewMode.history);
      expect(identical(active.currentDisplaySchedule, schedule), true);
      expect(active.hasDisplayData, true);
      await statusService
          .observe(EmergencyObservation(false, now + 1, confirmed: true));
      await Future<void>.delayed(Duration.zero);
      expect(container.read(homeNotifierProvider).isEmergencyActive, false);
      expect(container.read(homeNotifierProvider).emergencyNoticeText, isEmpty);
      expect(container.read(homeNotifierProvider).hasDisplayData, true);
    } finally {
      container.dispose();
      await db.close();
    }
  });
}
