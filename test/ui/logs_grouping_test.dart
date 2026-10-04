import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/ui/logs_page.dart';

void main() {
  group('Logs Grouping & Filtering Logic Tests', () {
    final rawLogs = [
      {
        'timestamp': '2026-10-01T06:22:27',
        'level': 'ERROR',
        'message': 'HTTP 401'
      },
      {
        'timestamp': '2026-10-01T06:21:57',
        'level': 'ERROR',
        'message': 'HTTP 401'
      },
      {
        'timestamp': '2026-10-01T06:21:27',
        'level': 'ERROR',
        'message': 'HTTP 401'
      },
      {
        'timestamp': '2026-10-01T06:14:27',
        'level': 'INFO',
        'message': 'Парсер: Старт прямого HTTP запиту'
      },
      {
        'timestamp': '2026-10-01T06:14:28',
        'level': 'INFO',
        'message': 'Парсер HTTP: Успішно розібрано 12 груп'
      },
    ];

    test('groupConsecutiveLogs collapses consecutive identical messages', () {
      final grouped = groupConsecutiveLogs(rawLogs);
      expect(grouped.length, 3);
      expect(grouped[0].message, 'HTTP 401');
      expect(grouped[0].count, 3);
      expect(grouped[1].message, 'Парсер: Старт прямого HTTP запиту');
      expect(grouped[1].count, 1);
      expect(grouped[2].message, 'Парсер HTTP: Успішно розібрано 12 груп');
      expect(grouped[2].count, 1);
    });

    test('filterGroupedLogs correctly filters by category', () {
      final grouped = groupConsecutiveLogs(rawLogs);

      final errorsOnly = filterGroupedLogs(grouped, LogFilterCategory.errors);
      expect(errorsOnly.length, 1);
      expect(errorsOnly.first.level, 'ERROR');

      final parserOnly = filterGroupedLogs(grouped, LogFilterCategory.parser);
      expect(parserOnly.length, 2);
      expect(parserOnly.every((l) => l.message.contains('Парсер')), isTrue);

      final monitorOnly =
          filterGroupedLogs(grouped, LogFilterCategory.powerMonitor);
      expect(
          monitorOnly.length, 0); // None of these rawLogs contain PowerMonitor
    });
  });
}

