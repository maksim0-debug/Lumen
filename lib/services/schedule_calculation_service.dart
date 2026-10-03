import 'package:flutter/material.dart';
import '../models/data_source_mode.dart';
import '../models/interval_info.dart';
import '../models/power_event.dart';
import '../models/schedule_status.dart';
import '../utils/app_formatters.dart';
import 'hour_segment_service.dart';

/// Сервіс для обчислення розкладів, інтервалів та статистики відключень.
class ScheduleCalculationService {
  /// Підрахунок сумарних хвилин відключень для графіка.
  static int calculateOutageMinutes(DailySchedule schedule) {
    return schedule.totalOutageMinutes;
  }

  /// Точний підрахунок хвилин без світла з реальних інтервалів.
  static int computeRealOutageMinutes(
      List<PowerOutageInterval> intervals, DateTime date) {
    return HourSegmentService.computeRealOutageMinutes(intervals, date);
  }

  /// Формування тексту інформації про час без світла (для прогнозу або реального режиму).
  static String getOutageInfoText(
    DailySchedule? schedule,
    bool isTomorrow, {
    bool powerMonitorEnabled = false,
    DataSourceMode dataSourceMode = DataSourceMode.predicted,
    List<PowerOutageInterval> realOutageIntervals = const [],
    DateTime? displayDate,
    bool wasUpdated = false,
    String? currentGroup,
    Map<String, int> lastUpdateOldStats = const {},
  }) {
    // Real mode: precise minutes from intervals
    if (powerMonitorEnabled && dataSourceMode == DataSourceMode.real) {
      final realMinutes = computeRealOutageMinutes(
          realOutageIntervals, displayDate ?? DateTime.now());
      if (realMinutes == 0 && realOutageIntervals.isEmpty) return "";
      final percent = (realMinutes / 1440 * 100).round();
      final h = realMinutes ~/ 60;
      final m = realMinutes % 60;
      String timeStr;
      if (h > 0 && m > 0) {
        timeStr = '$hг $mхв';
      } else if (h > 0) {
        timeStr = '$hг';
      } else {
        timeStr = '$mхв';
      }
      return "Час без світла: $timeStr ($percent%)";
    }

    if (schedule == null || schedule.isEmpty) return "";

    final currentMinutes = calculateOutageMinutes(schedule);
    final currentPercent = (currentMinutes / (24 * 60) * 100).round();

    final hours = currentMinutes ~/ 60;
    final minutes = currentMinutes % 60;
    final timeStr = "$hours:${minutes.toString().padLeft(2, '0')}";

    String baseText = "Час без світла: $timeStr ($currentPercent%)";

    if (wasUpdated && currentGroup != null) {
      final key = "${currentGroup}_${isTomorrow ? 'tomorrow' : 'today'}";
      if (lastUpdateOldStats.containsKey(key)) {
        final oldMinutes = lastUpdateOldStats[key]!;
        final diffMinutes = currentMinutes - oldMinutes;

        if (diffMinutes != 0) {
          final diffPercent = (diffMinutes / (24 * 60) * 100).round();
          final sign = diffPercent > 0 ? "+" : "";
          return "Графік оновився: $baseText ($sign$diffPercent%)";
        }
      }
    }

    return baseText;
  }

  /// Конвертувати DailySchedule у слоти (півгодинні).
  static List<SlotStatus> convertScheduleToSlots(DailySchedule schedule) {
    return schedule.toSlots();
  }

  /// Генерація списку інтервалів для планового графіка.
  static List<IntervalInfo> generateIntervals(DailySchedule? schedule) {
    if (schedule == null || schedule.isEmpty) return [];
    final slots = convertScheduleToSlots(schedule);
    List<IntervalInfo> intervals = [];
    int i = 0;
    while (i < slots.length) {
      final currentStatus = slots[i];
      int j = i + 1;
      while (j < slots.length && slots[j] == currentStatus) {
        j++;
      }
      final startTime = AppFormatters.formatTime(i * 30);
      final endTime = AppFormatters.formatTime(j * 30);
      final durationMins = (j - i) * 30;
      final durationStr = AppFormatters.formatDuration(durationMins);
      String statusStr = "";
      Color color = Colors.grey;
      switch (currentStatus) {
        case SlotStatus.on:
          statusStr = "ON";
          color = Colors.green;
          break;
        case SlotStatus.off:
          statusStr = "OFF";
          color = Colors.red;
          break;
        case SlotStatus.maybe:
          statusStr = "MAYBE";
          color = Colors.grey;
          break;
        case SlotStatus.unknown:
          statusStr = "?";
          color = Colors.grey.shade800;
          break;
      }
      intervals.add(
          IntervalInfo("$startTime - $endTime", statusStr, durationStr, color));
      i = j;
    }
    return intervals;
  }

