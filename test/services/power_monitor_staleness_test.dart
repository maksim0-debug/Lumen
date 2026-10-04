import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/power_monitor_status.dart';
import 'package:lumen/services/power_monitor_service.dart';

void main() {
  group('PowerMonitorService parseLastSeen Tests', () {
    test('parses standard date-time string YYYY-MM-DD HH:mm:ss', () {
      final dt = PowerMonitorService.parseLastSeen("2026-10-01 07:30:00");
      expect(dt, DateTime(2026, 10, 1, 7, 30, 0));
    });

    test('parses ISO8601 string', () {
      final dt = PowerMonitorService.parseLastSeen("2026-10-01T07:30:00.000");
      expect(dt, DateTime(2026, 10, 1, 7, 30, 0));
    });

    test('parses ISO8601 string with UTC indicator Z', () {
      final dt = PowerMonitorService.parseLastSeen("2026-10-01T07:30:00Z");
      expect(dt, isNotNull);
      expect(dt!.isUtc, isTrue);
      expect(dt.year, 2026);
    });

    test('parses Unix timestamp in seconds', () {
      const seconds = 1760000000;
      final dt = PowerMonitorService.parseLastSeen(seconds);
      expect(dt, DateTime.fromMillisecondsSinceEpoch(seconds * 1000));
    });

    test('parses Unix timestamp as string number', () {
      const secondsStr = "1760000000";
      final dt = PowerMonitorService.parseLastSeen(secondsStr);
      expect(dt, DateTime.fromMillisecondsSinceEpoch(1760000000 * 1000));
    });

    test('parses Unix timestamp in milliseconds', () {
      const millis = 1760000000000;
      final dt = PowerMonitorService.parseLastSeen(millis);
      expect(dt, DateTime.fromMillisecondsSinceEpoch(millis));
    });

    test('parses Map with timestamp or last_seen key', () {
      final dt1 = PowerMonitorService.parseLastSeen(
          {"timestamp": "2026-10-01 07:30:00"});
      expect(dt1, DateTime(2026, 10, 1, 7, 30, 0));

      final dt2 = PowerMonitorService.parseLastSeen(
          {"last_seen": "2026-10-01 07:30:00"});
      expect(dt2, DateTime(2026, 10, 1, 7, 30, 0));
    });

    test('handles double timestamps including nan and infinity safely', () {
      expect(PowerMonitorService.parseLastSeen(double.nan), isNull);
      expect(PowerMonitorService.parseLastSeen(double.infinity), isNull);
      expect(
          PowerMonitorService.parseLastSeen(double.negativeInfinity), isNull);
      const seconds = 1760000000.5;
      final dt = PowerMonitorService.parseLastSeen(seconds);
      expect(dt, DateTime.fromMillisecondsSinceEpoch(1760000000500));
    });

    test('returns null for null, empty or invalid data', () {
      expect(PowerMonitorService.parseLastSeen(null), isNull);
      expect(PowerMonitorService.parseLastSeen(""), isNull);
      expect(PowerMonitorService.parseLastSeen("invalid-date-string"), isNull);
      expect(PowerMonitorService.parseLastSeen([]), isNull);
      expect(PowerMonitorService.parseLastSeen({"unrelated_key": 123}), isNull);
    });
  });

  group('PowerMonitorService evaluatePowerState Tests', () {
    final now = DateTime(2026, 10, 1, 12, 0, 0);

    test('returns disabled when disabled or notConfigured when url empty', () {
      final snap = PowerMonitorService.evaluatePowerState(
        isEnabled: false,
        customUrl: 'https://test.firebasedatabase.app',
        now: now,
      );
      expect(snap.status, RealPowerState.unknown);
      expect(snap.reason, PowerStateReason.disabled);

      final snapNoUrl = PowerMonitorService.evaluatePowerState(
        isEnabled: true,
        customUrl: '',
        now: now,
      );
      expect(snapNoUrl.status, RealPowerState.unknown);
      expect(snapNoUrl.reason, PowerStateReason.notConfigured);
    });

    test('returns networkError when consecutiveErrors >= 3', () {
      final snap = PowerMonitorService.evaluatePowerState(
        isEnabled: true,
        customUrl: 'https://test.firebasedatabase.app',
        consecutiveErrors: 3,
        lastSeen: now.subtract(const Duration(minutes: 5)),
        rawStatus: 'online',
        now: now,
      );
      expect(snap.status, RealPowerState.unknown);
      expect(snap.reason, PowerStateReason.networkError);
    });

    test(
        'returns online when lastSeen is within 25 min and rawStatus is online',
        () {
      final snap = PowerMonitorService.evaluatePowerState(
        isEnabled: true,
        customUrl: 'https://test.firebasedatabase.app',
        lastSeen: now.subtract(const Duration(minutes: 20)),
        rawStatus: 'online',
        now: now,
      );
      expect(snap.status, RealPowerState.online);
      expect(snap.reason, PowerStateReason.fresh);
    });

    test(
        'returns offline when lastSeen is within 25 min and rawStatus is offline',
        () {
      final snap = PowerMonitorService.evaluatePowerState(
        isEnabled: true,
        customUrl: 'https://test.firebasedatabase.app',
        lastSeen: now.subtract(const Duration(minutes: 10)),
        rawStatus: 'offline',
        now: now,
      );
      expect(snap.status, RealPowerState.offline);
      expect(snap.reason, PowerStateReason.fresh);
    });

    test(
        'remains offline when lastSeen exceeds heartbeat TTL because power outage is ongoing',
        () {
      final snap = PowerMonitorService.evaluatePowerState(
        isEnabled: true,
        customUrl: 'https://test.firebasedatabase.app',
        lastSeen: now.subtract(const Duration(minutes: 40)),
        lastEventTime: now.subtract(const Duration(minutes: 40)),
        rawStatus: 'offline',
        ttl: const Duration(minutes: 25),
        eventTtl: const Duration(hours: 24),
        now: now,
      );
      expect(snap.status, RealPowerState.offline);
      expect(snap.reason, PowerStateReason.fresh);
    });

    test('returns unknown (staleLastSeen) when online and lastSeen exceeds TTL',
        () {
      final snap = PowerMonitorService.evaluatePowerState(
        isEnabled: true,
        customUrl: 'https://test.firebasedatabase.app',
        lastSeen: now.subtract(const Duration(minutes: 26)),
        rawStatus: 'online',
        ttl: const Duration(minutes: 25),
        now: now,
      );
      expect(snap.status, RealPowerState.unknown);
      expect(snap.reason, PowerStateReason.staleLastSeen);
      expect(snap.isStale, isTrue);
    });

    test('respects custom configurable TTL (e.g. 15 minutes)', () {
      final snap = PowerMonitorService.evaluatePowerState(
        isEnabled: true,
        customUrl: 'https://test.firebasedatabase.app',
        lastSeen: now.subtract(const Duration(minutes: 16)),
        rawStatus: 'online',
        ttl: const Duration(minutes: 15),
        now: now,
      );
      expect(snap.status, RealPowerState.unknown);
      expect(snap.reason, PowerStateReason.staleLastSeen);
    });

    test('respects disabled TTL (Duration.zero) without going unknown', () {
      final snap = PowerMonitorService.evaluatePowerState(
        isEnabled: true,
        customUrl: 'https://test.firebasedatabase.app',
        lastSeen: now.subtract(const Duration(hours: 3)),
        rawStatus: 'online',
        ttl: Duration.zero,
        now: now,
      );
      expect(snap.status, RealPowerState.online);
      expect(snap.reason, PowerStateReason.fresh);
    });

    test(
        'falls back to lastEventTime when lastSeen is null and online event is fresh (< ttl)',
        () {
      final snap = PowerMonitorService.evaluatePowerState(
        isEnabled: true,
        customUrl: 'https://test.firebasedatabase.app',
        lastSeen: null,
        lastEventTime: now.subtract(const Duration(minutes: 10)),
        rawStatus: 'online',
        ttl: const Duration(minutes: 25),
        eventTtl: const Duration(hours: 24),
        now: now,
      );
      expect(snap.status, RealPowerState.online);
      expect(snap.reason, PowerStateReason.fresh);
    });

    test(
        'returns unknown (staleEvent) when lastSeen is null and online event exceeds ttl',
        () {
      final snap = PowerMonitorService.evaluatePowerState(
        isEnabled: true,
        customUrl: 'https://test.firebasedatabase.app',
        lastSeen: null,
        lastEventTime: now.subtract(const Duration(minutes: 30)),
        rawStatus: 'online',
        ttl: const Duration(minutes: 25),
        eventTtl: const Duration(hours: 24),
        now: now,
      );
      expect(snap.status, RealPowerState.unknown);
      expect(snap.reason, PowerStateReason.staleEvent);
      expect(snap.isStale, isTrue);
    });

    test('supports 5-minute TTL: online is fresh at 4m and stale at 6m', () {
      final snapFresh = PowerMonitorService.evaluatePowerState(
        isEnabled: true,
        customUrl: 'https://test.firebasedatabase.app',
        lastSeen: null,
        lastEventTime: now.subtract(const Duration(minutes: 4)),
        rawStatus: 'online',
        ttl: const Duration(minutes: 5),
        now: now,
      );
      expect(snapFresh.status, RealPowerState.online);
      expect(snapFresh.reason, PowerStateReason.fresh);

      final snapStale = PowerMonitorService.evaluatePowerState(
        isEnabled: true,
        customUrl: 'https://test.firebasedatabase.app',
        lastSeen: null,
        lastEventTime: now.subtract(const Duration(minutes: 6)),
        rawStatus: 'online',
        ttl: const Duration(minutes: 5),
        now: now,
      );
      expect(snapStale.status, RealPowerState.unknown);
      expect(snapStale.reason, PowerStateReason.staleEvent);
    });

    test(
        'offline event remains offline up to eventTtl (24 hours) even if it exceeds heartbeat ttl',
        () {
      final snap = PowerMonitorService.evaluatePowerState(
        isEnabled: true,
        customUrl: 'https://test.firebasedatabase.app',
        lastSeen: null,
        lastEventTime: now.subtract(const Duration(hours: 4)),
        rawStatus: 'offline',
        ttl: const Duration(minutes: 25),
        eventTtl: const Duration(hours: 24),
        now: now,
      );
      expect(snap.status, RealPowerState.offline);
      expect(snap.reason, PowerStateReason.fresh);
    });

    test(
        'returns notConfigured when customUrl is empty and local API is not available',
        () {
      final snap = PowerMonitorService.evaluatePowerState(
        isEnabled: true,
        customUrl: '',
        isLastEventManual: true,
        isLocalApiAvailable: false,
        rawStatus: 'online',
        lastEventTime: now.subtract(const Duration(minutes: 5)),
        now: now,
      );
      expect(snap.status, RealPowerState.unknown);
      expect(snap.reason, PowerStateReason.notConfigured);
    });

    test(
        'returns online when customUrl is empty but manual event exists and local API is available',
        () {
      final snap = PowerMonitorService.evaluatePowerState(
        isEnabled: true,
        customUrl: '',
        isLastEventManual: true,
        isLocalApiAvailable: true,
        rawStatus: 'online',
        lastEventTime: now.subtract(const Duration(minutes: 5)),
        ttl: const Duration(minutes: 25),
        now: now,
      );
      expect(snap.status, RealPowerState.online);
      expect(snap.reason, PowerStateReason.fresh);
    });

    test('returns unknown (noData) when both lastSeen and lastEvent are null',
        () {
      final snap = PowerMonitorService.evaluatePowerState(
        isEnabled: true,
        customUrl: 'https://test.firebasedatabase.app',
        lastSeen: null,
        lastEventTime: null,
        rawStatus: 'unknown',
        now: now,
      );
      expect(snap.status, RealPowerState.unknown);
      expect(snap.reason, PowerStateReason.noData);
    });
  });

  group('PowerMonitorSnapshot Model Tests', () {
    final now = DateTime(2026, 10, 1, 12, 0, 0);

    test('implements operator== and hashCode correctly', () {
      final snap1 = PowerMonitorSnapshot(
        status: RealPowerState.online,
        reason: PowerStateReason.fresh,
        lastSeen: now,
      );
      final snap2 = PowerMonitorSnapshot(
        status: RealPowerState.online,
        reason: PowerStateReason.fresh,
        lastSeen: now,
      );
      final snap3 = PowerMonitorSnapshot(
        status: RealPowerState.offline,
        reason: PowerStateReason.fresh,
        lastSeen: now,
      );

      expect(snap1, equals(snap2));
      expect(snap1.hashCode, equals(snap2.hashCode));
      expect(snap1, isNot(equals(snap3)));
    });

    test('copyWith updates properties properly', () {
      final snap = PowerMonitorSnapshot(
        status: RealPowerState.online,
        reason: PowerStateReason.fresh,
        lastSeen: now,
      );
      final updated = snap.copyWith(status: RealPowerState.unknown);

      expect(updated.status, RealPowerState.unknown);
      expect(updated.reason, PowerStateReason.fresh);
      expect(updated.lastSeen, now);
    });

    test('userMessage provides clear Ukrainian descriptions for all reasons',
        () {
      for (final reason in PowerStateReason.values) {
        expect(reason.userMessage, isNotEmpty);
      }
    });
  });

  group('PowerMonitorService TTL & Local API Availability Tests', () {
    test('allowedTtlMinutes contains expected values including 5 minutes', () {
      expect(PowerMonitorService.allowedTtlMinutes,
          containsAll([0, 5, 15, 25, 45, 60, 720, 1440]));
    });

    test('setLocalApiAvailable updates availability and recalculates snapshot',
        () {
      final service = PowerMonitorService();
      service.setLocalApiAvailable(true);
      expect(service.isLocalApiAvailable, isTrue);

      service.setLocalApiAvailable(false);
      expect(service.isLocalApiAvailable, isFalse);
    });

    test('setTtlMinutes falls back to default 25 min if invalid minute passed',
        () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final service = PowerMonitorService();
      await service.setTtlMinutes(999);
      expect(service.heartbeatTtl, const Duration(minutes: 25));

      await service.setTtlMinutes(5);
      expect(service.heartbeatTtl, const Duration(minutes: 5));
    });
  });
}
