import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/services/schedule_sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ScheduleSyncService Cooldown & State Tests', () {
    test('Default cooldown is 30 seconds and initial state is not fetching',
        () {
      final service = ScheduleSyncService();
      expect(service.isFetching, isFalse);
      expect(service.lastFetchTime, isNull);
      expect(service.fetchCooldown, equals(const Duration(seconds: 30)));
    });

    test('isCooldownActive returns false when no prior fetch was made', () {
      final service = ScheduleSyncService();
      expect(service.isCooldownActive(hasExistingData: true), isFalse);
    });

    test(
        'isCooldownActive returns true when within cooldown and hasExistingData is true',
        () {
      final service = ScheduleSyncService();
      service.lastFetchTime = DateTime.now();

      expect(service.isCooldownActive(force: false, hasExistingData: true),
          isTrue);
      // Forced fetch bypasses cooldown
      expect(service.isCooldownActive(force: true, hasExistingData: true),
          isFalse);
      // Empty existing data bypasses cooldown
      expect(service.isCooldownActive(force: false, hasExistingData: false),
          isFalse);
    });

    test('isCooldownActive returns false after cooldown elapses', () {
      final service = ScheduleSyncService();
      service.lastFetchTime =
          DateTime.now().subtract(const Duration(seconds: 31));

      expect(service.isCooldownActive(force: false, hasExistingData: true),
          isFalse);
    });

    test(
        'computeOldStats correctly calculates outage minutes for today and tomorrow',
        () {
      final service = ScheduleSyncService();
      final Map<String, FullSchedule> schedules = {
        'GPV1.1': FullSchedule(
          today: DailySchedule(List.filled(24, LightStatus.on)),
          tomorrow: DailySchedule(List.filled(24, LightStatus.off)),
        ),
      };

      final stats = service.computeOldStats(schedules);
      expect(stats.containsKey('GPV1.1_today'), isTrue);
      expect(stats.containsKey('GPV1.1_tomorrow'), isTrue);
      expect(stats['GPV1.1_today'], equals(0)); // All on -> 0 outage minutes
      expect(stats['GPV1.1_tomorrow'],
          equals(24 * 60)); // All off -> 1440 outage minutes
    });
  });

  group('ScheduleSyncService Lifecycle Orchestration', () {
    test('Skips fetch when cooldown is active and triggers onCooldownSkipped',
        () async {
      final service = ScheduleSyncService();
      service.lastFetchTime = DateTime.now();

      bool cooldownSkippedTriggered = false;
      bool fetchSuccessTriggered = false;

      await service.sync(
        silent: false,
        force: false,
        hasExistingData: true,
        isHistoryMode: false,
        onCooldownSkipped: () async {
          cooldownSkippedTriggered = true;
        },
        onEnsureCache: () async => true,
        onFetchStart: () {},
        onBeforeFetch: () {},
        onFetchSuccess: (_) async {
          fetchSuccessTriggered = true;
        },
        onFetchError: (_) {},
      );

      expect(cooldownSkippedTriggered, isTrue);
      expect(fetchSuccessTriggered, isFalse);
      expect(service.isFetching, isFalse);
    });

    test('Bypasses cache check when silent is true but executes onBeforeFetch',
        () async {
      final service = ScheduleSyncService();
      bool ensureCacheCalled = false;
      bool beforeFetchCalled = false;

      await service.sync(
        silent: true,
        force: false,
        hasExistingData: false,
        isHistoryMode: false,
        onCooldownSkipped: () async {},
        onEnsureCache: () async {
          ensureCacheCalled = true;
          return true;
        },
        onFetchStart: () {},
        onBeforeFetch: () {
          beforeFetchCalled = true;
        },
        onFetchSuccess: (_) async {},
        onFetchError: (_) {},
      );

      expect(ensureCacheCalled, isFalse);
      expect(beforeFetchCalled, isTrue);
    });
  });
}

