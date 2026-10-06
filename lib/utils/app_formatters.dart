/// Утилітарні функції форматування часу, тривалості, дат та тексту.
class AppFormatters {
  /// Форматування хвилин від початку дня у рядок виду "HH:mm".
  static String formatTime(int minutesFromStart) {
    int hours = minutesFromStart ~/ 60;
    int minutes = minutesFromStart % 60;
    return "${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}";
  }

  /// Форматування тривалості у хвилинах у читабельний рядок виду "Xг Yхв".
  static String formatDuration(int totalMinutes) {
    int hours = totalMinutes ~/ 60;
    int minutes = totalMinutes % 60;
    if (hours > 0 && minutes > 0) return "$hoursг $minutesхв";
    if (hours > 0) return "$hoursг";
    return "$minutesхв";
  }

  /// Форматування дати/часу DateTime у рядок виду "HH:mm".
  static String fmtTime(DateTime dt) {
    return "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
  }

  /// Форматування годин та хвилин у рядок виду "HH:mm".
  static String fmtHM(int h, int m) {
    return "${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}";
  }

  /// Аліас для fmtHM.
  static String formatHourMinute(int h, int m) => fmtHM(h, m);

  /// Форматування дати у ключ виду "YYYY-MM-DD".
  static String formatDateKey(DateTime dt) {
    return "${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}";
  }

  /// Форматування дати у вигляд "DD.MM.YYYY".
  static String formatDate(DateTime dt) {
    return "${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}";
  }

  /// Форматування коду черги/групи у читабельний рядок (наприклад, "GPV2.1" -> "Група 2.1").
  static String formatGroupName(String groupKey) {
    final trimmed = groupKey.trim();
    if (trimmed.isEmpty) return "";
    if (trimmed.startsWith("Група")) return trimmed;
    final clean = trimmed.replaceFirst('GPV', '').trim();
    return clean.isNotEmpty ? "Група $clean" : trimmed;
  }

  /// Грамотне відмінювання українською: 1 версія, 2 версії, 5 версій.
  static String pluralVersions(int count) {
    final mod10 = count % 10;
    final mod100 = count % 100;
    if (mod100 >= 11 && mod100 <= 14) return "версій";
    if (mod10 == 1) return "версія";
    if (mod10 >= 2 && mod10 <= 4) return "версії";
    return "версій";
  }

  /// Форматування тексту сповіщення про зміну графіку на основі різниці у хвилинах відключень.
  static String formatScheduleChangeMessage({
    required int oldMinutes,
    required int newMinutes,
  }) {
    final diff = newMinutes - oldMinutes;
    if (diff != 0) {
      final diffHours = (diff.abs() / 60);
      final diffStr = diffHours == diffHours.toInt()
          ? diffHours.toInt().toString()
          : diffHours.toStringAsFixed(1);
      return diff > 0
          ? "Світла стало МЕНШЕ на $diffStr год. 😔"
          : "Світла стало БІЛЬШЕ на $diffStr год. 🎉";
    } else {
      return "Змінився час відключень на сьогодні ⚡";
    }
  }
}

// Top-level aliases for direct functional usage
String formatTime(int minutesFromStart) =>
    AppFormatters.formatTime(minutesFromStart);
String formatDuration(int totalMinutes) =>
    AppFormatters.formatDuration(totalMinutes);
String fmtTime(DateTime dt) => AppFormatters.fmtTime(dt);
String fmtHM(int h, int m) => AppFormatters.fmtHM(h, m);
String formatHourMinute(int h, int m) => AppFormatters.formatHourMinute(h, m);
String formatDateKey(DateTime dt) => AppFormatters.formatDateKey(dt);
String formatDate(DateTime dt) => AppFormatters.formatDate(dt);
String formatGroupName(String groupKey) =>
    AppFormatters.formatGroupName(groupKey);
String pluralVersions(int count) => AppFormatters.pluralVersions(count);
String formatScheduleChangeMessage({
  required int oldMinutes,
  required int newMinutes,
}) =>
    AppFormatters.formatScheduleChangeMessage(
      oldMinutes: oldMinutes,
      newMinutes: newMinutes,
    );
