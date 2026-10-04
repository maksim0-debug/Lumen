import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Analytics Logic', () {
    test('getWorstDays should calculate SUM of outage hours per weekday', () {
      // Mock data: 2 Mondays.
      // Monday 1: 4 hours outage.
      // Monday 2: 2 hours outage.
      // Expected Result for Monday: 6.0 hours (Sum).

      final dailyData = [
        DailyOutage(date: DateTime(2024, 2, 12), outageMinutes: 240), // Mon, 4h
        DailyOutage(date: DateTime(2024, 2, 19), outageMinutes: 120), // Mon, 2h
        DailyOutage(date: DateTime(2024, 2, 13), outageMinutes: 60), // Tue, 1h
      ];

      final result = calculateWorstDays(dailyData);

      expect(result[1], equals(6.0)); // Monday (1) should be 6.0
      expect(result[2], equals(1.0)); // Tuesday (2) should be 1.0
      expect(result.containsKey(3), isFalse); // Wednesday (3) no data
    });
  });
}

// The logic to be implemented in AnalyticsService
Map<int, double> calculateWorstDays(List<DailyOutage> dailyData) {
  Map<int, List<double>> byWeekday = {};
  for (final d in dailyData) {
    final wd = d.date.weekday;
    byWeekday.putIfAbsent(wd, () => []);
    byWeekday[wd]!.add(d.outageMinutes / 60.0);
  }

  Map<int, double> result = {};
  for (final entry in byWeekday.entries) {
    // OLD LOGIC: Average
    // final avg = entry.value.reduce((a, b) => a + b) / entry.value.length;
    // result[entry.key] = avg;

    // NEW LOGIC: Sum
    final sum = entry.value.reduce((a, b) => a + b);
    result[entry.key] = sum;
  }

  return result;
}

class DailyOutage {
  final DateTime date;
  final int outageMinutes;

  DailyOutage({required this.date, required this.outageMinutes});
}

