import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'power_monitor_service.dart';
import 'preferences_helper.dart';

/// "4 стадії тьми" — автоматична зміна теми інтерфейсу
/// залежно від реального часу без світла за сьогодні.
///
/// 🌿 Solarpunk   — < 4 год без світла
/// ⚙️ Dieselpunk  — 4–8 год без світла
/// 🌃 Cyberpunk   — 8–12 год без світла
/// ☢️ Stalker     — > 12 год без світла
enum DarknessStage {
  solarpunk, // < 4h   – "Все добре. Життя прекрасне."
  dieselpunk, // 4-8h   – "Будь готовий, можливі перебої."
  cyberpunk, // 8-12h  – "Місто занурюється у темряву."
  stalker, // > 12h  – "Економ заряд. Виживай."
}

class DarknessThemeService {
  static final DarknessThemeService _instance =
      DarknessThemeService._internal();
  factory DarknessThemeService() => _instance;
  DarknessThemeService._internal();

  static const String _prefKeyLegacy = 'auto_darkness_theme_enabled';
  static const String _prefKeyMode = 'darkness_theme_mode';
  static const String _prefKeyAnimations = 'animations_enabled';

  /// Режими роботи:
  /// "off" - вимкнено (стандартна тема)
  /// "auto" - автоматично від часу без світла
  /// "solarpunk", "dieselpunk", "cyberpunk", "stalker" - ручний вибір
  String _mode = 'off';

  bool _animationsEnabled = true;

  DarknessStage _currentStage = DarknessStage.solarpunk;
  Timer? _refreshTimer;

  /// Callback — викликається коли стадія змінилася і потрібно оновити тему.
  void Function(DarknessStage stage)? onStageChanged;

  bool get isEnabled => _mode != 'off';
  bool get isAuto => _mode == 'auto';
  String get mode => _mode;
  bool get areAnimationsEnabled => _animationsEnabled;

  DarknessStage get currentStage {
    if (_mode == 'auto') return _currentStage;

    // Якщо вибрано ручний режим, повертаємо відповідну стадію
    switch (_mode) {
      case 'solarpunk':
        return DarknessStage.solarpunk;
      case 'dieselpunk':
        return DarknessStage.dieselpunk;
      case 'cyberpunk':
        return DarknessStage.cyberpunk;
      case 'stalker':
        return DarknessStage.stalker;
    }

    return _currentStage; // Fallback
  }

  /// Ініціалізація: завантажити налаштування та запустити оновлення.
  Future<void> init() async {
    try {
      final prefs = await PreferencesHelper.getSafeInstance();

      // Міграція зі старого ключа
      if (prefs.containsKey(_prefKeyLegacy) &&
          !prefs.containsKey(_prefKeyMode)) {
        final legacyEnabled = prefs.getBool(_prefKeyLegacy) ?? false;
        _mode = legacyEnabled ? 'auto' : 'off';
        await prefs.setString(_prefKeyMode, _mode);
        await prefs.remove(_prefKeyLegacy); // Clean up
      } else {
        _mode = prefs.getString(_prefKeyMode) ?? 'off';
      }

      _animationsEnabled = prefs.getBool(_prefKeyAnimations) ?? true;
    } catch (e) {
      print('[DarknessTheme] Error loading prefs: $e');
    }

    if (_mode == 'auto') {
      await refresh();
      _startPeriodicRefresh();
    } else {
      // Для ручного режиму теж оновимо _currentStage щоб UI (Settings) показував правильний опис
      // хоча getter currentStage і так поверне правильне, але про всяк випадок
      _updateManualStage();
    }
  }

  void _updateManualStage() {
    if (_mode == 'off' || _mode == 'auto') return;

    switch (_mode) {
      case 'solarpunk':
        _currentStage = DarknessStage.solarpunk;
        break;
      case 'dieselpunk':
        _currentStage = DarknessStage.dieselpunk;
        break;
      case 'cyberpunk':
        _currentStage = DarknessStage.cyberpunk;
        break;
      case 'stalker':
        _currentStage = DarknessStage.stalker;
        break;
    }
    // Сповістити про зміну, щоб UI оновився
    onStageChanged?.call(_currentStage);
  }

