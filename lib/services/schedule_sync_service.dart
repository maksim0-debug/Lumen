import 'dart:async';
import 'dart:io';

import '../models/schedule_status.dart';
import 'app_logger.dart';
import 'android_fetch_diagnostics.dart';
import 'history_service.dart';
import 'parser_service.dart';
import 'schedule_calculation_service.dart';
import 'worker_schedule_service.dart';

enum ScheduleSyncStatus {
  success,
  cooldownActive,
  alreadyFetching,
  error,
}

class ScheduleSyncResult {
  final ScheduleSyncStatus status;
  final Map<String, FullSchedule>? schedules;
  final Object? error;

  const ScheduleSyncResult.success(this.schedules)
      : status = ScheduleSyncStatus.success,
        error = null;

  const ScheduleSyncResult.cooldownActive()
      : status = ScheduleSyncStatus.cooldownActive,
        schedules = null,
        error = null;

  const ScheduleSyncResult.alreadyFetching()
      : status = ScheduleSyncStatus.alreadyFetching,
        schedules = null,
        error = null;

  const ScheduleSyncResult.failure(this.error)
      : status = ScheduleSyncStatus.error,
        schedules = null;

  bool get isSuccess => status == ScheduleSyncStatus.success;
  bool get isCooldownActive => status == ScheduleSyncStatus.cooldownActive;
  bool get isAlreadyFetching => status == ScheduleSyncStatus.alreadyFetching;
  bool get isError => status == ScheduleSyncStatus.error;
}

/// Сервіс синхронізації розкладів, керування мережевими викликами та кулдаунами.
class ScheduleSyncService {
  final ParserService _parser;
  final HistoryService _historyService;
  final Duration cooldown;

  static final StreamController<Map<String, FullSchedule>> _syncBroadcast =
      StreamController<Map<String, FullSchedule>>.broadcast();

  /// Stream of all newly synced schedules for real-time subscribers (SSE, background workers, UI).
  static Stream<Map<String, FullSchedule>> get onSyncCompleted =>
      _syncBroadcast.stream;

  static Map<String, FullSchedule>? _lastPublished;

  static void _publish(Map<String, FullSchedule> schedules) {
    // Coalesced parser callers receive the same map. Publish that fetch exactly once.
    if (identical(_lastPublished, schedules)) return;
    _lastPublished = schedules;
    _syncBroadcast.add(schedules);
  }

  bool _isFetching = false;
  DateTime? lastFetchTime;

  static const Duration defaultCooldown = Duration(seconds: 30);

  ScheduleSyncService({
    ParserService? parser,
    HistoryService? historyService,
    this.cooldown = defaultCooldown,
  })  : _parser = parser ?? ParserService(),
        _historyService = historyService ?? HistoryService();

  bool get isFetching => _isFetching;
  Duration get fetchCooldown => cooldown;
  ParserService get parser => _parser;
  HistoryService get historyService => _historyService;

  /// Перевірка чи активний кулдаун (30 сек) і чи потрібно пропустити оновлення.
  bool isCooldownActive({bool force = false, bool hasExistingData = true}) {
    if (force || !hasExistingData || lastFetchTime == null) {
      return false;
    }
    return DateTime.now().difference(lastFetchTime!) < cooldown;
  }

  /// Завантаження останніх відомих даних із локальної бази даних (кешу).
  Future<Map<String, FullSchedule>> loadCachedData() async {
    try {
      final cached = await _historyService.getLastKnownSchedules();
      AndroidFetchDiagnostics.current
          ?.event('cache_loaded', {'groups': cached.length});
      return cached;
    } catch (e) {
      AndroidFetchDiagnostics.current?.event(
          'cache_load_error', AndroidFetchDiagnostics.errorFields(e),
          level: AppLogLevel.warning);
      AppLogger.e("Error loading cached data", tag: 'Main', error: e);
      return {};
    }
  }

  /// Завантаження свіжих даних з мережі через ParserService.
  Future<Map<String, FullSchedule>> fetchAllSchedules() async {
    final allData = await _fetchSchedules();
    if (allData.isEmpty) throw Exception("Пустий список");
    lastFetchTime = DateTime.now();
    return allData;
  }

  Future<Map<String, FullSchedule>> _fetchSchedules() async {
    if (Platform.isAndroid) {
      try {
        return await WorkerScheduleService().fetch();
      } catch (error) {
        AppLogger.w('Worker schedules unavailable; using DTEK parser',
            tag: 'ScheduleSync', error: error.runtimeType);
      }
    }
    return _parser.fetchAllSchedules();
  }

  Future<ParserFetchResult> fetchSnapshotAndPublish() async {
    final result = await _parser.fetchSnapshot();
    if (result.schedules.isEmpty) {
      if (result.emergency != null) return result;
      throw StateError('No schedules received');
    }
    lastFetchTime = DateTime.now();
    _publish(result.schedules);
    return result;
  }

