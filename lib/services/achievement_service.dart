import 'dart:async';

import '../models/achievement.dart';
import '../models/power_event.dart';
import '../models/schedule_status.dart';
import 'app_logger.dart';
import 'history_service.dart';
import 'power_monitor_service.dart';
import 'preferences_helper.dart';

/// Сервіс для перевірки та розблокування досягнень.
class AchievementService {
  static final AchievementService _instance = AchievementService._internal();
  factory AchievementService() => _instance;
  AchievementService._internal();

  /// Callback для показу нотифікації про нове досягнення
  void Function(AchievementDef achievement)? onAchievementUnlocked;

  // ── Трекери для секретних ачівок ──
  final List<DateTime> _refreshTimestamps = [];
  int _themeToggleCount = 0;
  DateTime? _themeToggleSessionStart;

  // ── Трекер сесій ("Контроль ситуації") ──
  int _sessionCount = 0;
  String? _sessionDay;

  // ── Кеш стану ──
  Map<String, AchievementState> _stateCache = {};
  bool _cacheLoaded = false;

  // ══════════════════════════════════════════
  //  ПУБЛІЧНЕ API
  // ══════════════════════════════════════════

  /// Завантажити стан усіх ачівок з БД.
  Future<Map<String, AchievementState>> loadAllStates() async {
    if (_cacheLoaded) return Map.from(_stateCache);

    final db = await HistoryService().database;

    // Переконатися, що таблиця існує
    await db.execute('''
      CREATE TABLE IF NOT EXISTS achievements (
        achievement_id TEXT PRIMARY KEY,
        unlocked INTEGER DEFAULT 0,
        unlocked_at TEXT,
        progress REAL DEFAULT 0.0
      )
    ''');

    final rows = await db.query('achievements');
    _stateCache = {};
    for (final row in rows) {
      final state = AchievementState.fromMap(row);
      _stateCache[state.achievementId] = state;
    }
    _cacheLoaded = true;
    return Map.from(_stateCache);
  }

  /// Чи розблоковано досягнення?
  Future<bool> isUnlocked(String achievementId) async {
    await loadAllStates();
    return _stateCache[achievementId]?.unlocked ?? false;
  }

  /// Кількість розблокованих.
  Future<int> unlockedCount() async {
    await loadAllStates();
    return _stateCache.values.where((s) => s.unlocked).length;
  }

  /// Повна перевірка ВСІХ досягнень (виклик після синхронізації даних).
  Future<void> checkAll({
    Map<String, FullSchedule>? schedules,
    String? currentGroup,
  }) async {
    await loadAllStates();

    final powerMonitor = PowerMonitorService();
    final allEvents = await _safeGetAllEvents(powerMonitor);

    // ── Survival ──
    await _checkInitiatedIntoDarkness(allEvents);
    await _checkDungeonChild(allEvents);
    await _checkBornInDarkness(allEvents);
    await _checkMarathonRunner(powerMonitor);
    await _checkBlackoutSurvivor(powerMonitor);

    // ── Oracle ──
    if (schedules != null && currentGroup != null) {
      await _checkDeceivedInvestor(schedules, currentGroup, allEvents);
      await _checkHachiko(schedules, currentGroup, allEvents);
      await _checkMatrixGlitch(schedules, currentGroup, powerMonitor);
    }
    // Archivist checked separately via trackHistoryView()

    // ── Lifestyle ──
    await _checkNightWatch(allEvents);
    await _checkLightDisco(allEvents);

    // ── Secret: second_wind ──
    await _checkSecondWind(powerMonitor);

    // ── Tutorial ──
    await _checkCitizen();
    await _checkConnected();

    // ── Casual ──
    await _checkSeemedLike(allEvents);
    await _checkBrightStreak(powerMonitor);
  }

  /// Трекер: pull-to-refresh (для «Нервовий тік»).
  Future<void> trackRefresh() async {
    final now = DateTime.now();
    _refreshTimestamps.add(now);
    // Видаляємо старші ніж 60 секунд
    _refreshTimestamps.removeWhere((t) => now.difference(t).inSeconds > 60);

    if (_refreshTimestamps.length >= 20) {
      await _unlock('nervous_tic');
      _refreshTimestamps.clear();
    }
  }