  /// Встановити чи дозволені анімації
  Future<void> setAnimationsEnabled(bool enabled) async {
    if (_animationsEnabled == enabled) return;
    _animationsEnabled = enabled;

    try {
      final prefs = await PreferencesHelper.getSafeInstance();
      await prefs.setBool(_prefKeyAnimations, enabled);
    } catch (e) {
      print('[DarknessTheme] Error saving animations pref: $e');
    }
    // Сповістити про зміну, щоб UI оновився
    onStageChanged?.call(currentStage);
  }

  /// Встановити режим роботи.
  Future<void> setMode(String newMode) async {
    if (_mode == newMode) return;

    _mode = newMode;
    try {
      final prefs = await PreferencesHelper.getSafeInstance();
      await prefs.setString(_prefKeyMode, newMode);
    } catch (e) {
      print('[DarknessTheme] Error saving pref: $e');
    }

    if (_mode == 'auto') {
      await refresh();
      _startPeriodicRefresh();
    } else if (_mode == 'off') {
      _stopPeriodicRefresh();
      // Повертаємо дефолтну, але вона не буде використовуватись, бо isEnabled = false
    } else {
      _stopPeriodicRefresh();
      _updateManualStage();
    }

    // Завжди викликаємо callback, щоб main.dart оновив тему
    onStageChanged?.call(_currentStage);
  }

  /// Примусове оновлення стадії (тільки для Auto).
  Future<void> refresh() async {
    if (_mode != 'auto') return;

    final monitor = PowerMonitorService();
    if (!monitor.isEnabled) {
      _setStage(DarknessStage.solarpunk);
      return;
    }

    try {
      final totalMinutes =
          await monitor.getTotalOutageMinutesForDate(DateTime.now());
      final hours = totalMinutes / 60.0;
      _setStage(_classifyStage(hours));
    } catch (e) {
      print('[DarknessTheme] Error computing stage: $e');
    }
  }

  DarknessStage _classifyStage(double hoursWithoutPower) {
    if (hoursWithoutPower >= 12) return DarknessStage.stalker;
    if (hoursWithoutPower >= 8) return DarknessStage.cyberpunk;
    if (hoursWithoutPower >= 4) return DarknessStage.dieselpunk;
    return DarknessStage.solarpunk;
  }

  void _setStage(DarknessStage stage) {
    if (stage != _currentStage) {
      _currentStage = stage;
      onStageChanged?.call(stage);
    }
  }

  void _startPeriodicRefresh() {
    _stopPeriodicRefresh();
    _refreshTimer =
        Timer.periodic(const Duration(minutes: 2), (_) => refresh());
  }

  void _stopPeriodicRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  void dispose() {
    _stopPeriodicRefresh();
  }

  // ========================================================
  // МЕТАДАНІ СТАДІЙ
  // ========================================================

  ThemeData getThemeForCurrentStage() => getThemeForStage(_currentStage);

  IconData getArrowIcon({bool forward = true}) {
    switch (_currentStage) {
      case DarknessStage.solarpunk:
        return forward
            ? Icons.arrow_circle_right_outlined
            : Icons.arrow_circle_left_outlined;
      case DarknessStage.dieselpunk:
        return forward ? Icons.arrow_forward_ios : Icons.arrow_back_ios_new;
      case DarknessStage.cyberpunk:
        return forward
            ? Icons.keyboard_double_arrow_right
            : Icons.keyboard_double_arrow_left;
      case DarknessStage.stalker:
        return forward ? Icons.forward : Icons.reply;
    }
  }

  ThemeData getThemeForStage(DarknessStage stage) {
    switch (stage) {
      case DarknessStage.solarpunk:
        return _solarpunkTheme;
      case DarknessStage.dieselpunk:
        return _dieselpunkTheme;
      case DarknessStage.cyberpunk:
        return _cyberpunkTheme;
      case DarknessStage.stalker:
        return _stalkerTheme;
    }
  }

  static String stageName(DarknessStage stage) {
    switch (stage) {
      case DarknessStage.solarpunk:
        return 'Solarpunk';
      case DarknessStage.dieselpunk:
        return 'Dieselpunk';
      case DarknessStage.cyberpunk:
        return 'Cyberpunk';
      case DarknessStage.stalker:
        return 'S.T.A.L.K.E.R.';
    }
  }

  static String stageSubtitle(DarknessStage stage) {
    switch (stage) {
      case DarknessStage.solarpunk:
        return 'Еко-режим';
      case DarknessStage.dieselpunk:
        return 'Індустріальний режим';
      case DarknessStage.cyberpunk:
        return 'Нічне місто';
      case DarknessStage.stalker:
        return 'РЕЖИМ БЛЕКАУТУ';
    }
  }

