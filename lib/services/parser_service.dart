import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'parser_transport_policy.dart';
import '../models/emergency_status.dart';
import 'emergency_status_parser.dart';
import 'emergency_status_service.dart';
import 'dtek_snapshot.dart';
import '../models/schedule_status.dart';
import 'app_logger.dart';
import 'history_service.dart';
import 'android_fetch_diagnostics.dart';
import 'android_fetch_coordinator.dart';
import 'package:lumen_android_diagnostics/lumen_android_diagnostics.dart';

part 'parser_transport.dart';

class ParserFetchResult {
  final Map<String, FullSchedule> schedules;
  final String? html;
  final EmergencyObservation? emergency;
  bool? get isEmergency => emergency?.active;
  const ParserFetchResult(this.schedules, this.html, {this.emergency});

  /// Preserve a status-only response when a schedule fallback succeeds.
  ParserFetchResult retainEmergencyFrom(ParserFetchResult? earlier) {
    final observation = earlier?.emergency;
    if (observation == null ||
        (emergency != null &&
            emergency!.observedAt >= observation.observedAt)) {
      return this;
    }
    // Both payloads are canonical exports. Replace their metadata rather than
    // attaching two contradictory observations after a cached HTTP retry.
    final payload = (html ?? '').replaceAll(
        RegExp(
            r'<script id="lumen-emergency" type="application/json">.*?</script>',
            dotAll: true),
        '');
    return ParserFetchResult(
        schedules,
        '$payload<script id="lumen-emergency" type="application/json">'
        '${jsonEncode(observation.toTransport()).replaceAll('<', r'\u003c')}</script>',
        emergency: observation);
  }
}

class ParserService {
  static final ParserService _instance = ParserService._internal();

  factory ParserService() => _instance;

  static final ParserService _backgroundInstance =
      ParserService._internal(policy: ParserFetchPolicy.background);

  factory ParserService.background() => _backgroundInstance;

  ParserService._internal(
      {ParserFetchPolicy policy = const ParserFetchPolicy()})
      : _policy = policy,
        _target = Uri.parse(_url),
        _windows = Platform.isWindows,
        _httpClientFactory = HttpClient.new,
        _environmentFactory = null,
        _coordinator = Platform.isAndroid
            ? AndroidFetchCoordinator(() => HistoryService().database)
            : null,
        _networkAvailable =
            Platform.isAndroid ? _androidNetworkAvailable : null;

  @visibleForTesting
  ParserService.forTesting({
    Uri? target,
    ParserFetchPolicy policy = const ParserFetchPolicy(),
    bool windows = false,
    HttpClient Function()? httpClientFactory,
    Future<WebViewEnvironment?> Function()? environmentFactory,
    AndroidFetchCoordinator? coordinator,
    Future<bool?> Function()? networkAvailable,
  })  : _policy = policy,
        _target = target ?? Uri.parse(_url),
        _windows = windows,
        _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _environmentFactory = environmentFactory,
        _coordinator = coordinator,
        _networkAvailable = networkAvailable;

  final AndroidFetchCoordinator? _coordinator;
  final Future<bool?> Function()? _networkAvailable;
  final ParserFetchPolicy _policy;
  final Uri _target;
  final bool _windows;
  final HttpClient Function() _httpClientFactory;
  final Future<WebViewEnvironment?> Function()? _environmentFactory;
  final _cookies = ParserCookieJar();
  Future<WebViewEnvironment?>? _environment;
  String? _httpUserAgent;
  DateTime? _retryNotBefore;

  static const String _url = "https://www.dtek-krem.com.ua/ua/shutdowns";

  // Preserve the pre-refactor HTTP identity before a native browser session is
  // available. A captured navigator.userAgent takes precedence for that session.
  static const String _fallbackHttpUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  static const List<String> allGroups = [
    "GPV1.1",
    "GPV1.2",
    "GPV2.1",
    "GPV2.2",
    "GPV3.1",
    "GPV3.2",
    "GPV4.1",
    "GPV4.2",
    "GPV5.1",
    "GPV5.2",
    "GPV6.1",
    "GPV6.2",
  ];

  /// Returns the next or previous group in the cycle based on [direction] (+1 next, -1 previous).
  static String cycleGroup(String currentGroup, int direction) {
    if (direction == 0) return currentGroup;
    final currentIndex = allGroups.indexOf(currentGroup);
    final validIndex = currentIndex == -1 ? 0 : currentIndex;
    final newIndex = (validIndex + direction) % allGroups.length;
    final targetIndex = newIndex < 0 ? newIndex + allGroups.length : newIndex;
    return allGroups[targetIndex];
  }

  Future<ParserFetchResult>? _ongoingFetch;
  String? _ongoingDiagnosticId;

  Future<void> init() async {}

  Future<Map<String, FullSchedule>> fetchAllSchedules() async {
    return (await fetchSnapshot()).schedules;
  }

