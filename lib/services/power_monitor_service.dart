import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../models/power_event.dart';
import '../models/power_monitor_status.dart';
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
  static const Duration defaultHeartbeatTtl = Duration(minutes: 25);
  static const Duration defaultEventTtl = Duration(hours: 24);

  /// Allowed heartbeat / staleness TTL durations in minutes (0 = disabled).
  static const List<int> allowedTtlMinutes = [
    0,
    5,
    15,
    25,
    45,
    60,
    720,
    1440,
  ];

  String? _customUrl;

  Timer? _pollTimer;
  Timer? _stalenessTimer;
  String _currentStatus = 'unknown'; // 'online' / 'offline' / 'unknown'
  String _rawLastStatus = 'unknown';
  DateTime? _lastEventTime;
  DateTime? _lastSeen;
  DateTime? _lastSuccessfulSync;
  bool _isEnabled = false;
  bool _isLastEventManual = false;
  Duration _heartbeatTtl = defaultHeartbeatTtl;
  final Duration _eventTtl = defaultEventTtl;
  PowerMonitorSnapshot _snapshot = PowerMonitorSnapshot.unknown();

  int _consecutiveErrors = 0;
  String? _lastSyncError;
  bool _hadPreviousError = false;
  bool _wasAuthError = false;
  bool _isSyncing = false;
  Duration _currentPollDelay = defaultPollingInterval;

  String? get lastSyncError => _lastSyncError;
  int get consecutiveErrors => _consecutiveErrors;
  Duration get currentPollDelay => _currentPollDelay;
  DateTime? get lastSeen => _lastSeen;
  DateTime? get lastSuccessfulSync => _lastSuccessfulSync;
  Duration get heartbeatTtl => _heartbeatTtl;
  PowerMonitorSnapshot get snapshot => _snapshot;
  RealPowerState get effectiveState => _snapshot.status;

  /// Парсинг різноманітних форматів last_seen (рядок, unix timestamp, Map)
  static DateTime? parseLastSeen(dynamic raw) {
    if (raw == null) return null;
    if (raw is int) {
      final ms = raw < 10000000000 ? raw * 1000 : raw;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    if (raw is double) {
      if (raw.isNaN || raw.isInfinite) return null;
      final ms = raw < 10000000000 ? (raw * 1000).toInt() : raw.toInt();
      return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    if (raw is Map) {
      final val =
          raw['timestamp'] ?? raw['last_seen'] ?? raw['time'] ?? raw['date'];
      return parseLastSeen(val);
    }
    if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return null;
      final asNum = int.tryParse(trimmed);
      if (asNum != null) {
        final ms = asNum < 10000000000 ? asNum * 1000 : asNum;
        return DateTime.fromMillisecondsSinceEpoch(ms);
      }
      final parsedIso = DateTime.tryParse(trimmed);
      if (parsedIso != null) return parsedIso;
      return PowerEvent.parseTimestamp(trimmed);
    }
    return null;
  }

  /// Чиста функція розрахунку стану монітора з урахуванням застарівання
  static PowerMonitorSnapshot evaluatePowerState({
    required bool isEnabled,
    required String? customUrl,
    int consecutiveErrors = 0,
    DateTime? lastSeen,
    DateTime? lastEventTime,
    DateTime? lastSyncTime,
    String? errorMessage,
    String? rawStatus,
    Duration ttl = defaultHeartbeatTtl,
    Duration eventTtl = defaultEventTtl,
    DateTime? now,
    bool isLastEventManual = false,
    bool isLocalApiAvailable = false,
  }) {
    final currentTime = now ?? DateTime.now();

    if (!isEnabled) {
      return PowerMonitorSnapshot.unknown(
        reason: PowerStateReason.disabled,
        lastSeen: lastSeen,
        lastEventTime: lastEventTime,
        lastSyncTime: lastSyncTime,
        errorMessage: errorMessage,
        ttl: ttl,
      );
    }

    final hasValidUrl = customUrl != null && customUrl.trim().isNotEmpty;
    final hasValidSource =
        hasValidUrl || (isLastEventManual && isLocalApiAvailable);
    if (!hasValidSource) {
      return PowerMonitorSnapshot.unknown(
        reason: PowerStateReason.notConfigured,
        lastSeen: lastSeen,
        lastEventTime: lastEventTime,
        lastSyncTime: lastSyncTime,
        errorMessage: errorMessage,
        ttl: ttl,
      );
    }

    if (consecutiveErrors >= 3 && !isLastEventManual) {
      return PowerMonitorSnapshot.unknown(
        reason: PowerStateReason.networkError,
        lastSeen: lastSeen,
        lastEventTime: lastEventTime,
        lastSyncTime: lastSyncTime,
        errorMessage: errorMessage,
        ttl: ttl,
      );
    }

    final normStatus = RealPowerState.fromString(rawStatus);

    // 1. Стан OFFLINE (триває відключення світла)
    // Коли 220В відсутнє, сенсор/роутер знеструмлений і фізично не може надсилати пінги.
    // Тому статус OFF залишається дійсним, доки триває блекаут (або доки не вийде загальний eventTtl).
    if (normStatus == RealPowerState.offline) {
      final refTime = lastEventTime ?? lastSeen;
      if (eventTtl > Duration.zero &&
          refTime != null &&
          currentTime.difference(refTime) > eventTtl) {
        return PowerMonitorSnapshot.unknown(
          reason: PowerStateReason.staleEvent,
          lastSeen: lastSeen,
          lastEventTime: lastEventTime,
          lastSyncTime: lastSyncTime,
          errorMessage: errorMessage,
          ttl: ttl,
        );
      }
      return PowerMonitorSnapshot(
        status: RealPowerState.offline,
        reason: PowerStateReason.fresh,
        lastSeen: lastSeen,
        lastEventTime: lastEventTime,
        lastSyncTime: lastSyncTime,
        errorMessage: errorMessage,
        ttl: ttl,
      );
    }

    // 2. Якщо користувач вимкнув TTL у налаштуваннях (Duration.zero)
    if (ttl == Duration.zero) {
      return PowerMonitorSnapshot(
        status: normStatus == RealPowerState.unknown
            ? RealPowerState.unknown
            : normStatus,
        reason: normStatus == RealPowerState.unknown
            ? PowerStateReason.noData
            : PowerStateReason.fresh,
        lastSeen: lastSeen,
        lastEventTime: lastEventTime,
        lastSyncTime: lastSyncTime,
        errorMessage: errorMessage,
        ttl: ttl,
      );
    }

    // 3. Пріоритет: перевірка Heartbeat (last_seen), якщо налаштовано
    final hasFresherManualEvent = isLastEventManual &&
        lastEventTime != null &&
        (lastSeen == null || lastEventTime.isAfter(lastSeen));

    if (lastSeen != null && !hasFresherManualEvent) {
      final age = currentTime.difference(lastSeen);
      if (age > ttl) {
        return PowerMonitorSnapshot.unknown(
          reason: PowerStateReason.staleLastSeen,
          lastSeen: lastSeen,
          lastEventTime: lastEventTime,
          lastSyncTime: lastSyncTime,
          errorMessage: errorMessage,
          ttl: ttl,
        );
      }
      return PowerMonitorSnapshot(
        status: normStatus == RealPowerState.unknown
            ? RealPowerState.unknown
            : normStatus,
        reason: normStatus == RealPowerState.unknown
            ? PowerStateReason.noData
            : PowerStateReason.fresh,
        lastSeen: lastSeen,
        lastEventTime: lastEventTime,
        lastSyncTime: lastSyncTime,
        errorMessage: errorMessage,
        ttl: ttl,
      );
    }

    // 4. Фолбек: перевірка часу останньої події, якщо last_seen відсутній
    if (lastEventTime != null) {
      final age = currentTime.difference(lastEventTime);
      final effectiveTtl = normStatus == RealPowerState.online ? ttl : eventTtl;
      if (effectiveTtl > Duration.zero && age > effectiveTtl) {
        return PowerMonitorSnapshot.unknown(
          reason: PowerStateReason.staleEvent,
          lastSeen: lastSeen,
          lastEventTime: lastEventTime,
          lastSyncTime: lastSyncTime,
          errorMessage: errorMessage,
          ttl: ttl,
        );
      }
      return PowerMonitorSnapshot(
        status: normStatus == RealPowerState.unknown
            ? RealPowerState.unknown
            : normStatus,
        reason: normStatus == RealPowerState.unknown
            ? PowerStateReason.noData
            : PowerStateReason.fresh,
        lastSeen: lastSeen,
        lastEventTime: lastEventTime,
        lastSyncTime: lastSyncTime,
        errorMessage: errorMessage,
        ttl: ttl,
      );
    }

    // 5. Жодних даних
    return PowerMonitorSnapshot.unknown(
      reason: PowerStateReason.noData,
      lastSeen: lastSeen,
      lastEventTime: lastEventTime,
      lastSyncTime: lastSyncTime,
      errorMessage: errorMessage,
      ttl: ttl,
    );
  }

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
  bool get isOnline => _snapshot.status == RealPowerState.online;
  bool get isOffline => _snapshot.status == RealPowerState.offline;
  bool get isUnknown => _snapshot.status == RealPowerState.unknown;
  String? get customUrl => _customUrl;
  bool _isLocalApiAvailable = false;
  bool get isLocalApiAvailable => _isLocalApiAvailable;

  /// Whether a data source is configured (either remote database URL or local API).
  bool get isSourceConfigured {
    final hasUrl = _customUrl != null && _customUrl!.trim().isNotEmpty;
    return hasUrl || _isLocalApiAvailable;
  }

  void setLocalApiAvailable(bool available) {
    if (_isLocalApiAvailable != available) {
      _isLocalApiAvailable = available;
      _applySnapshotUpdate();
    }
  }

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

    final rawTtlMinutes = prefs?.getInt('power_monitor_ttl_minutes') ?? 25;
    final ttlMinutes = allowedTtlMinutes.contains(rawTtlMinutes)
        ? rawTtlMinutes
        : defaultHeartbeatTtl.inMinutes;
    _heartbeatTtl = Duration(minutes: ttlMinutes);

    // Відновлюємо закешований last_seen, щоб уникнути спалаху "unknown" при холодному старті
    final cachedLastSeenStr = prefs?.getString('power_monitor_last_seen');
    if (cachedLastSeenStr != null) {
      _lastSeen = DateTime.tryParse(cachedLastSeenStr);
    }

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
      _rawLastStatus = 'unknown';
      _lastSeen = null;
      _lastEventTime = null;
      _snapshot =
          PowerMonitorSnapshot.unknown(reason: PowerStateReason.disabled);
      _currentStatus = 'unknown';
      _notifyStatusChanged(_currentStatus);
      PreferencesHelper.getSafeInstance().then((prefs) {
        prefs.remove('power_monitor_last_seen');
      }).catchError((_) {});
    }
  }

  /// Запуск polling з підтримкою динамічного інтервалу та таймера застарівання.
  void startPolling({Duration? initialDelay}) {
    stopPolling();
    _startStalenessTimer();
    _scheduleNextPoll(initialDelay ?? _currentPollDelay);
  }

  void _startStalenessTimer() {
    _stalenessTimer?.cancel();
    _stalenessTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _checkStaleness();
    });
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
    _stalenessTimer?.cancel();
    _stalenessTimer = null;
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
      }
      _lastSuccessfulSync = DateTime.now();
      _updateCurrentStatus(events);

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
        } else {
          _applySnapshotUpdate();
        }
      } catch (_) {
        _applySnapshotUpdate();
      }

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

  // 1. ИСПРАВЛЕННЫЙ МЕТОД ЗАГРУЗКИ (Сортировка по времени, а не ключу + Heartbeat last_seen)
  Future<List<PowerEvent>> _fetchFromFirebase() async {
    if (_customUrl == null || _customUrl!.trim().isEmpty) return [];

    var baseUrl = _customUrl!.trim();
    if (baseUrl.endsWith('/')) {
      baseUrl = baseUrl.substring(0, baseUrl.length - 1);
    }

    final url = '$baseUrl/events.json?orderBy="\$key"&limitToLast=200';
    final lastSeenUrl = '$baseUrl/last_seen.json';

    final responses = await Future.wait([
      http.get(Uri.parse(url)).timeout(const Duration(seconds: 15)),
      http
          .get(Uri.parse(lastSeenUrl))
          .timeout(const Duration(seconds: 10))
          .catchError((e) {
        AppLogger.w('PowerMonitor: Не вдалося завантажити last_seen: $e',
            tag: 'PowerMonitor');
        return http.Response('network_error', 504);
      }),
    ]);

    final response = responses[0];
    final lastSeenResponse = responses[1];

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }

    final contentType = response.headers['content-type'] ?? '';
    if (!contentType.contains('application/json')) {
      throw FormatException(
          'Invalid Content-Type. Expected JSON but got: $contentType');
    }

    // Попередження про права доступу до last_seen
    if (lastSeenResponse.statusCode == 401 ||
        lastSeenResponse.statusCode == 403) {
      AppLogger.w(
        'PowerMonitor: Доступ до /last_seen.json заборонено (HTTP ${lastSeenResponse.statusCode}). '
        'Перевірте правила доступу у Firebase Console.',
        tag: 'PowerMonitor',
      );
    }

    // Обробка Heartbeat / last_seen
    if (lastSeenResponse.statusCode == 200) {
      final lastSeenBody = lastSeenResponse.body.trim();
      if (lastSeenBody == 'null' || lastSeenBody.isEmpty) {
        // Firebase підтвердив, що нода /last_seen відсутня в БД.
        // Скидаємо збережений час, щоб уникнути помилкового статусу UNKNOWN
        if (_lastSeen != null) {
          _lastSeen = null;
          PreferencesHelper.getSafeInstance().then((prefs) {
            prefs.remove('power_monitor_last_seen');
          }).catchError((_) {});
        }
      } else {
        try {
          final decoded = jsonDecode(lastSeenBody);
          final dt = parseLastSeen(decoded);
          if (dt != null) {
            if (_lastSeen != dt) {
              _lastSeen = dt;
              PreferencesHelper.getSafeInstance().then((prefs) {
                prefs.setString(
                    'power_monitor_last_seen', dt.toIso8601String());
              }).catchError((_) {});
            }
          }
        } catch (e) {
          AppLogger.w('Error parsing last_seen: $e', tag: 'PowerMonitor');
        }
      }
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
      await prefs.remove('power_monitor_last_seen');
      _customUrl = baseUrl;
      _lastSeen = null;
      _rawLastStatus = 'unknown';
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

  void _updateCurrentStatus(List<PowerEvent> events) {
    if (events.isNotEmpty) {
      // Events are sorted by timestamp ASC, so last is the latest
      final latest = events.last;
      _rawLastStatus = latest.status;
      _lastEventTime = latest.timestamp;
      _isLastEventManual = latest.isManual;
    } else {
      _rawLastStatus = 'unknown';
      _lastEventTime = null;
      _isLastEventManual = false;
    }

    _applySnapshotUpdate();
  }

  void _applySnapshotUpdate() {
    final oldStatus = _currentStatus;
    final oldSnapshot = _snapshot;

    _snapshot = evaluatePowerState(
      isEnabled: _isEnabled,
      customUrl: _customUrl,
      consecutiveErrors: _consecutiveErrors,
      lastSeen: _lastSeen,
      lastEventTime: _lastEventTime,
      lastSyncTime: _lastSuccessfulSync,
      errorMessage: _lastSyncError,
      rawStatus: _rawLastStatus,
      ttl: _heartbeatTtl,
      eventTtl: _eventTtl,
      isLastEventManual: _isLastEventManual,
      isLocalApiAvailable: _isLocalApiAvailable,
    );

    _currentStatus = _snapshot.status.toSerializedString();

    if (_snapshot != oldSnapshot) {
      AppLogger.d(
          'Status updated to: $_currentStatus (reason: ${_snapshot.reason})',
          tag: 'PowerMonitor');
    }

    // Сповіщаємо слухачів (HomeNotifier / Riverpod) ВИКЛЮЧНО коли статус змінився!
    if (_currentStatus != oldStatus) {
      _notifyStatusChanged(_currentStatus);
    }
  }

  void _checkStaleness() {
    if (!_isEnabled) return;
    _applySnapshotUpdate();
  }

  /// Налаштування тривалості TTL для застарівання (0 = без таймауту)
  Future<void> setTtlMinutes(int minutes) async {
    final safeMinutes = allowedTtlMinutes.contains(minutes)
        ? minutes
        : defaultHeartbeatTtl.inMinutes;
    _heartbeatTtl = Duration(minutes: safeMinutes);
    try {
      final prefs = await PreferencesHelper.getSafeInstance();
      await prefs.setInt('power_monitor_ttl_minutes', safeMinutes);
    } catch (e) {
      AppLogger.e('Error saving power_monitor_ttl_minutes',
          tag: 'PowerMonitor', error: e);
    }
    _checkStaleness();
  }

  /// Отримати всі події з локальної БД (відсортовані за timestamp).
  Future<List<PowerEvent>> getLocalEvents() async {
    final db = await HistoryService().database;
    final maps = await db.query(
      'power_events',
      orderBy: "timestamp ASC",
    );
    return maps.map((m) => PowerEvent.fromMap(m)).toList();
  }

  /// Отримати події для конкретної дати з локальної БД.
  Future<List<PowerEvent>> getEventsForDate(DateTime date) async {
    final db = await HistoryService().database;
    final dateStr =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final nextDay = DateTime(date.year, date.month, date.day + 1);
    final nextDayStr =
        '${nextDay.year}-${nextDay.month.toString().padLeft(2, '0')}-${nextDay.day.toString().padLeft(2, '0')}';

    final maps = await db.query(
      'power_events',
      where: "timestamp >= ? AND timestamp < ?",
      whereArgs: ['${dateStr}T00:00:00', '${nextDayStr}T00:00:00'],
      orderBy: "timestamp ASC",
    );
    return maps.map((m) => PowerEvent.fromMap(m)).toList();
  }

  Future<List<PowerOutageInterval>> getOutageIntervalsForDate(DateTime date,
      {List<PowerEvent>? preloadedEvents}) async {
    // 1. Визначаємо межі дня (DST safe)
    final dayStart = DateTime(date.year, date.month, date.day);
    final dayEnd = DateTime(date.year, date.month, date.day + 1);

    // 2. Отримуємо події (відсортовані за часом)
    final allEvents = preloadedEvents ?? await getLocalEvents();

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

  /// Checks whether power monitor tracking data covers the given date:
  /// either events occurred on that date, or monitoring was active before and continues through it.
  Future<bool> hasCoverageForDate(DateTime date,
      {List<PowerEvent>? preloadedEvents}) async {
    try {
      final now = DateTime.now();
      final dayStart = DateTime(date.year, date.month, date.day);
      final todayStart = DateTime(now.year, now.month, now.day);
      if (dayStart.isAfter(todayStart)) return false;

      final allEvents = preloadedEvents ?? await getLocalEvents();
      if (allEvents.isEmpty) return false;

      final dayEnd = DateTime(date.year, date.month, date.day + 1);

      final hasEventOnDay = allEvents.any((e) =>
          !e.timestamp.isBefore(dayStart) && e.timestamp.isBefore(dayEnd));
      if (hasEventOnDay) return true;

      final hasEventBefore =
          allEvents.any((e) => e.timestamp.isBefore(dayStart));
      if (!hasEventBefore) return false;

      final hasEventAfter = allEvents.any((e) => !e.timestamp.isBefore(dayEnd));
      if (hasEventAfter) return true;

      final isRecent = now.difference(dayStart).inDays <= 30;
      final isCurrentlyActive = isSourceConfigured &&
          (isOnline || _lastSeen != null || _lastSuccessfulSync != null);

      if (isRecent && isCurrentlyActive) {
        final lastEventBefore =
            allEvents.where((e) => e.timestamp.isBefore(dayStart)).lastOrNull;
        if (lastEventBefore != null && lastEventBefore.isOnline) {
          return true;
        }
      }

      return false;
    } catch (e) {
      AppLogger.w('Error checking coverage for date: $e', tag: 'PowerMonitor');
      return false;
    }
  }

  Future<void> deleteEvent(int id) async {
    final db = await HistoryService().database;
    await db.delete('power_events', where: 'id = ?', whereArgs: [id]);
    final events = await getLocalEvents();
    _updateCurrentStatus(events);
    _applySnapshotUpdate();
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
    final timeStr = newTime.toIso8601String();

    // Set is_manual = 1 to protect from future sync overwrites
    await db.update('power_events', {'timestamp': timeStr, 'is_manual': 1},
        where: 'id = ?', whereArgs: [id]);
    final events = await getLocalEvents();
    _updateCurrentStatus(events);
  }

  Future<void> deleteEventByTimestamp(DateTime timestamp) async {
    final db = await HistoryService().database;
    final isoPrefix =
        timestamp.toIso8601String().substring(0, 19); // YYYY-MM-DDTHH:mm:ss
    final spacePrefix = isoPrefix.replaceFirst('T', ' ');

    // Delete by timestamp matching both standard ISO-8601 and legacy space format
    await db.delete(
      'power_events',
      where: 'timestamp LIKE ? OR timestamp LIKE ?',
      whereArgs: ['$isoPrefix%', '$spacePrefix%'],
    );
    final events = await getLocalEvents();
    _updateCurrentStatus(events);
  }

  /// Атомарне додавання ручної події та негайне оновлення статусу моніторингу
  Future<int> insertManualEvent(PowerEvent event) async {
    final db = await HistoryService().database;
    final id = await db.insert(
      'power_events',
      event.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    if (!_isEnabled) {
      await setEnabled(true);
    }
    _consecutiveErrors = 0;
    _lastSyncError = null;
    final events = await getLocalEvents();
    _updateCurrentStatus(events);
    return id;
  }

  /// Отримати події за період з пагінацією та контролем сортування
  Future<List<PowerEvent>> getEventsRange({
    DateTime? startDate,
    DateTime? endDate,
    int limit = 100,
    bool descending = true,
  }) async {
    final db = await HistoryService().database;
    String? where;
    List<dynamic>? whereArgs;

    String formatIsoTime(DateTime dt) =>
        '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}T'
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';

    if (startDate != null && endDate != null) {
      final startStr = formatIsoTime(startDate);
      // If endDate represents full day boundary (23:59:59), use strict next day boundary to capture all fractional seconds
      if (endDate.hour == 23 && endDate.minute == 59 && endDate.second >= 59) {
        final endNextDay = DateTime(endDate.year, endDate.month, endDate.day)
            .add(const Duration(days: 1));
        final endNextDayStr =
            '${endNextDay.year}-${endNextDay.month.toString().padLeft(2, '0')}-${endNextDay.day.toString().padLeft(2, '0')}T00:00:00';
        where = "timestamp >= ? AND timestamp < ?";
        whereArgs = [startStr, endNextDayStr];
      } else {
        final endStr = formatIsoTime(endDate);
        where = "timestamp >= ? AND timestamp <= ?";
        whereArgs = [startStr, endStr];
      }
    } else if (startDate != null) {
      final startStr = formatIsoTime(startDate);
      where = "timestamp >= ?";
      whereArgs = [startStr];
    } else if (endDate != null) {
      if (endDate.hour == 23 && endDate.minute == 59 && endDate.second >= 59) {
        final endNextDay = DateTime(endDate.year, endDate.month, endDate.day)
            .add(const Duration(days: 1));
        final endNextDayStr =
            '${endNextDay.year}-${endNextDay.month.toString().padLeft(2, '0')}-${endNextDay.day.toString().padLeft(2, '0')}T00:00:00';
        where = "timestamp < ?";
        whereArgs = [endNextDayStr];
      } else {
        final endStr = formatIsoTime(endDate);
        where = "timestamp <= ?";
        whereArgs = [endStr];
      }
    }

    final safeLimit = limit.clamp(1, 1000);
    final orderBy = descending ? "timestamp DESC" : "timestamp ASC";

    final maps = await db.query(
      'power_events',
      where: where,
      whereArgs: whereArgs,
      orderBy: orderBy,
      limit: safeLimit,
    );
    return maps.map((m) => PowerEvent.fromMap(m)).toList();
  }

  /// Перезавантажити статус сенсора виключно з локальної БД (без запитів до мережі)
  Future<void> reloadStatusFromLocal() async {
    final events = await getLocalEvents();
    _updateCurrentStatus(events);
    _applySnapshotUpdate();
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
    final dayEnd = DateTime(date.year, date.month, date.day + 1);
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