  /// Розрахунок статистики відключень для кожної групи перед оновленням.
  Map<String, int> computeOldStats(Map<String, FullSchedule> schedules) {
    final Map<String, int> stats = {};
    if (schedules.isNotEmpty) {
      for (var entry in schedules.entries) {
        final group = entry.key;
        final schedule = entry.value;
        stats["${group}_today"] =
            ScheduleCalculationService.calculateOutageMinutes(schedule.today);
        stats["${group}_tomorrow"] =
            ScheduleCalculationService.calculateOutageMinutes(
                schedule.tomorrow);
      }
    }
    return stats;
  }

  /// Виконання виклику синхронізації з перевіркою кулдаунів та блокуванням паралельних запитів.
  Future<ScheduleSyncResult> syncSchedules({
    bool force = false,
    bool hasExistingData = false,
  }) async {
    if (_isFetching) {
      AppLogger.d("⏳ Fetch already in progress, skipping duplicate request",
          tag: 'Main');
      return const ScheduleSyncResult.alreadyFetching();
    }

    if (!force &&
        hasExistingData &&
        lastFetchTime != null &&
        DateTime.now().difference(lastFetchTime!) < cooldown) {
      AppLogger.d("⏳ Data is fresh (cooldown active), skipping fetch",
          tag: 'Main');
      return const ScheduleSyncResult.cooldownActive();
    }

    _isFetching = true;

    try {
      final allData = await _fetchSchedules();
      if (allData.isEmpty) throw Exception("Пустий список");

      lastFetchTime = DateTime.now();
      _publish(allData);
      return ScheduleSyncResult.success(allData);
    } catch (e) {
      AppLogger.e("Error loading data", tag: 'Main', error: e);
      return ScheduleSyncResult.failure(e);
    } finally {
      _isFetching = false;
    }
  }

  /// Повний оркестратор процесу завантаження, синхронізації та делегування життєвого циклу.
  Future<void> sync({
    bool silent = false,
    bool force = false,
    required bool hasExistingData,
    required bool isHistoryMode,
    required Future<void> Function() onCooldownSkipped,
    required Future<bool> Function() onEnsureCache,
    required void Function() onFetchStart,
    required void Function() onBeforeFetch,
    required Future<void> Function(Map<String, FullSchedule> allData)
        onFetchSuccess,
    required void Function(Object error) onFetchError,
  }) async {
    if (_isFetching) {
      AndroidFetchDiagnostics.current
          ?.event('sync_skipped', {'reason': 'already_fetching'});
      AppLogger.d("⏳ Fetch already in progress, skipping duplicate request",
          tag: 'Main');
      return;
    }

    if (!force &&
        hasExistingData &&
        lastFetchTime != null &&
        DateTime.now().difference(lastFetchTime!) < cooldown) {
      AppLogger.d("⏳ Data is fresh (cooldown active), skipping fetch",
          tag: 'Main');
      AndroidFetchDiagnostics.current?.event('sync_skipped', {
        'reason': 'cooldown',
        'lastFetchAt': lastFetchTime?.toUtc().toIso8601String(),
      });
      if (!silent && !isHistoryMode) {
        await onCooldownSkipped();
      }
      return;
    }

    _isFetching = true;

    try {
      if (!silent) {
        final proceed = await onEnsureCache();
        if (!proceed) return;

        if (!isHistoryMode) {
          onFetchStart();
        }
      }

      onBeforeFetch();

      final allData = await _fetchSchedules();
      if (allData.isEmpty) {
        AndroidFetchDiagnostics.current
            ?.event('sync_empty_schedule', {}, level: AppLogLevel.warning);
        await _historyService.logAction(
            "Парсер: Помилка — список графіків порожній (не вдалося завантажити)",
            level: "ERROR");
        throw Exception("Пустий список");
      }

      lastFetchTime = DateTime.now();
      _publish(allData);

      await onFetchSuccess(allData);
      AndroidFetchDiagnostics.current
          ?.event('sync_applied', {'groups': allData.length});
      await _historyService.logAction(
          "Парсер: Синхронізація успішна — застосовано графіки для ${allData.length} груп");
    } catch (e) {
      AndroidFetchDiagnostics.current?.event(
          'sync_error',
          {
            'isHistoryMode': isHistoryMode,
            ...AndroidFetchDiagnostics.errorFields(e),
          },
          level: AppLogLevel.error);
      if (!isHistoryMode) {
        onFetchError(e);
      }
      AppLogger.e("Error loading data", tag: 'Main', error: e);
    } finally {
      _isFetching = false;
    }
  }
}