  /// HTML and schedules belong to the same completed fetch, including coalesced callers.
  Future<ParserFetchResult> fetchSnapshot() =>
      AndroidFetchDiagnostics.instance.run(
        source: 'parser_direct',
        execution: identical(_policy, ParserFetchPolicy.background)
            ? 'background_parser'
            : 'main_parser',
        action: _fetchSnapshot,
      );

  Future<ParserFetchResult> _fetchSnapshot() async {
    if (_ongoingFetch != null) {
      AndroidFetchDiagnostics.current?.event('fetch_join', {
        'sharedOperationId': _ongoingDiagnosticId,
      });
      AppLogger.d("⏳ Парсинг вже виконується, очікуємо спільний результат...",
          tag: 'Parser');
      return _ongoingFetch!;
    }

    _ongoingDiagnosticId = AndroidFetchDiagnostics.current?.id;
    final coordinator = _coordinator;
    _ongoingFetch = coordinator == null
        ? _executeFetchAllSchedules()
        : coordinator.run<ParserFetchResult>(
            target: _target.toString(),
            waitTimeout: _policy.totalTimeout,
            leaseDuration: _policy.totalTimeout +
                _policy.controllerTimeout +
                const Duration(seconds: 10),
            fetch: _executeFetchAllSchedules,
            encode: (result) => jsonEncode({
              'html': result.html,
              'emergency': result.emergency?.toTransport()
            }),
            decode: decodeSharedSnapshot,
            observe: (stage, fields) =>
                AndroidFetchDiagnostics.current?.event(stage, fields),
          );
    try {
      return await _ongoingFetch!;
    } finally {
      _ongoingFetch = null;
      _ongoingDiagnosticId = null;
    }
  }

  Future<({ParserFetchResult value, int completedAt})?>
      recentAndroidSnapshot() async => _coordinator?.recent<ParserFetchResult>(
          target: _target.toString(),
          maxAge: const Duration(seconds: 30),
          decode: decodeSharedSnapshot);

  static Future<bool?> _androidNetworkAvailable() async {
    try {
      final state = await AndroidSystemDiagnostics.networkState()
          .timeout(const Duration(milliseconds: 300));
      AndroidFetchDiagnostics.current?.event('network_state', state);
      if (state['networkBlocked'] == true || state['networkPresent'] == false) {
        return false;
      }
      return state['networkPresent'] == true ? true : null;
    } catch (error) {
      AndroidFetchDiagnostics.current?.event('network_state_unavailable',
          AndroidFetchDiagnostics.errorFields(error),
          level: AppLogLevel.warning);
      return null; // Unavailable diagnostics must never block a real request.
    }
  }

  @visibleForTesting
  static ParserFetchResult? decodeSharedSnapshot(String payload) {
    try {
      final data = jsonDecode(payload) as Map;
      final html = data['html'] as String?;
      if (html == null) return const ParserFetchResult({}, null);
      final json = DtekSnapshot.extractJson(html);
      final schedules = json.isEmpty
          ? <String, FullSchedule>{}
          : DtekSnapshot.parse(json, allGroups).schedules;
      final transported = data['emergency'];
      EmergencyObservation? emergency;
      if (transported is Map &&
          transported['schemaVersion'] == 1 &&
          transported['active'] is bool &&
          transported['observedAt'] is int &&
          transported['confirmed'] is bool &&
          transported['isPossible'] is bool &&
          transported['noticeText'] is String) {
        emergency = EmergencyObservation(
            transported['active'], transported['observedAt'],
            confirmed: transported['confirmed'],
            isPossible: transported['isPossible'],
            noticeText: transported['noticeText']);
      }
      return ParserFetchResult(schedules, html,
          emergency:
              emergency?.isValidAt(DateTime.now().millisecondsSinceEpoch) ==
                      true
                  ? emergency
                  : null);
    } catch (error) {
      AppLogger.w('Cannot reuse overlapping snapshot (${error.runtimeType})',
          tag: 'Parser', persistToHistory: false);
      return null;
    }
  }

  static bool isBotChallengeHtml(String html) =>
      ParserProtection.classify(html) != ParserPageProtection.none;

  int _responseObservationTime(HttpClientResponse response, int startedAt) {
    final parsedAge = int.tryParse(response.headers.value('age') ?? '0') ?? 0;
    final age = parsedAge.clamp(0, 3153600000);
    final date = response.headers.date?.millisecondsSinceEpoch;
    return [startedAt - age * 1000, if (date != null) date]
        .reduce((a, b) => a < b ? a : b);
  }

  /// Публічний екстрактор для тестування та внутрішнього використання
  String extractJsonFromHtml(String html) => DtekSnapshot.extractJson(html);