  /// Побудувати DailySchedule з реальних інтервалів відключень (для grid).
  /// Використовується тільки для інтервального списку та нотифікацій (fallback).
  static DailySchedule buildRealScheduleFromIntervals(
      List<PowerOutageInterval> intervals, DateTime date,
      {DailySchedule? baseSchedule, DateTime? nowOverride}) {
    // Якщо є прогноз, беремо його за основу, інакше все зелене
    List<LightStatus> hours = baseSchedule != null
        ? List.from(baseSchedule.hours)
        : List.filled(24, LightStatus.on);

    final now = nowOverride ?? DateTime.now();
    final isToday =
        date.year == now.year && date.month == now.month && date.day == now.day;

    // Якщо це сьогодні - перезаписуємо минуле і поточну годину реальними даними.
    // Майбутнє залишаємо як у прогнозі (або зеленим якщо прогнозу немає).
    // Якщо день у минулому - перезаписуємо весь день (limitHour = 24).
    // Якщо день у майбутньому - все залишається прогнозом (loop не виконається або limitHour=0).

    int limitHour = 24;
    if (isToday) {
      // Перезаписуємо все ДО поточної години включно.
      // Поточна година теж формується тут, але в GridView вона перекривається _buildRealModeCell.
      // Для total outage minutes важливо порахувати і поточну годину з оффлайном.
      limitHour = now.hour + 1;
    } else if (date.isAfter(now)) {
      // Майбутній день - повністю прогноз
      limitHour = 0;
    }

    for (int h = 0; h < limitHour; h++) {
      // Скидаємо статус на On перед розрахунком реального,
      // бо ми хочемо порахувати суто по факту відключень.
      // (Хоча якщо там було semiOn/off в прогнозі, а світло було 100% часу - воно стане On.
      // А якщо світло було 0% часу - стане Off).
      // Але логіку нижче треба перевірити.
      // Логіка нижче базується на offMinutes.
      hours[h] = LightStatus.on;

      int offMinutes = 0;
      for (final interval in intervals) {
        offMinutes += interval.minutesOfflineInHour(date, h);
      }

      if (offMinutes >= 55) {
        hours[h] = LightStatus.off;
      } else if (offMinutes >= 30) {
        final hourStart = DateTime(date.year, date.month, date.day, h);
        final hourMid = hourStart.add(const Duration(minutes: 30));
        int firstHalfOff = 0;
        int secondHalfOff = 0;
        for (final interval in intervals) {
          final intervalEnd = interval.end ?? (nowOverride ?? DateTime.now());
          final s1 =
              interval.start.isAfter(hourStart) ? interval.start : hourStart;
          final e1 = intervalEnd.isBefore(hourMid) ? intervalEnd : hourMid;
          if (e1.isAfter(s1)) firstHalfOff += e1.difference(s1).inMinutes;
          final hourEnd = hourStart.add(const Duration(hours: 1));
          final s2 = interval.start.isAfter(hourMid) ? interval.start : hourMid;
          final e2 = intervalEnd.isBefore(hourEnd) ? intervalEnd : hourEnd;
          if (e2.isAfter(s2)) secondHalfOff += e2.difference(s2).inMinutes;
        }
        if (firstHalfOff > secondHalfOff) {
          hours[h] = LightStatus.semiOn;
        } else {
          hours[h] = LightStatus.semiOff;
        }
      } else if (offMinutes >= 5) {
        hours[h] = LightStatus.semiOff;
      }
    }
    return DailySchedule(hours);
  }

