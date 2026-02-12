import 'package:flutter_test/flutter_test.dart';
import 'package:vikl/models/power_event.dart';

// Mock function to simulate the logic we want to implement in PowerMonitorService
List<PowerEvent> processEvents(List<PowerEvent> fetchedEvents) {
  const int routerStartupDelayMinutes = 6;
  return fetchedEvents.map((e) {
    if (e.status == 'online') {
      return PowerEvent(
        id: e.id,
        firebaseKey: e.firebaseKey,
        status: e.status,
        timestamp: e.timestamp
            .subtract(const Duration(minutes: routerStartupDelayMinutes)),
        device: e.device,
      );
    }
    return e;
  }).toList();
}

void main() {
  group('PowerMonitorService Logic Tests', () {
    test('Should subtract 6 minutes from online events', () {
      final initialTime = DateTime(2025, 2, 11, 12, 6); // 12:06
      final event = PowerEvent(
        firebaseKey: 'test_key_1',
        status: 'online',
        timestamp: initialTime,
      );

      final processed = processEvents([event]);

      expect(processed.first.timestamp,
          DateTime(2025, 2, 11, 12, 0)); // Should be 12:00
      expect(processed.first.status, 'online');
    });

    test('Should NOT subtract from offline events', () {
      final initialTime = DateTime(2025, 2, 11, 10, 0); // 10:00
      final event = PowerEvent(
        firebaseKey: 'test_key_2',
        status: 'offline',
        timestamp: initialTime,
      );

      final processed = processEvents([event]);

      expect(processed.first.timestamp, initialTime); // Should remain 10:00
      expect(processed.first.status, 'offline');
    });

    test('Should handle mixed events correctly', () {
      final t1 = DateTime(2025, 2, 11, 10, 0);
      final t2 = DateTime(2025, 2, 11, 12, 6);

      final events = [
        PowerEvent(firebaseKey: 'k1', status: 'offline', timestamp: t1),
        PowerEvent(firebaseKey: 'k2', status: 'online', timestamp: t2),
      ];

      final processed = processEvents(events);

      expect(processed[0].timestamp, t1);
      expect(processed[1].timestamp, DateTime(2025, 2, 11, 12, 0));
    });
  });
}