  static String stageIcon(DarknessStage stage) {
    switch (stage) {
      case DarknessStage.solarpunk:
        return '🌿';
      case DarknessStage.dieselpunk:
        return '⚙️';
      case DarknessStage.cyberpunk:
        return '🌃';
      case DarknessStage.stalker:
        return '☢️';
    }
  }

  static IconData stageFlutterIcon(DarknessStage stage) {
    switch (stage) {
      case DarknessStage.solarpunk:
        return Icons.eco;
      case DarknessStage.dieselpunk:
        return Icons.factory;
      case DarknessStage.cyberpunk:
        return Icons.nights_stay;
      case DarknessStage.stalker:
        return Icons.warning_amber;
    }
  }

  static String stageDescription(DarknessStage stage) {
    switch (stage) {
      case DarknessStage.solarpunk:
        return 'Енергії достатньо. Сонячний день, панелі працюють. Розслабся.';
      case DarknessStage.dieselpunk:
        return 'Генератори гудуть за вікном. Запасись водою. Будь готовий.';
      case DarknessStage.cyberpunk:
        return 'Неон мерехтить у темряві. Місто занурюється в нічь. Тримайся.';
      case DarknessStage.stalker:
        return '[ УВАГА: ТОТАЛЬНИЙ БЛЕКАУТ ]\nЕкономте заряд. Мінімум яскравості. Виживайте.';
    }
  }

  static String stageCondition(DarknessStage stage) {
    switch (stage) {
      case DarknessStage.solarpunk:
        return '< 4 год без світла';
      case DarknessStage.dieselpunk:
        return '4 – 8 год без світла';
      case DarknessStage.cyberpunk:
        return '8 – 12 год без світла';
      case DarknessStage.stalker:
        return '> 12 год без світла';
    }
  }

  /// Головний акцентний колір стадії.
  static Color stageAccentColor(DarknessStage stage) {
    switch (stage) {
      case DarknessStage.solarpunk:
        return const Color(0xFF2E7D32);
      case DarknessStage.dieselpunk:
        return const Color(0xFFFF9800);
      case DarknessStage.cyberpunk:
        return const Color(0xFFFF0080);
      case DarknessStage.stalker:
        return const Color(0xFF39FF14);
    }
  }

  /// Другорядний колір стадії.
  static Color stageSecondaryColor(DarknessStage stage) {
    switch (stage) {
      case DarknessStage.solarpunk:
        return const Color(0xFF66BB6A);
      case DarknessStage.dieselpunk:
        return const Color(0xFFFFB74D);
      case DarknessStage.cyberpunk:
        return const Color(0xFF00FFFF);
      case DarknessStage.stalker:
        return const Color(0xFFFF1744);
    }
  }

  /// Колір фону стадії.
  static Color stageBackgroundColor(DarknessStage stage) {
    switch (stage) {
      case DarknessStage.solarpunk:
        return const Color(0xFFF5FFF5);
      case DarknessStage.dieselpunk:
        return const Color(0xFF2A2A2A);
      case DarknessStage.cyberpunk:
        return const Color(0xFF0A0E21);
      case DarknessStage.stalker:
        return Colors.black;
    }
  }

