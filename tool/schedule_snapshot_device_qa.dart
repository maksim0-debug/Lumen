// Isolated Android harness. It uses production ingestion and platform effects,
// but subscribes only to the random QA topic supplied by the test runner.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:convert';
import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:home_widget/home_widget.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lumen/services/background_service.dart';
import 'package:lumen/services/fcm_service.dart';
import 'package:lumen/services/history_service.dart';
import 'package:lumen/services/notification_service.dart';
import 'package:lumen/services/worker_schedule_service.dart';
import 'package:lumen_schedule_widgets/lumen_schedule_widgets.dart';

Future<void> _record(RemoteMessage message, String mode,
    {Object? error}) async {
  final db = await HistoryService().database;
  final docs = await getApplicationDocumentsDirectory();
  final snapshot = message.data['snapshot'];
  final parsed = snapshot is String ? jsonDecode(snapshot) as Map : null;
  final evidence = {
    'receivedAt': DateTime.now().toUtc().toIso8601String(),
    'mode': mode,
    'sequence': parsed?['sequence'],
    'sourceVersion': parsed?['sourceVersion'],
    'historyRows':
        (await db.rawQuery('SELECT COUNT(*) AS n FROM schedule_history'))
            .single['n'],
    'current': {
      for (final e in (await HistoryService().getLastKnownSchedules()).entries)
        e.key: [e.value.today.scheduleHash, e.value.tomorrow.scheduleHash]
    },
    'localWork': await db.query('schedule_local_work'),
    'notifications': await db.query('schedule_notification_state'),
    'widget': await HomeWidget.getWidgetData<String>('schedule_snapshot'),
    'scheduledReminders':
        (await FlutterLocalNotificationsPlugin().pendingNotificationRequests())
            .length,
    if (error != null) 'error': error.toString(),
  };
  // Separate immutable files avoid cross-isolate evidence append races.
  await File(
          '${docs.path}/snapshot_qa_${DateTime.now().microsecondsSinceEpoch}.json')
      .writeAsString(jsonEncode(evidence), flush: true);
}

@pragma('vm:entry-point')
Future<void> snapshotQaBackground(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await handleFcmBackgroundMessage(message, refreshSchedules: () async {},
      initializeFirebase: () async {
    await Firebase.initializeApp();
  });
  await _record(message, 'background');
}

Future<void> runSnapshotQa() async {
  WidgetsFlutterBinding.ensureInitialized();
  const topic = String.fromEnvironment('QA_TOPIC');
  if (!RegExp(r'^lumen_snapshot_qa_[a-f0-9]{32}$').hasMatch(topic)) {
    throw ArgumentError('A unique isolated QA_TOPIC is required');
  }
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(snapshotQaBackground);
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList('notification_groups', ['GPV2.1']);
  await prefs.setString('selected_group', 'GPV2.1');
  await prefs.setBool('notify_schedule_change', true);
  await prefs.setBool('notify_tomorrow_schedule', true);
  await NotificationService().init(requestPermissions: false);
  await BackgroundManager().init();
  await FirebaseMessaging.instance.requestPermission();
  await FirebaseMessaging.instance.subscribeToTopic(topic);
  await const MethodChannel('lumen/snapshot_qa')
      .invokeMethod<void>('bindWidgets');
  const MethodChannel('lumen/snapshot_qa').setMethodCallHandler((call) async {
    if (call.method != 'qaCommand') return;
    final docs = await getApplicationDocumentsDirectory();
    if (call.arguments == 'recover_api') {
      await WorkerScheduleService().fetch();
      await applyPendingSchedules();
      await _record(const RemoteMessage(), 'api_recovery');
    } else if (call.arguments == 'retry_local') {
      await applyPendingSchedules();
      await _record(const RemoteMessage(), 'local_retry');
    } else if (call.arguments == 'native_watermark') {
      final raw = await HomeWidget.getWidgetData<String>('schedule_snapshot');
      final original = jsonDecode(raw!) as Map<String, dynamic>;
      final manual = jsonDecode(raw) as Map<String, dynamic>;
      final groups = manual['groups'] as Map;
      groups['GPV2.1'] = ['1' * 24, '0' * 24];
      manual['sourceVersion'] = 0;
      manual['sourceUpdatedAt'] = '10:00 (Manual)';
      await LumenScheduleWidgets.applySnapshot(jsonEncode(manual));
      final old = jsonDecode(raw) as Map<String, dynamic>;
      old['sourceVersion'] = (original['sourceVersion'] as int) - 60000;
      await LumenScheduleWidgets.applySnapshot(jsonEncode(old));
      final actual = jsonDecode(
              (await HomeWidget.getWidgetData<String>('schedule_snapshot'))!)
          as Map;
      if ((actual['groups'] as Map)['GPV2.1'][0] != '1' * 24) {
        throw StateError('An older widget writer replaced a manual edit');
      }
      await LumenScheduleWidgets.applySnapshot(raw);
      await File('${docs.path}/snapshot_qa_native_watermark.json')
          .writeAsString(jsonEncode({'passed': true}), flush: true);
    }
  });
  FirebaseMessaging.onMessage.listen((message) async {
    Object? error;
    try {
      await handleSnapshotPush(message.data, recover: () async {});
    } catch (e) {
      error = e;
    }
    await _record(message, 'foreground', error: error);
  });
  final docs = await getApplicationDocumentsDirectory();
  await File('${docs.path}/snapshot_qa_ready.json').writeAsString(
      jsonEncode({
        'topic': topic,
        'readyAt': DateTime.now().toUtc().toIso8601String(),
      }),
      flush: true);
  runApp(const MaterialApp(
      home: Scaffold(
          body: Center(
              child: Text('Lumen snapshot QA\nREADY',
                  textAlign: TextAlign.center)))));
}
