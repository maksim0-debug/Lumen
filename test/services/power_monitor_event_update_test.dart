import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/power_event.dart';
import 'package:lumen/services/power_monitor_service.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class MockPathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async => '.';
  @override
  Future<String?> getApplicationSupportPath() async => '.';
}

void main() {
  group('PowerMonitorService Manual Event & Fractional Timestamp Tests', () {
    late PowerMonitorService service;

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      PathProviderPlatform.instance = MockPathProviderPlatform();
      service = PowerMonitorService();
      service.setLocalApiAvailable(true);
    });

    test('insertManualEvent updates current snapshot and notifies listeners',
        () async {
      bool listenerCalled = false;
      String? updatedStatus;

      void testListener(String status) {
        listenerCalled = true;
        updatedStatus = status;
      }

      service.addStatusListener(testListener);

      final eventTime = DateTime.now().subtract(const Duration(minutes: 1));
      final event = PowerEvent(
        firebaseKey: 'test_manual_1',
        status: 'online',
        timestamp: eventTime,
        device: 'TestDevice',
        isManual: true,
      );

      final eventId = await service.insertManualEvent(event);
      expect(eventId, greaterThan(0));

      // Verify listener was notified
      expect(listenerCalled, isTrue);
      expect(updatedStatus, isNotNull);

      // Verify snapshot is updated
      final snapshot = service.snapshot;
      expect(snapshot.lastEventTime, isNotNull);

      service.removeStatusListener(testListener);
    });

    test(
        'getEventsRange includes events with fractional microsecond timestamps',
        () async {
      final baseTime = DateTime(2026, 10, 2, 14, 30, 0);
      final fractionalTime = baseTime.add(const Duration(microseconds: 123456));

      await service.insertManualEvent(PowerEvent(
        firebaseKey: 'test_manual_2',
        status: 'offline',
        timestamp: fractionalTime,
        device: 'FractionalSensor',
        isManual: true,
      ));

      // Query with endDate = baseTime (without microseconds, e.g. 14:30:00)
      final events = await service.getEventsRange(
        startDate: baseTime,
        endDate: baseTime,
      );

      expect(events.any((e) => e.device == 'FractionalSensor'), isTrue,
          reason:
              'Event with fractional microseconds within the target second must be included');
    });
  });
}