  // ========================================================
  // 🌿 SOLARPUNK — Еко-режим
  // Відчуття: теплий ранок, сонце, все працює. Зелена утопія.
  // ========================================================
  static final ThemeData _solarpunkTheme = ThemeData(
    brightness: Brightness.light,
    scaffoldBackgroundColor: const Color(0xFFF1F8E9),
    colorScheme: const ColorScheme.light(
      primary: Color(0xFF2E7D32),
      secondary: Color(0xFF66BB6A),
      tertiary: Color(0xFFA5D6A7),
      surface: Color(0xFFFFFDE7),
      onPrimary: Colors.white,
      onSecondary: Colors.white,
      onSurface: Color(0xFF1B5E20),
      outline: Color(0xFFA5D6A7),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFFE8F5E9),
      foregroundColor: Color(0xFF2E7D32),
      elevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(
        color: Color(0xFF2E7D32),
        fontSize: 20,
        fontWeight: FontWeight.w600,
      ),
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 2,
      shadowColor: const Color(0xFF2E7D32).withOpacity(0.12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: const Color(0xFFE8F5E9),
      selectedColor: const Color(0xFF66BB6A),
      labelStyle: const TextStyle(color: Color(0xFF2E7D32)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? const Color(0xFF2E7D32)
              : Colors.grey.shade400),
      trackColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? const Color(0xFF81C784)
              : Colors.grey.shade300),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: Color(0xFF2E7D32),
      foregroundColor: Colors.white,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: Color(0xFF2E7D32),
    ),
    dividerColor: const Color(0xFFC8E6C9),
    iconTheme: const IconThemeData(color: Color(0xFF388E3C)),
    listTileTheme: const ListTileThemeData(
      iconColor: Color(0xFF388E3C),
    ),
    textTheme: const TextTheme(
      bodyLarge: TextStyle(color: Color(0xFF1B5E20)),
      bodyMedium: TextStyle(color: Color(0xFF2E7D32)),
      titleLarge:
          TextStyle(color: Color(0xFF1B5E20), fontWeight: FontWeight.bold),
      titleMedium: TextStyle(color: Color(0xFF2E7D32)),
      labelLarge: TextStyle(color: Color(0xFF2E7D32)),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Color(0xFF2E7D32),
      contentTextStyle: TextStyle(color: Colors.white),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Color(0xFFF1F8E9),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    useMaterial3: true,
  );

