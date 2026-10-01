import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/power_event.dart';
import 'app_logger.dart';
import 'history_service.dart';
import 'preferences_helper.dart';

/// Сервіс моніторингу електроенергії через Firebase Realtime Database (REST API).
class PowerMonitorService {
  static final PowerMonitorService _instance = PowerMonitorService._internal();
  factory PowerMonitorService() => _instance;
  PowerMonitorService._internal();

  static const Duration defaultPollingInterval = Duration(seconds: 30);
  static const Duration maxPollingInterval = Duration(minutes: 5);
  static const Duration authErrorPollingInterval = Duration(minutes: 10);

  String? _customUrl;

  Timer? _pollTimer;
  String _currentStatus = 'unknown'; // 'online' / 'offline' / 'unknown'
  DateTime? _lastEventTime;
  bool _isEnabled = false;

  int _consecutiveErrors = 0;
  String? _lastSyncError;
  bool _hadPreviousError = false;
  bool _wasAuthError = false;
  bool _isSyncing = false;
  Duration _currentPollDelay = defaultPollingInterval;

  String? get lastSyncError => _lastSyncError;
  int get consecutiveErrors => _consecutiveErrors;
  Duration get currentPollDelay => _currentPollDelay;

  /// Обчислення наступної затримки опитування (Exponential Backoff для помилок)
  static Duration calculateNextPollDelay({
    required int consecutiveErrors,
    required bool isAuthError,
    Duration baseInterval = defaultPollingInterval,
    Duration maxInterval = maxPollingInterval,
    Duration authErrorInterval = authErrorPollingInterval,
  }) {
    if (isAuthError) {
      return authErrorInterval;
    }
    if (consecutiveErrors <= 0) {
      return baseInterval;
    }
    // Клемпимо ступінь зсуву (0..10), щоб запобігти переповненню цілих чисел (integer overflow)
    // при тривалій відсутності зв'язку (>32 або >64 помилок)
    final shift = (consecutiveErrors - 1).clamp(0, 10);
    final multiplier = 1 << shift;
    final delaySeconds = (baseInterval.inSeconds * multiplier).clamp(
      baseInterval.inSeconds,
      maxInterval.inSeconds,
    );
    return Duration(seconds: delaySeconds);
  }

  static final RegExp _authErrorPattern = RegExp(r'\b(401|403)\b');

  /// Перевірка чи є помилка проблемою авторизації/прав доступу (HTTP 401/403)
  static bool isAuthorizationError(dynamic error) {
    if (error == null) return false;
    final str = error.toString().toLowerCase();
    return _authErrorPattern.hasMatch(str) ||
        str.contains('permission denied') ||
        str.contains('unauthorized');
  }

  final List<void Function(String status)> _statusListeners = [];

  void addStatusListener(void Function(String status) listener) {
    if (!_statusListeners.contains(listener)) {
      _statusListeners.add(listener);
    }
  }

  void removeStatusListener(void Function(String status) listener) {
    _statusListeners.remove(listener);
  }

  void Function(String status)? _onStatusChangedLegacy;
  void Function(String status)? get onStatusChanged => _onStatusChangedLegacy;
  set onStatusChanged(void Function(String status)? callback) {
    if (_onStatusChangedLegacy != null) {
      _statusListeners.remove(_onStatusChangedLegacy);
    }
    _onStatusChangedLegacy = callback;
    if (callback != null) {
      _statusListeners.add(callback);
    }
  }

  void _notifyStatusChanged(String status) {
    for (final listener in List.of(_statusListeners)) {
      try {
        listener(status);
      } catch (e) {
        AppLogger.e('Error in status listener', tag: 'PowerMonitor', error: e);
      }
    }
  }

  String get currentStatus => _currentStatus;
  DateTime? get lastEventTime => _lastEventTime;
  bool get isEnabled => _isEnabled;
  bool get isOnline => _currentStatus == 'online';
  bool get isOffline => _currentStatus == 'offline';
  String? get customUrl => _customUrl;

