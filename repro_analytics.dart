import 'dart:math';

// Mock classes
class PowerEvent {
  final DateTime timestamp;
  final String status;

  PowerEvent(this.timestamp, this.status);

  bool get isOffline => status == 'offline';
  bool get isOnline => status == 'online';
  int get id => timestamp.millisecondsSinceEpoch;
}

class PowerOutageInterval {
  final DateTime start;
  final DateTime? end;

  PowerOutageInterval({required this.start, this.end});
}

class DailyOutage {
  final DateTime date;
  final int outageMinutes;

  DailyOutage({required this.date, required this.outageMinutes});
}

List<PowerOutageInterval> getOutageIntervalsForDate(
    DateTime date, List<PowerEvent> allEvents) {
  final dayStart = DateTime(date.year, date.month, date.day);
  final dayEnd = dayStart.add(const Duration(days: 1));
  const int routerDelayMinutes = 6;

  List<PowerOutageInterval> intervals = [];

  // Simple state machine simulation
  DateTime cursor = dayStart;
  bool isCurrentlyOffline = false;

  // Determine initial state
  // For this repro, let's assume valid state starts at dayStart based on previous events
  // But since we provide specific events for the day, we can ignore "before" events if they don't overlap relevantly
  // except for initial status.

  // Check initial status
  try {
    final lastBefore =
        allEvents.lastWhere((e) => e.timestamp.isBefore(dayStart));
    if (lastBefore.isOffline) {
      isCurrentlyOffline = true;
    } else {
      // Online logic correction
      if (lastBefore.timestamp.add(Duration(minutes: 6)).isAfter(dayStart)) {
        // Effectively offline until online+6
        // But let's keep it simple: assume online if online event was long ago
      }
    }
  } catch (e) {}

  for (final event in allEvents) {
    // Calculate effective time (Online + 6m)
    DateTime effectiveTime = event.timestamp;
    if (event.isOnline) {
      effectiveTime =
          event.timestamp.subtract(const Duration(minutes: routerDelayMinutes));
    }

    // Skip if completely outside
    if (effectiveTime.isBefore(dayStart)) continue;
    if (effectiveTime.isAfter(dayEnd)) {
      // Should process partial?
      // effectiveTime > dayEnd.
      // If offline -> still offline until dayEnd?
      continue;
      // Real code breaks here, but does it add interval?
    }

    if (event.isOffline) {
      if (!isCurrentlyOffline) {
        isCurrentlyOffline = true;
        cursor = effectiveTime;
      }
    } else {
      // Online
      if (isCurrentlyOffline) {
        isCurrentlyOffline = false;
        intervals.add(PowerOutageInterval(
          start: cursor.isBefore(dayStart) ? dayStart : cursor,
          end: effectiveTime,
        ));
      }
    }
  }

  // Close open interval at end of day
  if (isCurrentlyOffline) {
    intervals.add(PowerOutageInterval(
      start: cursor.isBefore(dayStart) ? dayStart : cursor,
      end:
          dayEnd, // In real code it uses null, then handles externally. Here we just close it.
    ));
  }

  return intervals;
}

List<DailyOutage> getDailyOutageHours(int days, List<PowerEvent> allEvents) {
  final now = DateTime(2024, 2, 12, 12, 0); // Monday
  List<DailyOutage> result = [];

  // Check last 'days' days.
  // d=3 (Fri), d=2 (Sat), d=1 (Sun), d=0 (Mon)
  for (int d = days - 1; d >= 0; d--) {
    final date =
        DateTime(now.year, now.month, now.day).subtract(Duration(days: d));
    final intervals = getOutageIntervalsForDate(date, allEvents);

    int totalSeconds = 0;
    final dayStart = DateTime(date.year, date.month, date.day);
    final dayEnd = dayStart.add(const Duration(days: 1));

    for (final interval in intervals) {
      final start =
          interval.start.isBefore(dayStart) ? dayStart : interval.start;
      final end = (interval.end ?? dayEnd).isAfter(dayEnd)
          ? dayEnd
          : (interval.end ?? dayEnd);

      if (end.isAfter(start)) {
        totalSeconds += end.difference(start).inSeconds;
      }
    }

    result.add(DailyOutage(
      date: date,
      outageMinutes: (totalSeconds / 60).round(),
    ));
  }

  return result;
}

void main() {
  // Friday Feb 9th
  final events = [
    PowerEvent(DateTime(2024, 2, 9, 8, 0), 'offline'),
    PowerEvent(DateTime(2024, 2, 9, 10, 0), 'online'),
    // 8:00->10:06 (due to delay) = 2h 6m = 126 min

    PowerEvent(DateTime(2024, 2, 9, 14, 0), 'offline'),
    PowerEvent(DateTime(2024, 2, 9, 16, 0), 'online'),
    // 14:00->16:06 = 2h 6m = 126 min

    // Total = 252 min = 4h 12m
  ];

  final dailyData = getDailyOutageHours(4, events);

  for (final d in dailyData) {
    print(
        'Date: ${d.date.toString().substring(0, 10)} (${d.date.weekday}) - Outage: ${d.outageMinutes} min');
  }
}
