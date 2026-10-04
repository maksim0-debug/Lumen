import 'package:flutter_test/flutter_test.dart';

/// Helper class simulating fetch throttling & state isolation logic
class ScheduleFetchCoordinator {
  bool isFetching = false;
  DateTime? lastFetchTime;
  final Duration cooldown;
  int networkFetchCount = 0;

  ScheduleFetchCoordinator({this.cooldown = const Duration(seconds: 30)});

  bool shouldFetch({bool force = false, bool hasExistingData = true}) {
    if (isFetching) {
      return false; // Concurrency lock: already fetching
    }
    if (!force &&
        hasExistingData &&
        lastFetchTime != null &&
        DateTime.now().difference(lastFetchTime!) < cooldown) {
      return false; // Throttled by cooldown
    }
    return true;
  }

  Future<bool> executeFetch({
    bool force = false,
    bool hasExistingData = true,
    required Future<void> Function() performNetworkCall,
  }) async {
    if (!shouldFetch(force: force, hasExistingData: hasExistingData)) {
      return false;
    }

    isFetching = true;
    try {
      networkFetchCount++;
      await performNetworkCall();
      lastFetchTime = DateTime.now();
      return true;
    } finally {
      isFetching = false;
    }
  }
}

void main() {
  group('ScheduleFetchCoordinator Tests', () {
    test('Initial fetch is allowed when no prior fetch was made', () {
      final coordinator = ScheduleFetchCoordinator();
      expect(coordinator.shouldFetch(force: false, hasExistingData: false),
          isTrue);
    });

    test('Immediate consecutive fetch within cooldown is skipped', () async {
      final coordinator = ScheduleFetchCoordinator();
      await coordinator.executeFetch(
        force: false,
        performNetworkCall: () async {},
      );

      expect(coordinator.networkFetchCount, equals(1));
      expect(coordinator.shouldFetch(force: false, hasExistingData: true),
          isFalse);

      final secondCall = await coordinator.executeFetch(
        force: false,
        performNetworkCall: () async {},
      );
      expect(secondCall, isFalse);
      expect(coordinator.networkFetchCount, equals(1));
    });

    test('Forced fetch bypasses cooldown', () async {
      final coordinator = ScheduleFetchCoordinator();
      await coordinator.executeFetch(
        force: false,
        performNetworkCall: () async {},
      );
      expect(coordinator.networkFetchCount, equals(1));

      // Force fetch should be allowed even immediately
      final forcedCall = await coordinator.executeFetch(
        force: true,
        performNetworkCall: () async {},
      );
      expect(forcedCall, isTrue);
      expect(coordinator.networkFetchCount, equals(2));
    });

    test('Fetch is allowed when existing data is empty even within cooldown',
        () {
      final coordinator = ScheduleFetchCoordinator();
      coordinator.lastFetchTime = DateTime.now();
      expect(coordinator.shouldFetch(force: false, hasExistingData: false),
          isTrue);
    });

    test('In-flight lock prevents duplicate concurrent executions', () async {
      final coordinator = ScheduleFetchCoordinator();
      coordinator.isFetching = true;

      expect(coordinator.shouldFetch(force: true, hasExistingData: false),
          isFalse);
      expect(coordinator.shouldFetch(force: false, hasExistingData: true),
          isFalse);
    });

    test('Fetch is allowed after cooldown duration elapses', () {
      final coordinator =
          ScheduleFetchCoordinator(cooldown: const Duration(seconds: 30));
      coordinator.lastFetchTime =
          DateTime.now().subtract(const Duration(seconds: 31));

      expect(
          coordinator.shouldFetch(force: false, hasExistingData: true), isTrue);
    });
  });
}

