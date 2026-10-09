import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/models/power_event.dart';
import 'package:lumen/services/parser_service.dart';
import 'package:lumen/services/schedule_sync_service.dart';
import 'package:lumen/services/schedule_clock.dart';
import 'package:lumen/services/hour_segment_service.dart';
import 'package:lumen/services/notification_service.dart';
import 'package:lumen/services/schedule_notification_coordinator.dart';
import 'package:lumen/utils/app_formatters.dart';

class SharedFetch implements ParserService {
  final Completer<ParserFetchResult> completion = Completer();
  @override
  Future<ParserFetchResult> fetchSnapshot() => completion.future;
  @override
  Future<Map<String, FullSchedule>> fetchAllSchedules() async =>
      (await completion.future).schedules;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class RecordingNotifications implements NotificationService {
  int notifications = 0;
  @override
  Future<void> showImmediate(String title, String body,
      {String? groupName,
      int? notificationId,
      String? notificationTag,
      String? payload,
      bool onlyAlertOnce = false,
      bool rethrowOnError = false}) async {
    notifications++;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('desktop and API sharing a fetch publish one completed snapshot',
      () async {
    final parser = SharedFetch();
    final desktop = ScheduleSyncService(parser: parser);
    final api = ScheduleSyncService(parser: parser);
    final events = <Map<String, FullSchedule>>[];
    final subscription = ScheduleSyncService.onSyncCompleted.listen(events.add);
    try {
      final first = desktop.fetchSnapshotAndPublish();
      final second = api.syncSchedules(force: true);
      final data = {
        'GPV1.1': FullSchedule(
            today: DailySchedule.fromEncodedString('0' * 24),
            tomorrow: DailySchedule.empty())
      };
      parser.completion.complete(ParserFetchResult(data, 'html'));
      await first;
      expect((await second).isSuccess, true);
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
      expect(identical(events.single, data), true);
    } finally {
      await subscription.cancel();
    }
  });
  test('overlapping notification passes cannot notify the same change twice',
      () async {
    SharedPreferences.setMockInitialValues({
      'prev_hash_GPV1.1_today': '0' * 24,
      'prev_date_GPV1.1_today':
          AppFormatters.formatDateKey(ScheduleClock.now()),
      'notify_schedule_change': true,
    });
    final notifier = RecordingNotifications();
    final first = ScheduleNotificationCoordinator(notifier: notifier);
    final second = ScheduleNotificationCoordinator(notifier: notifier);
    final data = {
      'GPV1.1': FullSchedule(
          today: DailySchedule.fromEncodedString('1' * 24),
          tomorrow: DailySchedule.empty())
    };
    await Future.wait([
      first.handleScheduleUpdate(allSchedules: data, currentGroup: 'GPV1.1'),
      second.handleScheduleUpdate(allSchedules: data, currentGroup: 'GPV1.1'),
    ]);
    expect(notifier.notifications, 1);
  }, skip: !Platform.isWindows);
  test('real interval clipping uses Kyiv calendar boundaries across autumn DST',
      () {
    final interval = PowerOutageInterval(
        start: DateTime.utc(2026, 10, 24, 21),
        end: DateTime.utc(2026, 10, 25, 22));
    final date = DateTime(2026, 10, 25);
    expect(
        HourSegmentService.computeRealOutageMinutes([interval], date,
            nowOverride: DateTime.utc(2026, 10, 26)),
        1500);
    expect(interval.minutesOfflineInHour(date, 0), 60);
  });
}