  /// Ініціалізація: завантажити налаштування і запустити polling.
  Future<void> init() async {
    SharedPreferences? prefs;
    try {
      prefs = await PreferencesHelper.getSafeInstance();
    } catch (e) {
      AppLogger.w(
          "Error loading SharedPreferences in PowerMonitorService.init: $e",
          tag: 'PowerMonitor');
    }
    _isEnabled = prefs?.getBool('power_monitor_enabled') ?? false;
    _customUrl = prefs?.getString('custom_power_monitor_url');

    if (_isEnabled) {
      // Cleanup bad data first
      await cleanupPhantomEvents();

      // Load local state immediately to avoid "unknown" status
      getLocalEvents().then((events) {
        if (events.isNotEmpty) {
          _updateCurrentStatus(events);
        }
      });
      await _fetchAndSync(isFullSync: true);
      startPolling();
    }
  }

  /// Увімкнути/вимкнути моніторинг.
  Future<void> setEnabled(bool enabled) async {
    _isEnabled = enabled;
    _consecutiveErrors = 0;
    _hadPreviousError = false;
    _wasAuthError = false;
    _lastSyncError = null;
    _currentPollDelay = defaultPollingInterval;
    try {
      final prefs = await PreferencesHelper.getSafeInstance();
      await prefs.setBool('power_monitor_enabled', enabled);
    } catch (e) {
      AppLogger.e("Error saving power_monitor_enabled",
          tag: 'PowerMonitor', error: e);
    }

    if (enabled) {
      await _fetchAndSync(isFullSync: true);
      startPolling();
    } else {
      stopPolling();
      _currentStatus = 'unknown';
      _notifyStatusChanged(_currentStatus);
    }
  }

  /// Запуск polling з підтримкою динамічного інтервалу.
  void startPolling({Duration? initialDelay}) {
    stopPolling();
    _scheduleNextPoll(initialDelay ?? _currentPollDelay);
  }

  void _scheduleNextPoll(Duration delay) {
    _pollTimer?.cancel();
    if (!_isEnabled || _customUrl == null || _customUrl!.isEmpty) return;
    _pollTimer = Timer(delay, () async {
      await _fetchAndSync();
    });
  }

  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// Головна функція: завантажити події з Firebase → зберегти локально → оновити статус.
  Future<void> _fetchAndSync({bool isFullSync = false}) async {
    if (!_isEnabled) return;
    if (_isSyncing) {
      AppLogger.d(
          "PowerMonitor: Синхронізація вже триває, пропускаємо виклик...",
          tag: 'PowerMonitor');
      return;
    }
    _isSyncing = true;

    try {
      final events = await _fetchFromFirebase();
      if (!_isEnabled) return;
      if (events.isNotEmpty) {
        if (isFullSync) {
          await _performFullSync(events);
        } else {
          await _saveToLocalDb(events);
        }
        _updateCurrentStatus(events);
      }

      // Успішне відновлення зв'язку
      if (_hadPreviousError) {
        AppLogger.i("PowerMonitor: З'єднання з Firebase успішно відновлено.",
            tag: 'PowerMonitor', persistToHistory: true);
      }
      _consecutiveErrors = 0;
      _hadPreviousError = false;
      _wasAuthError = false;
      _lastSyncError = null;
      _currentPollDelay = defaultPollingInterval;
      _scheduleNextPoll(_currentPollDelay);
    } catch (e) {
      _consecutiveErrors++;
      final isAuth = isAuthorizationError(e);
      _lastSyncError = e.toString();
      _currentPollDelay = calculateNextPollDelay(
        consecutiveErrors: _consecutiveErrors,
        isAuthError: isAuth,
      );

      // Записуємо в історію БД лише першу помилку або зміну типу помилки, щоб не засмічувати логи кожні 30 секунд
      final shouldPersist = !_hadPreviousError || (isAuth && !_wasAuthError);
      _hadPreviousError = true;
      _wasAuthError = isAuth;

      if (isAuth) {
        if (shouldPersist) {
          AppLogger.w(
            'PowerMonitor: Помилка доступу до Firebase (HTTP 401/403). '
            'Опитування призупинено на ${_currentPollDelay.inMinutes} хв. Перевірте URL або правила Firebase (.read: true).',
            tag: 'PowerMonitor',
            persistToHistory: true,
          );
        } else {
          AppLogger.d(
            'PowerMonitor: Доступ заборонено (401/403). Наступна спроба через ${_currentPollDelay.inMinutes} хв.',
            tag: 'PowerMonitor',
          );
        }
      } else {
        if (shouldPersist) {
          AppLogger.e('Sync error',
              tag: 'PowerMonitor', error: e, persistToHistory: true);
        } else {
          AppLogger.d(
            'PowerMonitor: Помилка синхронізації ($e). Backoff ${_currentPollDelay.inSeconds}с (помилка #$_consecutiveErrors).',
            tag: 'PowerMonitor',
          );
        }
      }

      // Fallback: спробувати прочитати з локальної БД
      try {
        final localEvents = await getLocalEvents();
        if (localEvents.isNotEmpty) {
          _updateCurrentStatus(localEvents);
        }
      } catch (_) {}

      _scheduleNextPoll(_currentPollDelay);
    } finally {
      _isSyncing = false;
    }
  }