  @visibleForTesting
  static ({
    String json,
    String? html,
    String? url,
    bool fromCache,
    bool htmlUnchanged
  }) decodeRuntimeCapture(dynamic value) {
    dynamic decoded = value;
    for (var i = 0; i < 2 && decoded is String; i++) {
      decoded = jsonDecode(decoded);
    }
    if (decoded is! Map ||
        (decoded['html'] != null && decoded['html'] is! String) ||
        (decoded['url'] != null && decoded['url'] is! String) ||
        (decoded['fromCache'] != null && decoded['fromCache'] is! bool) ||
        (decoded['htmlUnchanged'] != null &&
            decoded['htmlUnchanged'] is! bool)) {
      throw const FormatException('Invalid runtime page capture');
    }
    return (
      json: jsonEncode(decoded['fact']),
      html: decoded['html'] as String?,
      url: decoded['url'] as String?,
      htmlUnchanged: decoded['htmlUnchanged'] == true,
      fromCache: decoded['fromCache'] == true
    );
  }

  static ({bool? isEmergency, String details}) analyzeEmergencyStatus(
      String html) {
    final active = EmergencyStatusParser.parse(html);
    return (
      isEmergency: active,
      details: active == null
          ? 'Operational status could not be verified'
          : active
              ? 'Active emergency notice'
              : 'Emergency notice absent or cancelled'
    );
  }

  static bool extractEmergencyStatus(String html) =>
      EmergencyStatusParser.parse(html) == true;

  @visibleForTesting
  Future<ParserFetchResult> parseFetchedPage(String rawJson,
      {String? originalHtml,
      int? observedAt,
      EmergencyStatusService? emergencyService,
      bool Function()? isCurrent,
      Future<void> Function(DtekSnapshot)? persistSchedules}) async {
    if (isCurrent != null && !isCurrent()) {
      return const ParserFetchResult({}, null);
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final observation = originalHtml == null
        ? null
        : EmergencyStatusParser.parseObservation(
            originalHtml, observedAt ?? now);
    final emergency =
        observation != null && observation.isValidAt(now) ? observation : null;
    if (emergency != null) {
      try {
        await (emergencyService ?? EmergencyStatusService()).observe(emergency);
      } catch (error) {
        AppLogger.w('Cannot persist emergency observation',
            tag: 'Parser', error: error);
      }
    }
    if (isCurrent != null && !isCurrent()) {
      return const ParserFetchResult({}, null);
    }
    DtekSnapshot? snapshot;
    try {
      snapshot = DtekSnapshot.parse(rawJson, allGroups);
    } catch (error) {
      AndroidFetchDiagnostics.current?.event(
          'snapshot_invalid', AndroidFetchDiagnostics.errorFields(error),
          level: AppLogLevel.warning);
      AppLogger.w('No valid schedule in fetched page',
          tag: 'Parser', error: error);
    }
    if (snapshot != null) {
      AndroidFetchDiagnostics.current?.event('snapshot_valid', {
        'groups': snapshot.schedules.length,
        'sourceVersion': snapshot.update,
        'todayDate': snapshot.todayDate,
        'tomorrowDate': snapshot.tomorrowDate,
        'emergencyObserved': emergency != null,
      });
      try {
        if (persistSchedules != null) {
          await persistSchedules(snapshot);
        } else {
          await HistoryService().persistSnapshot(
              schedules: snapshot.schedules,
              todayDate: snapshot.todayDate,
              tomorrowDate: snapshot.tomorrowDate,
              dtekUpdatedAt: snapshot.update);
        }
        AndroidFetchDiagnostics.current?.event('snapshot_persisted', {});
      } on FormatException catch (error) {
        AndroidFetchDiagnostics.current?.event(
            'snapshot_rejected', AndroidFetchDiagnostics.errorFields(error),
            level: AppLogLevel.warning);
        // A source watermark rejection is a data-integrity decision, not a
        // storage outage. Do not publish an older/conflicting graph to the UI.
        snapshot = null;
        AppLogger.w(
            'Rejected schedule snapshot; retaining emergency observation',
            tag: 'Parser',
            error: error);
      } catch (error) {
        AndroidFetchDiagnostics.current?.event('snapshot_storage_error',
            AndroidFetchDiagnostics.errorFields(error),
            level: AppLogLevel.error);
        AppLogger.w('Cannot persist schedule history',
            tag: 'Parser', error: error);
      }
    }
    // Export the validated runtime object, never stale inline script text.
    // Emergency metadata is independent of schedule validity and version.
    final canonical = StringBuffer();
    if (snapshot != null) {
      final fact = jsonEncode(snapshot.fact).replaceAll('<', r'\u003c');
      canonical.write('<script>DisconSchedule.fact = $fact;</script>');
    }
    if (emergency != null) {
      canonical.write('<script id="lumen-emergency" type="application/json">'
          '${jsonEncode(emergency.toTransport()).replaceAll('<', r'\u003c')}</script>');
    }
    return ParserFetchResult(snapshot?.schedules ?? {},
        canonical.isEmpty ? null : canonical.toString(),
        emergency: emergency);
  }
}