  /// Трекер: зміна теми (для «Параноїк»).
  Future<void> trackThemeToggle() async {
    final now = DateTime.now();
    if (_themeToggleSessionStart == null ||
        now.difference(_themeToggleSessionStart!).inMinutes > 5) {
      _themeToggleSessionStart = now;
      _themeToggleCount = 0;
    }
    _themeToggleCount++;

    if (_themeToggleCount >= 10) {
      await _unlock('paranoid');
      _themeToggleCount = 0;
    }
  }

  /// Трекер: перегляд історії (для «Архіваріус»).
  Future<void> trackHistoryView(DateTime viewedDate) async {
    final diff = DateTime.now().difference(viewedDate).inDays;
    if (diff >= 30) {
      await _unlock('archivist');
    }
  }

  /// Трекер: зміна групи (для «Громадянин»).
  Future<void> trackGroupChange() async {
    await _unlock('citizen');
  }

  /// Трекер: відкриття через віджет (для «Завжди перед очима»).
  Future<void> trackWidgetOpen() async {
    await _unlock('always_visible');
  }

  /// Трекер: нова сесія додатка (для «Контроль ситуації»).
  Future<void> trackAppSession() async {
    final today = _todayStr();
    if (_sessionDay != today) {
      _sessionDay = today;
      _sessionCount = 0;
    }
    _sessionCount++;
    if (_sessionCount >= 5) {
      await _unlock('situation_control');
    }
  }

  String _todayStr() {
    final n = DateTime.now();
    return '${n.year}-${n.month}-${n.day}';
  }

  // ══════════════════════════════════════════
  //  ПРИВАТНА ЛОГІКА ПЕРЕВІРОК
  // ══════════════════════════════════════════

  Future<List<PowerEvent>> _safeGetAllEvents(PowerMonitorService pm) async {
    try {
      return await pm.getLocalEvents();
    } catch (_) {
      return [];
    }
  }

  // ── 💀 Посвячений у тьму ──
  Future<void> _checkInitiatedIntoDarkness(List<PowerEvent> events) async {
    if (await isUnlocked('initiated_into_darkness')) return;
    final hasOffline = events.any((e) => e.isOffline);
    if (hasOffline) {
      await _unlock('initiated_into_darkness');
    }
  }

  // ── 💀 Дитя підземелля (100 год) ──
  Future<void> _checkDungeonChild(List<PowerEvent> events) async {
    if (await isUnlocked('dungeon_child')) return;
    final totalMinutes = _computeTotalOfflineMinutes(events);
    final progress = (totalMinutes / (100 * 60)).clamp(0.0, 1.0);
    await _updateProgress('dungeon_child', progress);
    if (totalMinutes >= 100 * 60) {
      await _unlock('dungeon_child');
    }
  }

  // ── 💀 Народжений у тьмі (1000 год) ──
  Future<void> _checkBornInDarkness(List<PowerEvent> events) async {
    if (await isUnlocked('born_in_darkness')) return;
    final totalMinutes = _computeTotalOfflineMinutes(events);
    final progress = (totalMinutes / (1000 * 60)).clamp(0.0, 1.0);
    await _updateProgress('born_in_darkness', progress);
    if (totalMinutes >= 1000 * 60) {
      await _unlock('born_in_darkness');
    }
  }

  // ── 💀 Марафонець (12+ годин) ──
  Future<void> _checkMarathonRunner(PowerMonitorService pm) async {
    if (await isUnlocked('marathon_runner')) return;
    try {
      final events = await pm.getLocalEvents();
      final intervals = _buildIntervalsFromEvents(events);
      double maxHours = 0;
      for (final iv in intervals) {
        final hours = iv.duration.inMinutes / 60.0;
        if (hours > maxHours) maxHours = hours;
      }
      final progress = (maxHours / 12.0).clamp(0.0, 1.0);
      await _updateProgress('marathon_runner', progress);
      if (maxHours >= 12.0) {
        await _unlock('marathon_runner');
      }
    } catch (_) {}
  }

  // ── 💀 Блекаут Сюрвайвер (22+ год offline за добу) ──
  Future<void> _checkBlackoutSurvivor(PowerMonitorService pm) async {
    if (await isUnlocked('blackout_survivor')) return;
    try {
      // Перевіряємо останні 30 днів
      for (int i = 0; i < 30; i++) {
        final date = DateTime.now().subtract(Duration(days: i));
        final outageMinutes = await pm.getTotalOutageMinutesForDate(date);
        if (outageMinutes >= 22 * 60) {
          await _unlock('blackout_survivor');
          return;
        }
      }
      // progress = max outage ratio серед перевірених днів
      double maxRatio = 0;
      for (int i = 0; i < 7; i++) {
        final date = DateTime.now().subtract(Duration(days: i));
        final outageMinutes = await pm.getTotalOutageMinutesForDate(date);
        final ratio = outageMinutes / (22 * 60);
        if (ratio > maxRatio) maxRatio = ratio;
      }
      await _updateProgress('blackout_survivor', maxRatio.clamp(0.0, 1.0));
    } catch (_) {}
  }

