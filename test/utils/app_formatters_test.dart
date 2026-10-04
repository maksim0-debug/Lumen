import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/utils/app_formatters.dart';

void main() {
  group('AppFormatters Tests', () {
    test('formatTime formats minutes from start of day to HH:mm', () {
      expect(AppFormatters.formatTime(0), equals('00:00'));
      expect(AppFormatters.formatTime(30), equals('00:30'));
      expect(AppFormatters.formatTime(90), equals('01:30'));
      expect(AppFormatters.formatTime(720), equals('12:00'));
      expect(AppFormatters.formatTime(1439), equals('23:59'));

      // Direct top-level functional alias
      expect(formatTime(150), equals('02:30'));
    });

    test('formatDuration formats total minutes into Ukrainian duration string',
        () {
      expect(AppFormatters.formatDuration(0), equals('0хв'));
      expect(AppFormatters.formatDuration(35), equals('35хв'));
      expect(AppFormatters.formatDuration(60), equals('1г'));
      expect(AppFormatters.formatDuration(120), equals('2г'));
      expect(AppFormatters.formatDuration(125), equals('2г 5хв'));

      // Direct top-level functional alias
      expect(formatDuration(90), equals('1г 30хв'));
    });

    test('fmtTime formats DateTime to HH:mm', () {
      expect(
          AppFormatters.fmtTime(DateTime(2026, 10, 1, 8, 5)), equals('08:05'));
      expect(AppFormatters.fmtTime(DateTime(2026, 10, 1, 23, 45)),
          equals('23:45'));

      // Direct top-level functional alias
      expect(fmtTime(DateTime(2026, 10, 1, 0, 0)), equals('00:00'));
    });

    test('fmtHM and formatHourMinute format hour and minute to HH:mm', () {
      expect(AppFormatters.fmtHM(3, 7), equals('03:07'));
      expect(AppFormatters.formatHourMinute(14, 55), equals('14:55'));

      // Direct top-level functional aliases
      expect(fmtHM(9, 0), equals('09:00'));
      expect(formatHourMinute(21, 30), equals('21:30'));
    });

    test('formatDateKey formats DateTime to YYYY-MM-DD', () {
      expect(AppFormatters.formatDateKey(DateTime(2026, 3, 5)),
          equals('2026-03-05'));
      expect(AppFormatters.formatDateKey(DateTime(2026, 10, 1)),
          equals('2026-10-01'));

      // Direct top-level functional alias
      expect(formatDateKey(DateTime(2026, 12, 31)), equals('2026-12-31'));
    });

    test('formatDate formats DateTime to DD.MM.YYYY', () {
      expect(
          AppFormatters.formatDate(DateTime(2026, 2, 9)), equals('09.02.2026'));
      expect(AppFormatters.formatDate(DateTime(2026, 10, 19)),
          equals('19.10.2026'));

      // Direct top-level functional alias
      expect(formatDate(DateTime(2026, 12, 31)), equals('31.12.2026'));
    });

    test('formatGroupName correctly formats group identifiers', () {
      expect(AppFormatters.formatGroupName('GPV2.1'), equals('Група 2.1'));
      expect(AppFormatters.formatGroupName('GPV1.2'), equals('Група 1.2'));
      expect(AppFormatters.formatGroupName('2.1'), equals('Група 2.1'));
      expect(AppFormatters.formatGroupName('Група 3.1'), equals('Група 3.1'));
      expect(AppFormatters.formatGroupName(''), equals(''));
      expect(AppFormatters.formatGroupName('   '), equals(''));

      // Direct top-level functional alias
      expect(formatGroupName('GPV4.2'), equals('Група 4.2'));
    });

    test('pluralVersions produces grammatically correct Ukrainian plurals', () {
      // 1 версія
      expect(AppFormatters.pluralVersions(1), equals('версія'));
      expect(AppFormatters.pluralVersions(21), equals('версія'));
      expect(AppFormatters.pluralVersions(101), equals('версія'));

      // 2, 3, 4 версії
      expect(AppFormatters.pluralVersions(2), equals('версії'));
      expect(AppFormatters.pluralVersions(3), equals('версії'));
      expect(AppFormatters.pluralVersions(4), equals('версії'));
      expect(AppFormatters.pluralVersions(22), equals('версії'));
      expect(AppFormatters.pluralVersions(34), equals('версії'));

      // 5..20, 11..14 версій
      expect(AppFormatters.pluralVersions(0), equals('версій'));
      expect(AppFormatters.pluralVersions(5), equals('версій'));
      expect(AppFormatters.pluralVersions(11), equals('версій'));
      expect(AppFormatters.pluralVersions(12), equals('версій'));
      expect(AppFormatters.pluralVersions(13), equals('версій'));
      expect(AppFormatters.pluralVersions(14), equals('версій'));
      expect(AppFormatters.pluralVersions(20), equals('версій'));
      expect(AppFormatters.pluralVersions(112), equals('версій'));

      // Direct top-level functional alias
      expect(pluralVersions(2), equals('версії'));
    });
  });
}