  /// Генерація реальних інтервалів (ON / OFF / OFF ⏳) за день.
  static List<IntervalInfo> generateRealIntervals(
      List<PowerOutageInterval> intervals, DateTime date,
      {bool isOffline = false, DateTime? nowOverride}) {
    final dayStart = DateTime(date.year, date.month, date.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final now = nowOverride ?? DateTime.now();

    List<IntervalInfo> result = [];
    DateTime cursor = dayStart;

    final isToday =
        date.year == now.year && date.month == now.month && date.day == now.day;

    // Если интервалов нет вообще
    if (intervals.isEmpty) {
      if (isToday && isOffline) {
        // Весь день нет света?
        return [IntervalInfo("00:00 - 24:00", "OFF ⏳", "24г", Colors.red)];
      }
      return [IntervalInfo("00:00 - 24:00", "ON", "24г", Colors.green)];
    }

    for (final interval in intervals) {
      // 1. Зеленый интервал (ДО начала отключения)
      // Если начало отключения (interval.start) позже, чем курсор -> значит был свет
      if (interval.start.isAfter(cursor)) {
        final onDiff = interval.start.difference(cursor).inMinutes;
        if (onDiff > 0) {
          result.add(IntervalInfo(
            "${AppFormatters.fmtTime(cursor)} - ${AppFormatters.fmtTime(interval.start)}",
            "ON",
            AppFormatters.formatDuration(onDiff),
            Colors.green,
          ));
        }
      }

      // 2. Красный интервал (Отключение)
      DateTime intervalEnd =
          interval.end ?? (now.isBefore(dayEnd) ? now : dayEnd);

      // Визуальный фикс: если интервал продолжается, но мы смотрим вчерашний день,
      // он должен заканчиваться в 24:00, а не "зараз"
      String endLabel;
      bool isOngoing = interval.isOngoing;

      if (interval.end == null) {
        // Это текущее отключение
        if (date.day != now.day) {
          // Если смотрим историю (вчера), то отключение шло до конца дня
          intervalEnd = dayEnd;
          endLabel = "24:00";
          isOngoing = false;
        } else {
          endLabel = "зараз";
        }
      } else {
        endLabel = AppFormatters.fmtTime(intervalEnd);
      }

      final offDiff = intervalEnd.difference(interval.start).inMinutes;
      result.add(IntervalInfo(
        "${AppFormatters.fmtTime(interval.start)} - $endLabel",
        isOngoing ? "OFF ⏳" : "OFF",
        AppFormatters.formatDuration(offDiff),
        Colors.red,
        startEventId: interval.startEventId,
        endEventId: interval.endEventId,
      ));

      cursor = intervalEnd;
    }

    // 3. Финальный зеленый хвост (после последнего отключения до конца дня)
    if (cursor.isBefore(dayEnd)) {
      // Если последнее событие было "Свет дали" и оно закончилось раньше 24:00
      // ИЛИ если интервалов не было.
      // Важно проверить, не продолжается ли отключение.
      final lastInterval = intervals.last;
      if (lastInterval.end != null) {
        // Отключение закончилось, значит дальше свет есть
        // Но нужно обрезать по "сейчас", если смотрим сегодня
        DateTime tailEnd = dayEnd;
        if (date.year == now.year &&
            date.month == now.month &&
            date.day == now.day) {
          // Если сегодня, то зеленый рисуем "до сейчас" или прогнозом до конца
          // Обычно ON рисуют до 24:00 как прогноз "будет свет"
          tailEnd = dayEnd;
        }

        final tailDiff = tailEnd.difference(cursor).inMinutes;
        if (tailDiff > 0) {
          result.add(IntervalInfo(
            "${AppFormatters.fmtTime(cursor)} - 24:00",
            "ON",
            AppFormatters.formatDuration(tailDiff),
            Colors.green,
          ));
        }
      }
    }

    return result;
  }

  /// Форматування коду черги/групи у читабельний рядок (наприклад, "GPV2.1" -> "Група 2.1").
  /// Фасад до [AppFormatters.formatGroupName] для зворотної сумісності.
  static String formatGroupName(String groupKey) =>
      AppFormatters.formatGroupName(groupKey);

  /// Форматування окремого інтервалу у рядок виду "00:00 - 03:30  OFF  (3г 30хв)".
  static String formatIntervalText(IntervalInfo interval) {
    return "${interval.timeRange}  ${interval.statusText}  (${interval.duration})";
  }

  /// Формування повного структурованого тексту для копіювання розкладу в буфер обміну.
  static String formatScheduleClipboardSummary({
    String? group,
    DateTime? date,
    DataSourceMode? dataSourceMode,
    String? scheduleVersion,
    required String outageInfoText,
    required List<IntervalInfo> intervals,
  }) {
    // Якщо немає ані інтервалів, ані тексту про відключення — корисних даних для зведення немає
    if (outageInfoText.trim().isEmpty && intervals.isEmpty) {
      return "";
    }

    final buffer = StringBuffer();

    final List<String> headerParts = [];
    if (group != null && group.trim().isNotEmpty) {
      headerParts.add(AppFormatters.formatGroupName(group));
    }
    if (date != null) {
      headerParts.add(AppFormatters.formatDate(date));
    }

    if (headerParts.isNotEmpty) {
      buffer.writeln(headerParts.join(" — "));
    }

    if (dataSourceMode != null) {
      if (dataSourceMode == DataSourceMode.real) {
        buffer.writeln("Реальні відключення");
      } else if (dataSourceMode == DataSourceMode.predicted) {
        final cleanVersion = scheduleVersion?.trim();
        if (cleanVersion != null &&
            cleanVersion.isNotEmpty &&
            cleanVersion != 'Невідомо' &&
            cleanVersion != 'Немає даних') {
          buffer.writeln("Графік (Версія $cleanVersion)");
        } else {
          buffer.writeln("Графік");
        }
      }
    }

    if (outageInfoText.trim().isNotEmpty) {
      buffer.writeln(outageInfoText.trim());
    }

    if (intervals.isNotEmpty) {
      if (buffer.isNotEmpty) {
        buffer.writeln();
      }
      buffer.writeln("Розклад інтервалами:");
      for (final interval in intervals) {
        buffer.writeln(formatIntervalText(interval));
      }
    }

    return buffer.toString().trimRight();
  }
}