  // ── 🔮 Обманутий вкладник ──
  Future<void> _checkDeceivedInvestor(
    Map<String, FullSchedule> schedules,
    String currentGroup,
    List<PowerEvent> events,
  ) async {
    if (await isUnlocked('deceived_investor')) return;
    final schedule = schedules[currentGroup];
    if (schedule == null) return;

    // Шукаємо offline-подію під час "зеленої" години
    for (final event in events) {
      if (!event.isOffline) continue;
      final hour = event.timestamp.hour;
      final isToday = _isSameDay(event.timestamp, DateTime.now());
      if (!isToday) continue;

      if (hour < 24 && schedule.today.hours[hour] == LightStatus.on) {
        // Перевіряємо, чи offline тривав > 15 хв
        final nextOnline = events
            .where((e) => e.isOnline && e.timestamp.isAfter(event.timestamp))
            .toList();
        if (nextOnline.isEmpty) {
          // Досі offline
          if (DateTime.now().difference(event.timestamp).inMinutes > 15) {
            await _unlock('deceived_investor');
            return;
          }
        } else {
          final dur = nextOnline.first.timestamp.difference(event.timestamp);
          if (dur.inMinutes > 15) {
            await _unlock('deceived_investor');
            return;
          }
        }
      }
    }
  }

  // ── 🔮 Хатіко ──
  Future<void> _checkHachiko(
    Map<String, FullSchedule> schedules,
    String currentGroup,
    List<PowerEvent> events,
  ) async {
    if (await isUnlocked('hachiko')) return;
    final schedule = schedules[currentGroup];
    if (schedule == null) return;
    final today = DateTime.now();

    // Для кожної години, де графік = on/semiOn, а попередня = off/semiOff,
    // перевіряємо, чи реальний online прийшов більш ніж на 60 хв пізніше
    for (int h = 1; h < 24; h++) {
      final prev = schedule.today.hours[h - 1];
      final curr = schedule.today.hours[h];

      final wasOff = prev == LightStatus.off || prev == LightStatus.semiOff;
      final isOn = curr == LightStatus.on || curr == LightStatus.semiOn;

      if (wasOff && isOn) {
        final expectedOnTime = DateTime(today.year, today.month, today.day, h);
        // Знаходимо перший online після expectedOnTime
        final onlineAfter = events
            .where((e) =>
                e.isOnline &&
                _isSameDay(e.timestamp, today) &&
                e.timestamp.isAfter(expectedOnTime))
            .toList();

        if (onlineAfter.isNotEmpty) {
          final delay = onlineAfter.first.timestamp.difference(expectedOnTime);
          if (delay.inMinutes > 60) {
            await _unlock('hachiko');
            return;
          }
        } else {
          // Досі немає online після обіцяного - якщо > 60 хв
          if (today.isAfter(expectedOnTime) &&
              today.difference(expectedOnTime).inMinutes > 60) {
            // Перевіряємо, чи є offline, що охоплює цей період
            final offlineBeforeH = events
                .where((e) =>
                    e.isOffline &&
                    _isSameDay(e.timestamp, today) &&
                    e.timestamp.isBefore(expectedOnTime))
                .toList();
            if (offlineBeforeH.isNotEmpty) {
              await _unlock('hachiko');
              return;
            }
          }
        }
      }
    }
  }

