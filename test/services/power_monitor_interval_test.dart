import 'package:flutter_test/flutter_test.dart';
import 'package:vikl/models/power_event.dart';

// Mock function representing the logic in getOutageIntervalsForDate
List<PowerOutageInterval> calculateIntervals(
    List<PowerEvent> events, DateTime dayStart) {
  final dayEnd = dayStart.add(const Duration(days: 1));
  final List<PowerOutageInterval> intervals = [];
  DateTime? offlineStart;
  int? offlineStartId;

  // Pre-day check logic (simplified for test)
  for (final event in events) {
    if (event.timestamp.isBefore(dayStart)) {
      if (event.isOffline) {
        offlineStart = event.timestamp;
        offlineStartId = event.id;
      } else {
        offlineStart = null;
        offlineStartId = null;
      }
    }
  }

  if (offlineStart != null) {
    offlineStart = dayStart;
  }

  for (final event in events) {
    if (event.timestamp.isBefore(dayStart)) continue;
    if (event.timestamp.isAfter(dayEnd)) break;

    if (event.isOffline) {
      // FIX: Only set start if not already started
      if (offlineStart == null) {
        offlineStart = event.timestamp;
        offlineStartId = event.id;
      }
    } else if (event.isOnline && offlineStart != null) {
      intervals.add(PowerOutageInterval(
        start: offlineStart!,
        end: event.timestamp,
        startEventId: offlineStartId,
        endEventId: event.id,
      ));
      offlineStart = null;
      offlineStartId = null;
    }
  }

  if (offlineStart != null) {
    intervals.add(PowerOutageInterval(
      start: offlineStart!,
      end: null,
      startEventId: offlineStartId,
      endEventId: null,
    ));
  }

  return intervals;
}

void main() {
  group('PowerMonitorService Interval Calculation Logic', () {
    test('Should handle consecutive offline events correctly', () {
      final day = DateTime(2025, 2, 11);
      final events = [
        PowerEvent(
            firebaseKey: '1',
            status: 'offline',
            timestamp: DateTime(2025, 2, 11, 3, 14)),
        PowerEvent(
            firebaseKey: '2',
            status: 'offline',
            timestamp: DateTime(2025, 2, 11, 12, 19)), // Redundant
        PowerEvent(
            firebaseKey: '3',
            status: 'online',
            timestamp: DateTime(2025, 2, 11, 12, 32)),
      ];

      final intervals = calculateIntervals(events, day);

      expect(intervals.length, 1);
      // Expected: Start at 3:14
      expect(intervals.first.start, DateTime(2025, 2, 11, 3, 14));
      // Expected: End at 12:32
      expect(intervals.first.end, DateTime(2025, 2, 11, 12, 32));
    });

    test('Should handle outage crossing midnight correctly', () {
      final day = DateTime(2025, 2, 11);
      // Outage started previous day
      final prevDayEvent = PowerEvent(
          firebaseKey: '0',
          status: 'offline',
          timestamp: DateTime(2025, 2, 10, 23, 0));

      final events = [
        prevDayEvent,
        PowerEvent(
            firebaseKey: '1',
            status: 'offline',
            timestamp: DateTime(2025, 2, 11, 8, 0)), // Redundant
        PowerEvent(
            firebaseKey: '2',
            status: 'online',
            timestamp: DateTime(2025, 2, 11, 10, 0)),
      ];

      final intervals = calculateIntervals(events, day);

      expect(intervals.length, 1);
      // Ideally starts at 00:00 for display purposes on "day"
      expect(intervals.first.start, day);
      expect(intervals.first.end, DateTime(2025, 2, 11, 10, 0));
    });
  });
}