  // ========================================================
  // ⚙️ DIESELPUNK — Індустріальний
  // Відчуття: промзона, генератори, дим, метал. Важке повітря.
  // Нагадує цеховий пульт управління зі старими приладами.
  // ========================================================
  static final ThemeData _dieselpunkTheme = ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: const Color(0xFF1C1C1C),
    colorScheme: const ColorScheme.dark(
      primary: Color(0xFFFF9800),
      secondary: Color(0xFFFFB74D),
      tertiary: Color(0xFF795548),
      surface: Color(0xFF2C2C2C),
      onPrimary: Colors.black,
      onSecondary: Colors.black,
      onSurface: Color(0xFFBDBDBD),
      outline: Color(0xFF795548),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF212121),
      foregroundColor: Color(0xFFFF9800),
      elevation: 4,
      titleTextStyle: TextStyle(
        color: Color(0xFFFF9800),
        fontSize: 20,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.5,
      ),
    ),
    cardTheme: CardThemeData(
      color: const Color(0xFF2C2C2C),
      elevation: 4,
      shadowColor: Colors.black87,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(
            color: const Color(0xFFFF9800).withOpacity(0.25), width: 1),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: const Color(0xFF333333),
      selectedColor: const Color(0xFFFF9800),
      labelStyle: const TextStyle(color: Color(0xFFBDBDBD)),
      side: BorderSide(color: const Color(0xFF795548).withOpacity(0.5)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? const Color(0xFFFF9800)
              : const Color(0xFF757575)),
      trackColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? const Color(0xFFFF9800).withOpacity(0.4)
              : const Color(0xFF424242)),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: Color(0xFFFF9800),
      foregroundColor: Colors.black,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: Color(0xFFFF9800),
    ),
    dividerColor: const Color(0xFF424242),
    iconTheme: const IconThemeData(color: Color(0xFFFF9800)),
    listTileTheme: const ListTileThemeData(
      iconColor: Color(0xFFFFB74D),
      textColor: Color(0xFFBDBDBD),
    ),
    textTheme: const TextTheme(
      bodyLarge: TextStyle(color: Color(0xFFBDBDBD)),
      bodyMedium: TextStyle(color: Color(0xFF9E9E9E)),
      titleLarge:
          TextStyle(color: Color(0xFFFF9800), fontWeight: FontWeight.bold),
      titleMedium: TextStyle(color: Color(0xFFFFB74D)),
      labelLarge: TextStyle(color: Color(0xFFFF9800)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: const Color(0xFF333333),
      contentTextStyle: const TextStyle(color: Color(0xFFFFB74D)),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
        side: const BorderSide(color: Color(0xFFFF9800), width: 1),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Color(0xFF1C1C1C),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: const Color(0xFF2C2C2C),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: const Color(0xFFFF9800).withOpacity(0.3)),
      ),
    ),
    useMaterial3: true,
  );

  // ========================================================
  // 🌃 CYBERPUNK — Неон
  // Відчуття: нічне місто, неонові вивіски мерехтять, дощ,
  // голограми, техно-декаданс. High Tech — Low Life.
  // ========================================================
  static final ThemeData _cyberpunkTheme = ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: const Color(0xFF05060F),
    colorScheme: const ColorScheme.dark(
      primary: Color(0xFFFF0080),
      secondary: Color(0xFF00FFFF),
      tertiary: Color(0xFFBB86FC),
      surface: Color(0xFF0E0E1A),
      onPrimary: Colors.white,
      onSecondary: Colors.black,
      onSurface: Color(0xFFCCCCEE),
      outline: Color(0xFF2A2A4A),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF08081A),
      foregroundColor: Color(0xFF00FFFF),
      elevation: 0,
      titleTextStyle: TextStyle(
        color: Color(0xFF00FFFF),
        fontSize: 20,
        fontWeight: FontWeight.bold,
        letterSpacing: 2,
      ),
    ),
    cardTheme: CardThemeData(
      color: const Color(0xFF0E1025),
      elevation: 8,
      shadowColor: const Color(0xFFFF0080).withOpacity(0.25),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFF2A1040), width: 1),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: const Color(0xFF12122A),
      selectedColor: const Color(0xFFFF0080),
      labelStyle: const TextStyle(color: Color(0xFF00FFFF), letterSpacing: 1),
      side: const BorderSide(color: Color(0xFF2A2A4A)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? const Color(0xFFFF0080)
              : const Color(0xFF00FFFF)),
      trackColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? const Color(0xFFFF0080).withOpacity(0.35)
              : const Color(0xFF0E0E1A)),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: Color(0xFFFF0080),
      foregroundColor: Colors.white,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: Color(0xFF00FFFF),
    ),
    dividerColor: const Color(0xFF1A1A35),
    iconTheme: const IconThemeData(color: Color(0xFF00FFFF)),
    listTileTheme: const ListTileThemeData(
      iconColor: Color(0xFFFF0080),
      textColor: Color(0xFFCCCCEE),
    ),
    textTheme: const TextTheme(
      bodyLarge: TextStyle(color: Color(0xFFCCCCEE)),
      bodyMedium: TextStyle(color: Color(0xFF9999BB)),
      titleLarge: TextStyle(
        color: Color(0xFF00FFFF),
        fontWeight: FontWeight.bold,
        letterSpacing: 1.5,
      ),
      titleMedium: TextStyle(color: Color(0xFFFF0080)),
      labelLarge: TextStyle(color: Color(0xFF00FFFF), letterSpacing: 1),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: const Color(0xFF0E0E1A),
      contentTextStyle: const TextStyle(color: Color(0xFF00FFFF)),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Color(0xFFFF0080), width: 1),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Color(0xFF08081A),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: const Color(0xFF0E0E1A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFFF0080), width: 1),
      ),
    ),
    useMaterial3: true,
  );

  // ========================================================
  // ☢️ STALKER — Blackout / Зона відчуження
  // Відчуття: бункер, аварійне освітлення, старий ЕЛТ-монітор,
  // радіація, лічильник Гейгера, вижити будь-якою ціною.
  // Абсолютно чорний OLED-фон. Токсично-зелений як єдине
  // джерело світла — аварійний термінал. Кроваво-червоний —
  // попередження. Monospace — як в терміналі бункера.
  // ========================================================
  static final ThemeData _stalkerTheme = ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: Colors.black,
    colorScheme: const ColorScheme.dark(
      primary: Color(0xFF39FF14),
      secondary: Color(0xFFFF1744),
      tertiary: Color(0xFF76FF03),
      surface: Color(0xFF050505),
      onPrimary: Colors.black,
      onSecondary: Colors.white,
      onSurface: Color(0xFF39FF14),
      outline: Color(0xFF1A1A0A),
      error: Color(0xFFFF1744),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.black,
      foregroundColor: Color(0xFF39FF14),
      elevation: 0,
      titleTextStyle: TextStyle(
        color: Color(0xFF39FF14),
        fontSize: 18,
        fontWeight: FontWeight.bold,
        fontFamily: 'monospace',
        letterSpacing: 3,
      ),
    ),
    cardTheme: CardThemeData(
      color: const Color(0xFF030303),
      elevation: 0,
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(2),
        side: BorderSide(
          color: const Color(0xFF39FF14).withOpacity(0.4),
          width: 1,
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: Colors.black,
      selectedColor: const Color(0xFF39FF14).withOpacity(0.2),
      labelStyle: const TextStyle(
        color: Color(0xFF39FF14),
        fontFamily: 'monospace',
        fontSize: 12,
        letterSpacing: 1,
      ),
      side: const BorderSide(color: Color(0xFF39FF14), width: 1),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? const Color(0xFF39FF14)
              : const Color(0xFFFF1744)),
      trackColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? const Color(0xFF39FF14).withOpacity(0.2)
              : const Color(0xFF1A0000)),
      trackOutlineColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? const Color(0xFF39FF14).withOpacity(0.5)
              : const Color(0xFFFF1744).withOpacity(0.3)),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: Color(0xFF39FF14),
      foregroundColor: Colors.black,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: Color(0xFF39FF14),
    ),
    dividerColor: const Color(0xFF0D0D00),
    iconTheme: const IconThemeData(color: Color(0xFF39FF14), size: 20),
    listTileTheme: const ListTileThemeData(
      iconColor: Color(0xFF39FF14),
      textColor: Color(0xFF39FF14),
    ),
    textTheme: const TextTheme(
      bodyLarge: TextStyle(
        color: Color(0xFF39FF14),
        fontFamily: 'monospace',
        fontSize: 14,
        height: 1.4,
      ),
      bodyMedium: TextStyle(
        color: Color(0xFF2BD90E),
        fontFamily: 'monospace',
        fontSize: 13,
      ),
      bodySmall: TextStyle(
        color: Color(0xFF1FA00A),
        fontFamily: 'monospace',
        fontSize: 11,
      ),
      titleLarge: TextStyle(
        color: Color(0xFF39FF14),
        fontWeight: FontWeight.bold,
        fontFamily: 'monospace',
        letterSpacing: 3,
        fontSize: 20,
      ),
      titleMedium: TextStyle(
        color: Color(0xFF39FF14),
        fontFamily: 'monospace',
        letterSpacing: 2,
        fontWeight: FontWeight.w600,
      ),
      titleSmall: TextStyle(
        color: Color(0xFF39FF14),
        fontFamily: 'monospace',
        letterSpacing: 1,
      ),
      labelLarge: TextStyle(
        color: Color(0xFF39FF14),
        fontFamily: 'monospace',
        letterSpacing: 1.5,
      ),
      labelMedium: TextStyle(
        color: Color(0xFF39FF14),
        fontFamily: 'monospace',
      ),
      labelSmall: TextStyle(
        color: Color(0xFF2BD90E),
        fontFamily: 'monospace',
        fontSize: 10,
      ),
      headlineSmall: TextStyle(
        color: Color(0xFF39FF14),
        fontFamily: 'monospace',
        fontWeight: FontWeight.bold,
        letterSpacing: 2,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: Colors.black,
      contentTextStyle: const TextStyle(
        color: Color(0xFFFF1744),
        fontFamily: 'monospace',
        letterSpacing: 1,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(0),
        side: const BorderSide(color: Color(0xFFFF1744), width: 1),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: Colors.black,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(2)),
        side: BorderSide(color: Color(0xFF39FF14), width: 1),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Colors.black,
      titleTextStyle: const TextStyle(
        color: Color(0xFFFF1744),
        fontFamily: 'monospace',
        fontWeight: FontWeight.bold,
        fontSize: 18,
        letterSpacing: 2,
      ),
      contentTextStyle: const TextStyle(
        color: Color(0xFF39FF14),
        fontFamily: 'monospace',
        fontSize: 14,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(2),
        side: const BorderSide(color: Color(0xFF39FF14), width: 1),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      fillColor: const Color(0xFF050500),
      filled: true,
      labelStyle:
          const TextStyle(color: Color(0xFF39FF14), fontFamily: 'monospace'),
      hintStyle: TextStyle(
          color: const Color(0xFF39FF14).withOpacity(0.3),
          fontFamily: 'monospace'),
      enabledBorder: const OutlineInputBorder(
        borderSide: BorderSide(color: Color(0xFF39FF14), width: 1),
      ),
      focusedBorder: const OutlineInputBorder(
        borderSide: BorderSide(color: Color(0xFF39FF14), width: 2),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border.all(color: const Color(0xFF39FF14)),
      ),
      textStyle: const TextStyle(
          color: Color(0xFF39FF14), fontFamily: 'monospace', fontSize: 12),
    ),
    useMaterial3: true,
  );
}
