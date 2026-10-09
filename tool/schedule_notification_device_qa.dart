// This executable is a device test harness for the production FCM entry points.
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lumen/models/schedule_change_event.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/services/dtek_snapshot.dart';
import 'package:lumen/services/fcm_service.dart';
import 'package:lumen/services/history_service.dart';
import 'package:lumen/services/notification_service.dart';
import 'package:lumen/services/parser_service.dart';
import 'package:lumen/services/schedule_change_notification_service.dart';
import 'package:lumen/services/schedule_change_notification_store.dart';
import 'package:lumen/services/schedule_clock.dart';

/// Run in a separate Android application ID; never touches the user's Lumen DB.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: _DeviceQa()));
}

class _DeviceQa extends StatefulWidget {
  const _DeviceQa();
  @override
  State<_DeviceQa> createState() => _DeviceQaState();
}

class _DeviceQaState extends State<_DeviceQa> {
  final results = <String>[];
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => runScenarios());
  }

  void require(bool condition, String message) {
    if (!condition) throw StateError(message);
  }

  Future<void> runScenarios() async {
    final plugin = FlutterLocalNotificationsPlugin();
    final db = await HistoryService().database;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_group', 'GPV2.1');
    await prefs.setStringList('notification_groups', ['GPV2.1']);
    await prefs.setBool('notify_schedule_change', true);
    await prefs.setBool('notify_tomorrow_schedule', true);
    await prefs.setBool('fcm_initialized', true);
    await prefs.setStringList('fcm_subscribed_topics',
        ['group_gpv2_1_v2', 'group_gpv2_1_v2_tomorrow']);
    await NotificationService().init(requestPermissions: false);
    final now = ScheduleClock.now();
    final midnight = ScheduleClock.day(now);
    final date = DtekSnapshot.notificationDate('today', now: now);
    final tomorrowDate = DtekSnapshot.notificationDate('tomorrow', now: now);
    const a = '111111000000000000000000';
    const b = '111111110000000000000000';
    const c = '011111000000000000000000';
    final store = ScheduleChangeNotificationStore(database: () async => db);
    var displays = 0;
    var failDisplay = false;
    final service = ScheduleChangeNotificationService(
        store: store,
        now: () => now,
        show: (claim) async {
          if (failDisplay) {
            throw StateError('Injected platform display failure');
          }
          final e = claim.event;
          await NotificationService().showImmediate(
              e.title(), e.body(claim.previousHash),
              groupName: e.group,
              notificationId:
                  NotificationService.immediateGroupNotificationBaseId +
                      2 +
                      (e.dayType == 'tomorrow' ? 100 : 0),
              notificationTag: claim.identity,
              onlyAlertOnce: true,
              rethrowOnError: true);
          displays++;
        });
    ScheduleChangeEvent event(String hash, int revision,
            {bool tomorrow = false}) =>
        ScheduleChangeEvent(
            group: 'GPV2.1',
            targetDate: tomorrow ? tomorrowDate : date,
            sourceVersion: midnight.millisecondsSinceEpoch + revision * 1000,
            hash: hash,
            dayType: tomorrow ? 'tomorrow' : 'today');
    Map<String, dynamic> push(ScheduleChangeEvent e) => {
          'type': 'schedule_updated',
          'schemaVersion': '2',
          'group': e.group,
          'targetDate': e.targetDate,
          'sourceVersion': '${e.sourceVersion}',
          'scheduleHash': e.hash,
          'dayType': e.dayType,
          'eventId': e.id,
        };
    Future<void> reset() async {
      await plugin.cancelAll();
      await db.delete('schedule_notification_state');
      displays = 0;
      failDisplay = false;
    }

    Future<void> report(String name) async {
      results.add('PASS: $name');
      debugPrint('LUMEN_NOTIFICATION_QA: PASS $name');
      if (mounted) setState(() {});
    }

    try {
      // A full 12-group DTEK-shaped payload goes through the production validator.
      final fact = {
        'today': midnight.millisecondsSinceEpoch ~/ 1000,
        'update':
            '${midnight.day.toString().padLeft(2, '0')}.${midnight.month.toString().padLeft(2, '0')}.${midnight.year} 00:00:01',
        'data': {
          '${midnight.millisecondsSinceEpoch ~/ 1000}': {
            for (final group in ParserService.allGroups)
              group: {
                for (var i = 0; i < 24; i++)
                  '${i + 1}': a[i] == '1' ? 'no' : 'yes',
              },
          }
        }
      };
      final snapshot = DtekSnapshot.parse(
          jsonEncode(fact), ParserService.allGroups,
          now: now);
      require(snapshot.schedules['GPV2.1']!.today.totalOutageMinutes == 360,
          'Source validation');
      await reset();
      await service.observeSchedules(snapshot.schedules);
      final changedFact = {
        ...fact,
        'update':
            (fact['update'] as String).replaceFirst('00:00:01', '00:00:02'),
        'data': {
          '${midnight.millisecondsSinceEpoch ~/ 1000}': {
            for (final group in ParserService.allGroups)
              group: {
                for (var i = 0; i < 24; i++)
                  '${i + 1}': c[i] == '1' ? 'no' : 'yes',
              },
          }
        }
      };
      final changed = DtekSnapshot.parse(
          jsonEncode(changedFact), ParserService.allGroups,
          now: now);
      await service.observeSchedules(changed.schedules);
      require(
          displays == 1, 'Polling must notify immediately with FCM configured');
      await handleFcmBackgroundMessage(RemoteMessage(data: push(event(c, 2))),
          scheduleChanges: service,
          initializeFirebase: () async {},
          refreshSchedules: () async {});
      require(displays == 1, 'Late background FCM repeated local fallback');
      final active = await plugin.getActiveNotifications();
      require(active.length == 1, 'Android shade contains a duplicate');
      require(active.single.title == 'Графік змінено! (Група 2.1)',
          'Group title mismatch');
      require(active.single.body == 'Світла стало БІЛЬШЕ на 1 год. 🎉',
          'Delta mismatch');
      await report(
          '6 → 5 immediate local polling + late FCM: one Android notification');

      await reset();
      await store.observe(event(a, 1),
          nowMs: now.millisecondsSinceEpoch, handled: true);
      await FcmService().handleForegroundMessage(
          RemoteMessage(data: push(event(b, 2))),
          scheduleChanges: service);
      await service.handlePush(push(event(a, 3)));
      await service.handlePush(push(event(a, 3)));
      require(displays == 2, '6 → 8 → 6 lost a change or repeated a delivery');
      require((await plugin.getActiveNotifications()).length == 2,
          'Real transitions missing from Android shade');
      await report('6 → 8 → 6: two distinct Android notifications');

      await reset();
      await store.observe(event('1${'0' * 23}', 1),
          nowMs: now.millisecondsSinceEpoch, handled: true);
      await service.handlePush(push(event('01${'0' * 22}', 2)));
      require(
          (await plugin.getActiveNotifications()).single.body ==
              'Змінився час відключень на сьогодні ⚡',
          'Equal-duration shift missed');
      await report('Equal outage duration, shifted hours: change displayed');

      await reset();
      await service.acknowledge(event(b, 2));
      await service.handlePush(push(event(b, 2)));
      require(displays == 0 && (await plugin.getActiveNotifications()).isEmpty,
          'Viewed graph repeated');
      await report('Viewed schedule + late push: no Android notification');

      await reset();
      await Future.wait(
          List.generate(20, (_) => service.handlePush(push(event(b, 2)))));
      require(
          displays == 1 && (await plugin.getActiveNotifications()).length == 1,
          'Concurrent duplicate display');
      await report(
          '20 concurrent deliveries: one SQLite winner and one Android notification');

      await reset();
      await service.handlePush(push(event(b, 2)));
      await service.handlePush(push(event(c, 2, tomorrow: true)));
      final publications = await plugin.getActiveNotifications();
      require(displays == 2 && publications.length == 2,
          'Today/tomorrow collision');
      require(
          publications
              .map((notification) => notification.body)
              .toSet()
              .containsAll({
            'Заплановано відключень: 8 год. ⚡',
            'Заплановано відключень: 5 год. ⚡',
          }),
          'Initial publication hours contain a trailing decimal zero');
      await report(
          'Today and tomorrow remain independent with formatted hours');

      await reset();
      await store.observe(event(a, 1),
          nowMs: now.millisecondsSinceEpoch, handled: true);
      failDisplay = true;
      var refreshes = 0;
      await handleFcmBackgroundMessage(RemoteMessage(data: push(event(b, 2))),
          scheduleChanges: service,
          initializeFirebase: () async {}, refreshSchedules: () async {
        refreshes++;
      });
      require(
          refreshes == 1 &&
              displays == 0 &&
              (await plugin.getActiveNotifications()).isEmpty,
          'Failed background display did not queue recovery');
      final pending = (await db.query('schedule_notification_state')).single;
      require(pending['pending_since'] != null && pending['claim_key'] == null,
          'Failure consumed the event or retained its lease');
      failDisplay = false;
      await service.handlePush(push(event(b, 2)));
      await service.handlePush(push(event(b, 2)));
      require(
          displays == 1 && (await plugin.getActiveNotifications()).length == 1,
          'Recovered delivery missing or duplicated');
      await report(
          'Failed background display queues recovery and retries once');

      await reset();
      await store.observe(event(a, 1),
          nowMs: now.millisecondsSinceEpoch, handled: true);
      await store.observe(event(a, 0, tomorrow: true),
          nowMs: now.millisecondsSinceEpoch, handled: true);
      final sourceDate =
          '${now.day.toString().padLeft(2, '0')}.${now.month.toString().padLeft(2, '0')}.${now.year}';
      await service.observeSchedules({
        'GPV2.1': FullSchedule(
          today: DailySchedule.fromEncodedString(b),
          tomorrow: DailySchedule.fromEncodedString(c),
          lastUpdatedSource: '$sourceDate 00:00:01',
        ),
      });
      require(
          displays == 1 && (await plugin.getActiveNotifications()).length == 1,
          'Conflicting today blocked tomorrow');
      require(
          (await db.query('schedule_notification_state',
                      where: 'target_date = ?', whereArgs: [date]))
                  .single['schedule_hash'] ==
              a,
          'Conflict overwrote the accepted source version');
      await report('Conflicting today is rejected without blocking tomorrow');
      debugPrint('LUMEN_NOTIFICATION_QA: COMPLETE ${results.length} passed');
    } catch (error, stack) {
      results.add('FAIL: $error');
      debugPrint('LUMEN_NOTIFICATION_QA: FAIL $error\n$stack');
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Lumen notification QA')),
      body: ListView(
          children:
              results.map((value) => ListTile(title: Text(value))).toList()));
}
