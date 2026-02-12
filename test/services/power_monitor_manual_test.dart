import 'package:flutter_test/flutter_test.dart';
import 'package:vikl/models/power_event.dart';

// Mock DB and Logic
class MockPowerMonitorService {
  final Map<String, PowerEvent> _db = {};

  Future<void> saveToLocalDb(List<PowerEvent> events) async {
    // 1. Identify manual keys
    final manualKeys = <String>{};
    _db.forEach((key, value) {
      if (value.isManual) {
        manualKeys.add(value.firebaseKey);
      }
    });

    // 2. Insert or Update loop
    for (final event in events) {
      if (manualKeys.contains(event.firebaseKey)) {
        continue; // Skip manual events
      }

      // Simulate replace
      _db[event.firebaseKey] = event;
    }
  }

  // Simulate editing an event manually
  void userEditsEvent(String key, DateTime newTime) {
    if (_db.containsKey(key)) {
      final old = _db[key]!;
      _db[key] = PowerEvent(
        firebaseKey: old.firebaseKey,
        status: old.status,
        timestamp: newTime,
        isManual: true, // This is the key change
      );
    }
  }

  PowerEvent? getEvent(String key) => _db[key];
}

void main() {
  group('PowerMonitorService Manual Override Tests', () {
    test('Should NOT overwrite manually edited event during sync', () async {
      final service = MockPowerMonitorService();
      final key = 'event_1';
      final cloudTime = DateTime(2025, 2, 11, 10, 0);
      final userTime = DateTime(2025, 2, 11, 10, 30);

      // 1. Initial Sync
      await service.saveToLocalDb([
        PowerEvent(firebaseKey: key, status: 'offline', timestamp: cloudTime)
      ]);

      expect(service.getEvent(key)!.timestamp, cloudTime);
      expect(service.getEvent(key)!.isManual, false);

      // 2. User Edits
      service.userEditsEvent(key, userTime);

      expect(service.getEvent(key)!.timestamp, userTime);
      expect(service.getEvent(key)!.isManual, true);

      // 3. Sync Again (Cloud still sends old time)
      await service.saveToLocalDb([
        PowerEvent(firebaseKey: key, status: 'offline', timestamp: cloudTime)
      ]);

      // 4. Verification: Should still be User Time
      expect(service.getEvent(key)!.timestamp, userTime);
      expect(service.getEvent(key)!.isManual, true);
    });

    test('Should update non-manual events normally', () async {
      final service = MockPowerMonitorService();
      final key = 'event_2';
      final time1 = DateTime(2025, 2, 11, 10, 0);
      final time2 = DateTime(2025, 2, 11, 11, 0);

      await service.saveToLocalDb(
          [PowerEvent(firebaseKey: key, status: 'offline', timestamp: time1)]);

      await service.saveToLocalDb(
          [PowerEvent(firebaseKey: key, status: 'offline', timestamp: time2)]);

      expect(service.getEvent(key)!.timestamp, time2);
    });
  });
}