  // ── 🔮 Збій у Матриці (100% точність за тиждень) ──
  Future<void> _checkMatrixGlitch(
    Map<String, FullSchedule> schedules,
    String currentGroup,
    PowerMonitorService pm,
  ) async {
    if (await isUnlocked('matrix_glitch')) return;

    try {
      int totalHours = 0;
      int matchingHours = 0;

      for (int d = 1; d <= 7; d++) {
        final date = DateTime.now().subtract(Duration(days: d));

        // Отримуємо збережений графік
        final versions =
            await HistoryService().getVersionsForDate(date, currentGroup);
        if (versions.isEmpty) return; // Немає даних — не рахуємо

        final scheduleCode = versions.last.hash;
        final schedule = DailySchedule.fromEncodedString(scheduleCode);

        // Отримуємо реальні інтервали
        final intervals = await pm.getOutageIntervalsForDate(date);
        if (intervals.isEmpty && schedule.isEmpty) continue;

        // Порівнюємо кожну годину
        for (int h = 0; h < 24; h++) {
          totalHours++;
          final offMins = _offlineMinutesInHour(intervals, date, h);
          final status = schedule.hours[h];

          bool match = false;
          if (status == LightStatus.on && offMins <= 10) match = true;
          if (status == LightStatus.off && offMins >= 50) match = true;
          if ((status == LightStatus.semiOn || status == LightStatus.semiOff) &&
              offMins >= 15 &&
              offMins <= 45) {
            match = true;
          }
          if (status == LightStatus.maybe) {
            match = true; // "може бути" — завжди OK
          }

          if (match) matchingHours++;
        }
      }

      if (totalHours > 0) {
        final accuracy = matchingHours / totalHours;
        await _updateProgress('matrix_glitch', accuracy.clamp(0.0, 1.0));
        if (accuracy >= 1.0) {
          await _unlock('matrix_glitch');
        }
      }
    } catch (_) {}
  }

  // ── ⚡ Нічний дожор ──
  Future<void> _checkNightWatch(List<PowerEvent> events) async {
    if (await isUnlocked('night_watch')) return;
    for (final e in events) {
      if (e.isOnline && e.timestamp.hour >= 3 && e.timestamp.hour < 5) {
        await _unlock('night_watch');
        return;
      }
    }
  }

  // ── ⚡ Світлодискотека ──
  Future<void> _checkLightDisco(List<PowerEvent> events) async {
    if (await isUnlocked('light_disco')) return;

    // Sliding window 60 хвилин
    for (int i = 0; i < events.length; i++) {
      final windowStart = events[i].timestamp;
      final windowEnd = windowStart.add(const Duration(hours: 1));
      int togglePairs = 0;

      for (int j = i; j < events.length; j++) {
        if (events[j].timestamp.isAfter(windowEnd)) break;
        if (events[j].isOffline) {
          // Шукаємо наступний online
          if (j + 1 < events.length &&
              events[j + 1].isOnline &&
              events[j + 1].timestamp.isBefore(windowEnd)) {
            togglePairs++;
          }
        }
      }

      if (togglePairs >= 5) {
        await _unlock('light_disco');
        return;
      }
    }
  }

  // ── 🥚 Друге дихання ──
  Future<void> _checkSecondWind(PowerMonitorService pm) async {
    if (await isUnlocked('second_wind')) return;
    try {
      final events = await pm.getLocalEvents();
      final intervals = _buildIntervalsFromEvents(events);

      for (int i = 0; i < intervals.length - 1; i++) {
        final current = intervals[i];
        final next = intervals[i + 1];
        if (current.end != null && next.start.isAfter(current.end!)) {
          final gap = next.start.difference(current.end!);
          if (gap.inMinutes > 0 && gap.inMinutes <= 30) {
            await _unlock('second_wind');
            return;
          }
        }
      }
    } catch (_) {}
  }

  // ── 👶 Громадянин (вибір групи) ──
  Future<void> _checkCitizen() async {
    if (await isUnlocked('citizen')) return;
    try {
      final prefs = await PreferencesHelper.getSafeInstance();
      final group = prefs.getString('selected_group');
      if (group != null && group.isNotEmpty) {
        await _unlock('citizen');
      }
    } catch (_) {}
  }

  // ── 👶 На зв'язку (сповіщення) ──
  Future<void> _checkConnected() async {
    if (await isUnlocked('connected')) return;
    try {
      final prefs = await PreferencesHelper.getSafeInstance();
      final keys = [
        'notify_1h_before_off',
        'notify_30m_before_off',
        'notify_5m_before_off',
        'notify_1h_before_on',
        'notify_30m_before_on',
        'notify_schedule_change',
      ];
      for (final key in keys) {
        if (prefs.getBool(key) == true) {
          await _unlock('connected');
          return;
        }
      }
    } catch (_) {}
  }