  /// Повна синхронізація: видалити всі НЕ РУЧНІ локальні події і записати нові з Firebase.
  Future<void> _performFullSync(List<PowerEvent> firebaseEvents) async {
    final db = await HistoryService().database;

    // 1. Delete all non-manual events
    await db.delete('power_events', where: 'is_manual = 0');

    // 2. Insert all firebase events
    // We reuse logic from _saveToLocalDb but since we cleared the table,
    // we don't need to check for existence of non-manual events.
    // BUT we still need to respect manual events if they exist (is_manual=1 were NOT deleted).

    // To be safe and consistent, we can just call _saveToLocalDb.
    // It handles "INSERT OR REPLACE" and manual checks.
    // But since we just deleted is_manual=0, _saveToLocalDb will just insert them.
    await _saveToLocalDb(firebaseEvents);

    AppLogger.i('Full sync completed. Loaded ${firebaseEvents.length} events.',
        tag: 'PowerMonitor');
  }

  // 1. ИСПРАВЛЕННЫЙ МЕТОД ЗАГРУЗКИ (Сортировка по времени, а не ключу)
  Future<List<PowerEvent>> _fetchFromFirebase() async {
    if (_customUrl == null || _customUrl!.trim().isEmpty) return [];

    var baseUrl = _customUrl!.trim();
    if (baseUrl.endsWith('/')) {
      baseUrl = baseUrl.substring(0, baseUrl.length - 1);
    }

    // Запрашиваем события. Лучше фильтровать по timestamp, если возможно,
    // но для надежности берем последние 100-200 записей, чтобы закрыть "дыры" истории.
    // limitToLast=200 гарантирует, что мы получим актуальные данные даже при плохом интернете.
    final url = '$baseUrl/events.json?orderBy="\$key"&limitToLast=200';

    final response =
        await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }

    final contentType = response.headers['content-type'] ?? '';
    if (!contentType.contains('application/json')) {
      throw FormatException(
          'Invalid Content-Type. Expected JSON but got: $contentType');
    }

    final body = response.body;
    if (body == 'null' || body.isEmpty) return [];

    final Map<String, dynamic> data = jsonDecode(body);
    final List<PowerEvent> events = [];

    for (final entry in data.entries) {
      if (entry.value is Map<String, dynamic>) {
        try {
          events.add(PowerEvent.fromFirebase(entry.key, entry.value));
        } catch (e) {
          AppLogger.e('Parse error', tag: 'PowerMonitor', error: e);
        }
      }
    }

