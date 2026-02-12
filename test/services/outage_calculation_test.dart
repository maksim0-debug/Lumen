import 'package:flutter_test/flutter_test.dart';
import 'package:vikl/models/power_event.dart';

// Robust Logic from PowerMonitorService.dart
List<PowerOutageInterval> calculateIntervals(
    List<PowerEvent> allEvents, DateTime date) {
  if (allEvents.isEmpty) return [];

  final dayStart = DateTime(date.year, date.month, date.day);
  final dayEnd = dayStart.add(const Duration(days: 1));

  final List<PowerOutageInterval> intervals = [];
  DateTime? offlineStart;
  int? offlineStartId;

  // 1. Determine state at the very beginning of the day (00:00)
  PowerEvent? lastEventBeforeDay;
  for (final event in allEvents) {
    if (event.timestamp.isBefore(dayStart)) {
      lastEventBeforeDay = event;
    } else {
      break;
    }
  }

  if (lastEventBeforeDay != null && lastEventBeforeDay.isOffline) {
    offlineStart = dayStart;
    offlineStartId = lastEventBeforeDay.id;
  }

  // 2. Process events strictly falling within the day
  for (final event in allEvents) {
    if (event.timestamp.isBefore(dayStart)) continue;
    if (event.timestamp.isAfter(dayEnd)) break;

    if (event.isOffline) {
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

  // 3. If still offline at the end
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
  group('PowerMonitorService Robust Logic Test', () {
    test('Scenario: Outage starting at 3:14 should prevent 00:00 clamp', () {
      final day = DateTime(2026, 2, 11);

      final events = [
        PowerEvent(
            firebaseKey: '1',
            status: 'online',
            timestamp: DateTime(2026, 2, 10, 23, 02)),
        PowerEvent(
            firebaseKey: '2',
            status: 'offline',
            timestamp: DateTime(2026, 2, 11, 3, 14)),
        PowerEvent(
            firebaseKey: '3',
            status: 'online',
            timestamp: DateTime(2026, 2, 11, 10, 00)),
      ];

      final intervals = calculateIntervals(events, day);

      expect(intervals.length, 1);
      expect(intervals.first.start, DateTime(2026, 2, 11, 3, 14));
      expect(intervals.first.end, DateTime(2026, 2, 11, 10, 00));
    });

    test('Scenario: Outage continuous from previous day', () {
      final day = DateTime(2026, 2, 11);

      final events = [
        PowerEvent(
            firebaseKey: '1',
            status: 'offline',
            timestamp: DateTime(2026, 2, 10, 23, 00)),
        PowerEvent(
            firebaseKey: '2',
            status: 'online',
            timestamp: DateTime(2026, 2, 11, 01, 00)),
      ];

      final intervals = calculateIntervals(events, day);

      expect(intervals.length, 1);
      expect(intervals.first.start,
          DateTime(2026, 2, 11, 00, 00)); // Clamped to start of day
      expect(intervals.first.end, DateTime(2026, 2, 11, 01, 00));
    });
  });
}
