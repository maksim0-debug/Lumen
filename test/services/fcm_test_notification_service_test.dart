import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lumen/services/fcm_service.dart';
import 'package:lumen/services/fcm_test_notification_service.dart';
import 'package:lumen/services/notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late List<List<String>> shown;
  late FcmTestNotificationService service;

  RemoteMessage message(
          {Map<String, dynamic> data = const {},
          bool legacyNotification = false}) =>
      RemoteMessage(
        data: {
          'type': 'test',
          'group': 'EMERGENCY',
          'testAudience': 'emergency',
          'eventId': 'emergency_alerts:test:unique',
          'title': 'Lumen: тест каналу екстрених відключень',
          'body': 'Це тестове повідомлення.',
          ...data,
        },
        notification: legacyNotification
            ? const RemoteNotification(title: 'Legacy test', body: 'Test body')
            : null,
      );

  Map<String, Object?> storedValues() => {
        for (final key in prefs.getKeys()) key: prefs.get(key),
      };

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'selected_group': 'GPV1.1',
      'notify_emergency_outages': true,
      'notify_schedule_change': false,
      'notify_tomorrow_schedule': true,
      'last_change_notif_time_GPV2.1': 12345,
      'prev_hash_GPV2.1_today': 'saved-hash',
      'prev_date_GPV2.1_today': '08.10.2026',
      'fcm_pending_hash_GPV2.1_today': 'pending-hash',
      'fcm_pending_time_GPV2.1_today': 12340,
    });
    prefs = await SharedPreferences.getInstance();
    shown = [];
    service = FcmTestNotificationService(
      preferences: () async => prefs,
      show: (title, body) async => shown.add([title, body]),
      claim: (_) async => true,
    );
  });

  test(
      'failed legacy unsubscribe defers v2 and retries without dual subscription',
      () async {
    await prefs.setBool('notify_schedule_change', true);
    await prefs.setStringList('fcm_subscribed_topics', ['group_gpv1_1']);
    final subscribed = <String>[];
    final unsubscribed = <String>[];
    await FcmService.synchronizeTopics(prefs,
        subscribe: (topic) async => subscribed.add(topic),
        unsubscribe: (topic) async => throw StateError('Offline'));
    expect(subscribed, isNot(contains('group_gpv1_1_v2')));
    expect(
        prefs.getStringList('fcm_subscribed_topics'), contains('group_gpv1_1'));
    await FcmService.synchronizeTopics(prefs,
        subscribe: (topic) async {
          expect(unsubscribed, contains('group_gpv1_1'));
          subscribed.add(topic);
        },
        unsubscribe: (topic) async => unsubscribed.add(topic));
    expect(subscribed, contains('group_gpv1_1_v2'));
    expect(prefs.getStringList('fcm_subscribed_topics'),
        isNot(contains('group_gpv1_1')));
  });

  test(
      'emergency test displays for another group with schedule alerts disabled',
      () async {
    final before = storedValues();
    expect(await service.handleIfTest(message()), isTrue);
    expect(shown, [
      ['Lumen: тест каналу екстрених відключень', 'Це тестове повідомлення.']
    ]);
    expect(storedValues(), before);
  });

  test('disabled emergency preference suppresses only diagnostic display',
      () async {
    await prefs.setBool('notify_emergency_outages', false);
    await prefs.setBool('notify_schedule_change', true);
    expect(await service.handleIfTest(message()), isTrue);
    expect(shown, isEmpty);
  });

  test('legacy emergency topic test ignores its misleading schedule group',
      () async {
    final before = storedValues();
    expect(
        await service.handleIfTest(message(
          data: {'testAudience': null, 'group': 'GPV2.1', 'dayType': 'today'},
          legacyNotification: true,
        )),
        isTrue);
    expect(shown, [
      ['Legacy test', 'Test body']
    ]);
    expect(storedValues(), before);
  });

  test('legacy EMERGENCY envelope is treated as diagnostic without status',
      () async {
    expect(await service.handleIfTest(message(data: {'testAudience': null})),
        isTrue);
    expect(shown, hasLength(1));
  });

  test('group tests honor group selection and their respective day preference',
      () async {
    for (final scenario in [
      ['GPV1.1', 'today', false],
      ['GPV1.1', 'tomorrow', true],
      ['GPV2.1', 'tomorrow', false],
    ]) {
      shown.clear();
      expect(
          await service.handleIfTest(message(data: {
            'testAudience': 'group',
            'group': scenario[0],
            'dayType': scenario[1],
          })),
          isTrue);
      expect(shown, scenario[2] == true ? hasLength(1) : isEmpty);
    }
    await prefs.setBool('notify_schedule_change', true);
    await prefs.setBool('notify_tomorrow_schedule', false);
    shown.clear();
    await service.handleIfTest(message(data: {
      'testAudience': 'group',
      'group': 'GPV1.1',
      'dayType': 'tomorrow',
    }));
    expect(shown, isEmpty);
    await service.handleIfTest(message(data: {
      'testAudience': 'group',
      'group': 'GPV1.1',
      'dayType': 'today',
    }));
    expect(shown, hasLength(1));
  });

  test('legacy group tests retain targeting without changing schedule state',
      () async {
    final before = storedValues();
    await service.handleIfTest(message(data: {
      'testAudience': null,
      'group': 'GPV1.1',
      'dayType': 'tomorrow',
      'eventId': 'group_gpv1_1_tomorrow:test:unique',
    }, legacyNotification: true));
    expect(shown, hasLength(1));
    expect(storedValues(), before);
  });

  test('malformed tests are consumed without falling through to updates',
      () async {
    for (final data in <Map<String, dynamic>>[
      {'testAudience': 'invalid'},
      {'testAudience': 'group', 'group': 'all'},
      {'testAudience': 'group', 'group': 'GPV1.1', 'dayType': 'invalid'},
      {'title': 123},
      {'body': false},
      {'eventId': 123},
    ]) {
      expect(await service.handleIfTest(message(data: data)), isTrue);
    }
    expect(shown, isEmpty);
  });

  test('operational messages bypass diagnostic dependencies', () async {
    final isolated = FcmTestNotificationService(
      preferences: () async => throw StateError('must not load preferences'),
      show: (title, body) async => fail('must not show notification'),
    );
    for (final type in ['schedule_update', 'emergency_alert']) {
      expect(
          await isolated.handleIfTest(message(data: {'type': type})), isFalse);
    }
  });

  test('foreground tests display without broadcasting a schedule refresh',
      () async {
    final events = <RemoteMessage>[];
    final subscription = FcmService.onMessageStream.listen(events.add);
    addTearDown(subscription.cancel);
    final before = storedValues();
    await FcmService()
        .handleForegroundMessage(message(), testNotifications: service);
    await Future<void>.delayed(Duration.zero);
    expect(shown, hasLength(1));
    expect(events, isEmpty);
    expect(storedValues(), before);
  });

  test('failed diagnostic display cannot trigger a foreground refresh',
      () async {
    final events = <RemoteMessage>[];
    final subscription = FcmService.onMessageStream.listen(events.add);
    addTearDown(subscription.cancel);
    final failing = FcmTestNotificationService(
      preferences: () async => prefs,
      claim: (_) async => true,
      show: (title, body) async =>
          throw StateError('notification plugin unavailable'),
    );
    await FcmService()
        .handleForegroundMessage(message(), testNotifications: failing);
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);
  });

  test('opening a diagnostic notification never broadcasts an update',
      () async {
    final events = <RemoteMessage>[];
    final subscription = FcmService.onMessageStream.listen(events.add);
    addTearDown(subscription.cancel);
    final before = storedValues();
    await FcmService().handleNotificationOpened(message());
    await FcmService().handleNotificationOpened(message(data: {
      'group': 'GPV2.1',
      'testAudience': null,
    }));
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);
    expect(storedValues(), before);
  });

  test('legacy background tests skip Firebase and preserve operational keys',
      () async {
    final before = storedValues();
    var initialized = false;
    await handleFcmBackgroundMessage(
      message(
          data: {'group': 'GPV2.1', 'testAudience': null},
          legacyNotification: true),
      testNotifications: service,
      initializeFirebase: () async {
        initialized = true;
        throw StateError(
            'diagnostic must not initialize schedule dependencies');
      },
    );
    expect(initialized, isFalse);
    expect(shown, isEmpty); // The legacy notification was displayed by the OS.
    expect(storedValues(), before);
  });

  test('data-only background test displays once without initializing Firebase',
      () async {
    final before = storedValues();
    var initialized = false;
    await handleFcmBackgroundMessage(message(), testNotifications: service,
        initializeFirebase: () async {
      initialized = true;
      throw StateError('diagnostic must not initialize schedule dependencies');
    });
    expect(initialized, isFalse);
    expect(shown, hasLength(1));
    expect(storedValues(), before);
  });

  test('notification clicks and already displayed tests do not claim an event',
      () async {
    final isolated = FcmTestNotificationService(
      preferences: () async => throw StateError('must not load preferences'),
      claim: (_) async => fail('must not claim event'),
    );
    expect(await isolated.handleIfTest(message(), notify: false), isTrue);
  });

  test('replayed diagnostic IDs display once using the real event guard',
      () async {
    final deduplicating = FcmTestNotificationService(
      preferences: () async => prefs,
      show: (title, body) async => shown.add([title, body]),
    );
    await deduplicating.handleIfTest(message());
    await deduplicating.handleIfTest(message());
    expect(shown, hasLength(1));
    expect(prefs.getStringList('fcm_received_event_ids'),
        ['emergency_alerts:test:unique']);
    expect(prefs.getInt('last_change_notif_time_GPV2.1'), 12345);
    expect(prefs.getString('fcm_pending_hash_GPV2.1_today'), 'pending-hash');
  });

  test('diagnostic notification cannot replace emergency or schedule alerts',
      () {
    final operationalIds = [
      NotificationService.emergencyNotificationId,
      for (int index = 0; index < 12; index++)
        NotificationService.immediateGroupNotificationBaseId + index,
    ];
    expect(operationalIds,
        isNot(contains(NotificationService.testNotificationId)));
    expect(NotificationService.testNotificationId, greaterThan(1200000));
  });

  test('diagnostic capability supplements the actual enabled subscriptions',
      () async {
    expect(FcmService.topicsForPreferences(prefs), {
      'lumen_schedules_v1',
      'group_gpv1_1_v2_tomorrow',
      'emergency_alerts',
      'lumen_diagnostics_v1',
    });
    await prefs.setBool('notify_tomorrow_schedule', false);
    expect(FcmService.topicsForPreferences(prefs), {
      'lumen_schedules_v1',
      'emergency_alerts',
      'lumen_diagnostics_v1',
    });
    await prefs.setBool('notify_emergency_outages', false);
    expect(FcmService.topicsForPreferences(prefs), {'lumen_schedules_v1'});
    await prefs.setBool('notify_schedule_change', true);
    await prefs.setStringList('notification_groups', ['GPV1.1', 'GPV3.2']);
    expect(FcmService.topicsForPreferences(prefs), {
      'lumen_schedules_v1',
      'group_gpv1_1_v2',
      'group_gpv3_2_v2',
      'lumen_diagnostics_v1',
    });
  });
}