    // КРИТИЧНО: Сортируем строго по времени Dart, а не по строкам ключей
    events.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return events;
  }

  Future<bool> testAndSetUrl(String newUrl) async {
    try {
      var baseUrl = newUrl.trim();
      if (baseUrl.endsWith('/')) {
        baseUrl = baseUrl.substring(0, baseUrl.length - 1);
      }
      if (baseUrl.isEmpty) return false;

      // Firebase requires orderBy when using limitToLast
      final url = '$baseUrl/events.json?orderBy="\$key"&limitToLast=1';
      final response =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        return false;
      }

      final contentType = response.headers['content-type'] ?? '';
      if (!contentType.contains('application/json')) {
        return false;
      }

      final body = response.body;
      if (body != 'null' && body.isNotEmpty) {
        // Just checking if it's valid JSON map format
        final data = jsonDecode(body);
        if (data is! Map) {
          // Technically it could be an array of nulls but usually Firebase returns a map for objects
          // We just ensure it doesn't throw.
        }
      }

      final prefs = await PreferencesHelper.getSafeInstance();
      await prefs.setString('custom_power_monitor_url', baseUrl);
      _customUrl = baseUrl;
      _consecutiveErrors = 0;
      _hadPreviousError = false;
      _wasAuthError = false;
      _lastSyncError = null;
      _currentPollDelay = defaultPollingInterval;

      if (_isEnabled) {
        await _fetchAndSync(isFullSync: true);
        startPolling();
      }

      return true;
    } catch (e) {
      AppLogger.e('testAndSetUrl error', tag: 'PowerMonitor', error: e);
      return false;
    }
  }

  // 2. ИСПРАВЛЕННЫЙ МЕТОД СОХРАНЕНИЯ (Без модификации времени!)
  Future<void> _saveToLocalDb(List<PowerEvent> events) async {
    final db = await HistoryService().database;
    final batch = db.batch();

    for (final event in events) {
      // Сохраняем "как есть". Коррекцию роутера (6 мин) делаем ТОЛЬКО при отображении.
      // Это позволяет менять логику (например, изменить 6 мин на 5) без очистки БД.
      final timeStr =
          event.timestamp.toIso8601String(); // Используем ISO8601 для точности

      batch.rawInsert(
        'INSERT OR REPLACE INTO power_events (firebase_key, status, timestamp, device, synced_at, is_manual) '
        'VALUES (?, ?, ?, ?, ?, COALESCE((SELECT is_manual FROM power_events WHERE firebase_key = ?), 0))',
        [
          event.firebaseKey,
          event.status,
          timeStr, // Чистое время из Firebase
          event.device,
          DateTime.now().toIso8601String(),
          event.firebaseKey // Для проверки is_manual
        ],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> _updateCurrentStatus(List<PowerEvent> events) async {
    if (events.isEmpty) {
      _currentStatus = 'unknown';
    } else {
      // Events are sorted by timestamp ASC, so last is the latest
      final latest = events.last;
      _currentStatus = latest.status;

      // Ensure we track the latest update time
      if (_lastEventTime == null || latest.timestamp.isAfter(_lastEventTime!)) {
        _lastEventTime = latest.timestamp;
      }
    }

    AppLogger.d('Status updated to: $_currentStatus', tag: 'PowerMonitor');
    _notifyStatusChanged(_currentStatus);
  }

  /// Отримати всі події з локальної БД (відсортовані за timestamp).
  Future<List<PowerEvent>> getLocalEvents() async {
    final db = await HistoryService().database;
    final maps = await db.query(
      'power_events',
      orderBy: 'timestamp ASC',
    );
    return maps.map((m) => PowerEvent.fromMap(m)).toList();
  }

  /// Отримати події для конкретної дати з локальної БД.
  Future<List<PowerEvent>> getEventsForDate(DateTime date) async {
    final db = await HistoryService().database;
    final dateStr =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

    final maps = await db.query(
      'power_events',
      where: "timestamp LIKE ?",
      whereArgs: ['$dateStr%'],
      orderBy: 'timestamp ASC',
    );
    return maps.map((m) => PowerEvent.fromMap(m)).toList();
  }

  Future<List<PowerOutageInterval>> getOutageIntervalsForDate(
      DateTime date) async {
    // 1. Определяем границы дня
    final dayStart = DateTime(date.year, date.month, date.day);
    final dayEnd = dayStart.add(const Duration(days: 1));

    // 2. Получаем ВСЕ события (сортированные), чтобы найти контекст
    // Оптимизация: берем события за этот день + 1 последнее событие ДО этого дня
    // (чтобы понять, с чем мы вошли в этот день - со светом или без)

    // Для простоты берем все локальные (SQLite быстр), но лучше сделать запрос:
    // "SELECT * FROM power_events WHERE timestamp <= dayEnd ORDER BY timestamp ASC"
    final allEvents = await getLocalEvents();

    if (allEvents.isEmpty) return [];

    // 3. Настройки коррекции (6 минут)
    const int routerDelayMinutes = 0;

    List<PowerOutageInterval> intervals = [];

    // Находим состояние на момент начала дня (00:00)
    // Ищем последнее событие, которое произошло ДО dayStart
    PowerEvent? lastEventBeforeToday;
    try {
      lastEventBeforeToday =
          allEvents.lastWhere((e) => e.timestamp.isBefore(dayStart));
    } catch (e) {
      lastEventBeforeToday = null;
    }

    // Текущее состояние курсора времени
    DateTime cursor = dayStart;
    bool isCurrentlyOffline = false;
    int? currentStartId;

    // Если до начала дня было OFFLINE -> значит день начинается без света
    // Если было ONLINE -> проверяем, прошло ли 6 минут?
    if (lastEventBeforeToday != null) {
      if (lastEventBeforeToday.isOffline) {
        isCurrentlyOffline = true;
        currentStartId = lastEventBeforeToday.id;
      } else {
        // Был ONLINE. Но если он включился в 23:58 вчера?
        // Применяем логику задержки: "Свет есть" считается только через 6 мин после включения.
        DateTime realOnlineTime = lastEventBeforeToday.timestamp
            .add(const Duration(minutes: routerDelayMinutes));
        if (realOnlineTime.isAfter(dayStart)) {
          // Роутер загрузился уже сегодня (например в 00:04), значит до 00:04 света формально "не было" (интернета не было)
          // Но для графика отключений лучше считать физическое электричество.
          // Если мы трекаем именно интернет/роутер, то оставляем offline.
          // Если электричество - то считаем online.
          // Твой код подразумевает: Online Event = Router Connect. Power ON was 6 mins ago.
          // Значит Power ON event time = event.timestamp - 6 min.
        }
      }
    }

    // Фильтруем события, которые влияют на текущий день
    // (включая те, что могли начаться чуть раньше, но из-за коррекции попали в этот день)
    for (final event in allEvents) {
      // Расчетное время появления электричества (время события - 6 минут)
      // Время исчезновения электричества = времени события (моментально)
      DateTime effectiveTime = event.timestamp;

      if (event.isOnline) {
        effectiveTime = event.timestamp
            .subtract(const Duration(minutes: routerDelayMinutes));
      }

      // Если событие (с учетом коррекции) произошло после конца дня -> стоп
      if (effectiveTime.isAfter(dayEnd)) break;

      // Если событие (с учетом коррекции) произошло до начала дня -> пропускаем,
      // так как мы уже учли начальное состояние через lastEventBeforeToday
      if (effectiveTime.isBefore(dayStart)) continue;

      if (event.isOffline) {
        if (!isCurrentlyOffline) {
          // Свет пропал
          isCurrentlyOffline = true;
          cursor = effectiveTime; // Запоминаем начало отключения
          currentStartId = event.id;
        }
      } else {
        // Event is Online
        if (isCurrentlyOffline) {
          // Свет появился
          isCurrentlyOffline = false;

          // Добавляем интервал
          intervals.add(PowerOutageInterval(
            start: cursor.isBefore(dayStart)
                ? dayStart
                : cursor, // Обрезаем по 00:00
            end: effectiveTime,
            startEventId: currentStartId,
            endEventId: event.id,
          ));
        }
      }
    }

    // Если день закончился, а свет так и не дали (или сейчас он выключен)
    if (isCurrentlyOffline) {
      // Интервал до "сейчас" или до конца дня
      intervals.add(PowerOutageInterval(
        start: cursor.isBefore(dayStart) ? dayStart : cursor,
        end: null, // null означает "по текущий момент"
        startEventId: currentStartId,
      ));
    }

    return intervals;
  }

  Future<void> deleteEvent(int id) async {
    final db = await HistoryService().database;
    await db.delete('power_events', where: 'id = ?', whereArgs: [id]);
    final events = await getLocalEvents();
    _updateCurrentStatus(events);
  }

  Future<PowerEvent?> getEvent(int id) async {
    final db = await HistoryService().database;
    final maps = await db.query(
      'power_events',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (maps.isNotEmpty) {
      return PowerEvent.fromMap(maps.first);
    }
    return null;
  }

  Future<void> updateEventTimestamp(int id, DateTime newTime) async {
    final db = await HistoryService().database;
    final timeStr =
        '${newTime.year}-${newTime.month.toString().padLeft(2, '0')}-${newTime.day.toString().padLeft(2, '0')} '
        '${newTime.hour.toString().padLeft(2, '0')}:${newTime.minute.toString().padLeft(2, '0')}:${newTime.second.toString().padLeft(2, '0')}';

    // Set is_manual = 1 to protect from future sync overwrites
    await db.update('power_events', {'timestamp': timeStr, 'is_manual': 1},
        where: 'id = ?', whereArgs: [id]);
    final events = await getLocalEvents();
    _updateCurrentStatus(events);
  }

  Future<void> deleteEventByTimestamp(DateTime timestamp) async {
    final db = await HistoryService().database;
    final timeStr =
        '${timestamp.year}-${timestamp.month.toString().padLeft(2, '0')}-${timestamp.day.toString().padLeft(2, '0')} '
        '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}:${timestamp.second.toString().padLeft(2, '0')}';

    // Delete by timestamp (and optionally status/device if needed, but timestamp is usually unique enough for user action)
    await db.delete('power_events',
        where: 'timestamp LIKE ?', whereArgs: ['$timeStr%']);
    final events = await getLocalEvents();
    _updateCurrentStatus(events);
  }

  Future<void> cleanupPhantomEvents() async {
    try {
      final db = await HistoryService().database;
      // Delete events with null ID or weird state
      await db.delete('power_events', where: 'id IS NULL');
    } catch (e) {
      AppLogger.e("Cleanup error", tag: 'PowerMonitor', error: e);
    }
  }

  /// Обчислити загальний час без світла за дату (у хвилинах).
  Future<int> getTotalOutageMinutesForDate(DateTime date) async {
    final intervals = await getOutageIntervalsForDate(date);
    final dayStart = DateTime(date.year, date.month, date.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    int total = 0;

    for (final interval in intervals) {
      final effectiveStart =
          interval.start.isBefore(dayStart) ? dayStart : interval.start;
      final effectiveEnd = interval.end == null
          ? (DateTime.now().isBefore(dayEnd) ? DateTime.now() : dayEnd)
          : (interval.end!.isAfter(dayEnd) ? dayEnd : interval.end!);
      total += effectiveEnd.difference(effectiveStart).inMinutes;
    }
    return total;
  }

  /// Примусове оновлення (pull-to-refresh).
  Future<void> forceRefresh() async {
    if (!_isEnabled) return;
    await _fetchAndSync(isFullSync: true);
  }

  void dispose() {
    stopPolling();
  }
}