  // ── 🌤 Показалось (offline < 5 хв) ──
  Future<void> _checkSeemedLike(List<PowerEvent> events) async {
    if (await isUnlocked('seemed_like')) return;
    final intervals = _buildIntervalsFromEvents(events);
    for (final iv in intervals) {
      if (iv.end != null &&
          iv.duration.inMinutes < 5 &&
          iv.duration.inMinutes > 0) {
        await _unlock('seemed_like');
        return;
      }
    }
  }

  // ── 🌤 Світла смуга (цілий день без відключень) ──
  Future<void> _checkBrightStreak(PowerMonitorService pm) async {
    if (await isUnlocked('bright_streak')) return;
    try {
      // Перевіряємо вчорашній день (він вже завершився)
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      final outageMinutes = await pm.getTotalOutageMinutesForDate(yesterday);
      if (outageMinutes == 0) {
        // Додатково перевіримо, чи є хоча б одна подія за той день (щоб не давати за відсутність даних)
        final events = await pm.getEventsForDate(yesterday);
        if (events.isNotEmpty) {
          await _unlock('bright_streak');
        }
      }
    } catch (_) {}
  }

  // ══════════════════════════════════════════
  //  ДОПОМІЖНІ МЕТОДИ
  // ══════════════════════════════════════════

  int _computeTotalOfflineMinutes(List<PowerEvent> events) {
    int total = 0;
    DateTime? offlineStart;
    for (final e in events) {
      if (e.isOffline) {
        offlineStart ??= e.timestamp;
      } else if (e.isOnline && offlineStart != null) {
        total += e.timestamp.difference(offlineStart).inMinutes;
        offlineStart = null;
      }
    }
    // Якщо зараз offline
    if (offlineStart != null) {
      total += DateTime.now().difference(offlineStart).inMinutes;
    }
    return total;
  }

  List<PowerOutageInterval> _buildIntervalsFromEvents(List<PowerEvent> events) {
    final List<PowerOutageInterval> intervals = [];
    DateTime? offlineStart;
    int? startId;
    for (final e in events) {
      if (e.isOffline) {
        offlineStart ??= e.timestamp;
        startId ??= e.id;
      } else if (e.isOnline && offlineStart != null) {
        intervals.add(PowerOutageInterval(
          start: offlineStart,
          end: e.timestamp,
          startEventId: startId,
          endEventId: e.id,
        ));
        offlineStart = null;
        startId = null;
      }
    }
    if (offlineStart != null) {
      intervals.add(PowerOutageInterval(
        start: offlineStart,
        end: null,
        startEventId: startId,
      ));
    }
    return intervals;
  }

  int _offlineMinutesInHour(
      List<PowerOutageInterval> intervals, DateTime date, int hour) {
    int total = 0;
    for (final iv in intervals) {
      total += iv.minutesOfflineInHour(date, hour);
    }
    return total.clamp(0, 60);
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  // ══════════════════════════════════════════
  //  ЗБЕРЕЖЕННЯ
  // ══════════════════════════════════════════

  Future<void> _unlock(String achievementId) async {
    if (_stateCache[achievementId]?.unlocked == true) return;

    final db = await HistoryService().database;
    final now = DateTime.now();

    await db.rawInsert('''
      INSERT OR REPLACE INTO achievements (achievement_id, unlocked, unlocked_at, progress)
      VALUES (?, 1, ?, 1.0)
    ''', [achievementId, now.toIso8601String()]);

    _stateCache[achievementId] = AchievementState(
      achievementId: achievementId,
      unlocked: true,
      unlockedAt: now,
      progress: 1.0,
    );

    // Сповіщення
    final def = AchievementCatalog.getById(achievementId);
    if (def != null && onAchievementUnlocked != null) {
      onAchievementUnlocked!(def);
    }

    AppLogger.i('🏆 Unlocked: $achievementId', tag: 'Achievements');
  }

  Future<void> _updateProgress(String achievementId, double progress) async {
    if (_stateCache[achievementId]?.unlocked == true) return;

    final db = await HistoryService().database;

    await db.rawInsert('''
      INSERT OR REPLACE INTO achievements (achievement_id, unlocked, unlocked_at, progress)
      VALUES (?, COALESCE((SELECT unlocked FROM achievements WHERE achievement_id = ?), 0),
              (SELECT unlocked_at FROM achievements WHERE achievement_id = ?), ?)
    ''', [achievementId, achievementId, achievementId, progress]);

    _stateCache[achievementId] = AchievementState(
      achievementId: achievementId,
      unlocked: false,
      progress: progress,
    );
  }
}
