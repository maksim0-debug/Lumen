import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpDate;

import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/app_update_info.dart';
import 'app_info_service.dart';
import 'app_logger.dart';
import 'preferences_helper.dart';

/// Fetches public release metadata without downloading installers.
class AppUpdateService {
  static const defaultRepoOwner = 'maksim0-debug';
  static const defaultRepoName = 'Lumen';
  static const prefLastCheckMs = 'app_update_last_check_ms';
  static const prefCachedReleaseJson = 'app_update_cached_release_json';
  static const prefIgnoredVersion = 'app_update_ignored_version';
  static const prefNextAttemptMs = 'app_update_next_attempt_ms';
  static const prefRateLimitUntilMs = 'app_update_rate_limit_until_ms';
  static const prefFailureCount = 'app_update_failure_count';
  static const checkInterval = Duration(hours: 24);
  static const retryInterval = Duration(minutes: 5);
  static const maxRetryInterval = Duration(hours: 1);
  static const rateLimitInterval = Duration(hours: 1);
  static const requestTimeout = Duration(seconds: 10);
  static const maxResponseBytes = 256 * 1024;
  static const defaultApiHeaders = {
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2026-03-10',
    'User-Agent': 'Lumen-App-Updater',
  };

  final String repoOwner;
  final String repoName;
  final http.Client _httpClient;
  final SharedPreferences? _prefsOverride;
  final DateTime Function() _now;
  Future<AppUpdateInfo?>? _networkCheck;
  Completer<void>? _abortRequest;
  DateTime? _nextAttempt;
  DateTime? _rateLimitUntil;
  int _failureCount = 0;
  bool _disposed = false;

  AppUpdateService({
    this.repoOwner = defaultRepoOwner,
    this.repoName = defaultRepoName,
    http.Client? httpClient,
    SharedPreferences? prefs,
    DateTime Function()? now,
  })  : _httpClient = httpClient ?? http.Client(),
        _prefsOverride = prefs,
        _now = now ?? DateTime.now;

  Future<SharedPreferences> _getPrefs() async =>
      _prefsOverride ?? await PreferencesHelper.getSafeInstance();

  /// Validates the entire version before omitting build metadata from precedence.
  static String normalizeVersion(String value) {
    var version = value.trim();
    if (version.startsWith('v') || version.startsWith('V')) {
      version = version.substring(1);
    }
    final parsed = Version.parse(version);
    return Version(parsed.major, parsed.minor, parsed.patch,
            pre: parsed.preRelease.isEmpty ? null : parsed.preRelease.join('.'))
        .toString();
  }

  static bool isVersionGreater(String remoteVersion, String localVersion) {
    try {
      final local = Version.parse(normalizeVersion(localVersion));
      if (local == Version(0, 0, 0)) return false;
      return Version.parse(normalizeVersion(remoteVersion)) > local;
    } on FormatException {
      return false;
    }
  }

  /// Force bypasses cached success and transient backoff, but respects server
  /// rate limits. Concurrent network callers share one request and cache write.
  Future<AppUpdateInfo?> checkForUpdate({bool force = false}) async {
    if (_disposed) return null;
    try {
      final prefs = await _getPrefs();
      final currentVersion = await AppInfoService.getAppVersion();
      if (normalizeVersion(currentVersion) == '0.0.0') {
        throw const FormatException(
            'Installed application version is unavailable');
      }
      if (_disposed) return null;
      final active = _networkCheck;
      if (active != null) return await active;
      final now = _now();
      _rateLimitUntil ??= _readDeadline(prefs, prefRateLimitUntilMs, now);
      _nextAttempt ??= _readDeadline(prefs, prefNextAttemptMs, now);
      if (_rateLimitUntil != null && now.isBefore(_rateLimitUntil!)) {
        return null;
      }
      if (!force) {
        final lastCheck = prefs.getInt(prefLastCheckMs);
        if (lastCheck != null) {
          final age = now.millisecondsSinceEpoch - lastCheck;
          if (age >= 0 && age < checkInterval.inMilliseconds) {
            final cached = _readCache(prefs, currentVersion);
            if (cached != null) return cached;
          }
        }
        if (_nextAttempt != null && now.isBefore(_nextAttempt!)) return null;
      }
      final future = _fetchRelease(prefs, currentVersion);
      _networkCheck = future;
      try {
        return await future;
      } finally {
        if (identical(_networkCheck, future)) _networkCheck = null;
      }
    } catch (error, stack) {
      if (!_disposed) {
        AppLogger.w('Cannot check application updates',
            tag: 'AppUpdateService', error: error, stackTrace: stack);
      }
      return null;
    }
  }

  DateTime? _readDeadline(SharedPreferences prefs, String key, DateTime now) {
    final milliseconds = prefs.getInt(key);
    if (milliseconds == null) return null;
    final deadline = DateTime.fromMillisecondsSinceEpoch(milliseconds);
    final maximum = now.add(checkInterval);
    return deadline.isAfter(maximum) ? maximum : deadline;
  }

  AppUpdateInfo? _readCache(SharedPreferences prefs, String currentVersion) {
    final raw = prefs.getString(prefCachedReleaseJson);
    if (raw == null || utf8.encode(raw).length > maxResponseBytes) return null;
    try {
      final cached =
          AppUpdateInfo.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      if (normalizeVersion(cached.currentVersion) !=
              normalizeVersion(currentVersion) ||
          !_isRepositoryReleaseUrl(cached.releaseUrl)) {
        return null;
      }
      final latest = normalizeVersion(cached.latestVersion);
      return AppUpdateInfo(
        currentVersion: currentVersion,
        latestVersion: latest,
        releaseTitle: cached.releaseTitle,
        releaseNotes: cached.releaseNotes,
        releaseUrl: cached.releaseUrl,
        publishedAt: cached.publishedAt,
        hasUpdate: isVersionGreater(latest, currentVersion),
      );
    } catch (error) {
      AppLogger.w('Ignoring invalid application update cache',
          tag: 'AppUpdateService', error: error);
      return null;
    }
  }

  bool _isRepositoryReleaseUrl(String value) =>
      _releaseUri(value, owner: repoOwner, repository: repoName) != null;

  static Uri? _releaseUri(String value,
      {String owner = defaultRepoOwner, String repository = defaultRepoName}) {
    final uri = Uri.tryParse(value);
    final prefix = '/$owner/$repository/releases/';
    final valid = uri != null &&
        uri.scheme == 'https' &&
        uri.host == 'github.com' &&
        uri.userInfo.isEmpty &&
        (!uri.hasPort || uri.port == 443) &&
        uri.path.startsWith(prefix) &&
        uri.path.length > prefix.length &&
        !uri.pathSegments.any((segment) => segment == '.' || segment == '..');
    return valid ? uri : null;
  }

  Future<AppUpdateInfo?> _fetchRelease(
      SharedPreferences prefs, String currentVersion) async {
    final abort = Completer<void>();
    _abortRequest = abort;
    final timeout = Timer(requestTimeout, () {
      if (!abort.isCompleted) abort.complete();
    });
    try {
      final uri = Uri.https(
          'api.github.com', '/repos/$repoOwner/$repoName/releases/latest');
      final request =
          http.AbortableRequest('GET', uri, abortTrigger: abort.future)
            ..headers.addAll(defaultApiHeaders);
      final response = await _httpClient.send(request).timeout(requestTimeout);
      if (response.statusCode != 200) {
        await response.stream.listen(null).cancel();
        if (_disposed) return null;
        if (response.statusCode == 403 || response.statusCode == 429) {
          _rateLimitUntil = _rateLimitDeadline(response.headers, _now());
          await _persist(() => prefs.setInt(
              prefRateLimitUntilMs, _rateLimitUntil!.millisecondsSinceEpoch));
        }
        await _recordFailure(prefs);
        AppLogger.w(
            'Application update request failed: HTTP ${response.statusCode}',
            tag: 'AppUpdateService');
        return null;
      }
      final bytes = <int>[];
      if ((response.contentLength ?? 0) > maxResponseBytes) {
        await response.stream.listen(null).cancel();
        throw const FormatException('Release metadata exceeds size limit');
      }
      await (() async {
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > maxResponseBytes) {
            throw const FormatException('Release metadata exceeds size limit');
          }
          bytes.addAll(chunk);
        }
      })()
          .timeout(requestTimeout);
      if (_disposed) return null;
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (json['draft'] == true || json['prerelease'] == true) {
        throw const FormatException('Expected a published stable release');
      }
      final latest = normalizeVersion(json['tag_name'] as String);
      if (Version.parse(latest).isPreRelease) {
        throw const FormatException('Expected a stable release version');
      }
      final releaseUrl = json['html_url'] as String? ??
          'https://github.com/$repoOwner/$repoName/releases/latest';
      if (!_isRepositoryReleaseUrl(releaseUrl)) {
        throw const FormatException('Unexpected repository release URL');
      }
      final info = AppUpdateInfo(
        currentVersion: currentVersion,
        latestVersion: latest,
        releaseTitle: json['name'] as String? ?? json['tag_name'] as String,
        releaseNotes: json['body'] as String? ?? '',
        releaseUrl: releaseUrl,
        publishedAt: json['published_at'] == null
            ? null
            : DateTime.parse(json['published_at'] as String),
        hasUpdate: isVersionGreater(latest, currentVersion),
      );
      _nextAttempt = null;
      _rateLimitUntil = null;
      _failureCount = 0;
      // Store content before its freshness marker. Cache errors must not hide
      // a successfully fetched release from the caller.
      if (await _persist(() =>
          prefs.setString(prefCachedReleaseJson, jsonEncode(info.toJson())))) {
        await _persist(
            () => prefs.setInt(prefLastCheckMs, _now().millisecondsSinceEpoch));
      }
      await _persist(() => prefs.remove(prefNextAttemptMs));
      await _persist(() => prefs.remove(prefRateLimitUntilMs));
      await _persist(() => prefs.remove(prefFailureCount));
      return _disposed ? null : info;
    } catch (error, stack) {
      if (!_disposed) {
        await _recordFailure(prefs);
        AppLogger.w('Cannot fetch application release metadata',
            tag: 'AppUpdateService', error: error, stackTrace: stack);
      }
      return null;
    } finally {
      timeout.cancel();
      if (!abort.isCompleted) abort.complete();
      if (identical(_abortRequest, abort)) _abortRequest = null;
    }
  }

  DateTime _rateLimitDeadline(Map<String, String> headers, DateTime now) {
    var deadline = now.add(rateLimitInterval);
    final retryAfter = headers['retry-after'];
    final seconds = int.tryParse(retryAfter ?? '');
    final reset = int.tryParse(headers['x-ratelimit-reset'] ?? '');
    if (seconds != null && seconds > 0) {
      deadline = now.add(Duration(seconds: seconds));
    } else if (retryAfter != null) {
      try {
        deadline = HttpDate.parse(retryAfter);
      } on FormatException {
        // Retain the conservative default for invalid server metadata.
      }
    } else if (reset != null) {
      deadline = DateTime.fromMillisecondsSinceEpoch(reset * 1000);
    }
    if (!deadline.isAfter(now)) return now.add(retryInterval);
    final maximum = now.add(checkInterval);
    return deadline.isAfter(maximum) ? maximum : deadline;
  }

  Future<void> _recordFailure(SharedPreferences prefs) async {
    final previous = _failureCount == 0
        ? prefs.getInt(prefFailureCount) ?? 0
        : _failureCount;
    _failureCount = previous.clamp(0, 4) + 1;
    final milliseconds = (retryInterval.inMilliseconds << (_failureCount - 1))
        .clamp(retryInterval.inMilliseconds, maxRetryInterval.inMilliseconds);
    _nextAttempt = _now().add(Duration(milliseconds: milliseconds));
    await _persist(() => prefs.setInt(prefFailureCount, _failureCount));
    await _persist(() =>
        prefs.setInt(prefNextAttemptMs, _nextAttempt!.millisecondsSinceEpoch));
  }

  Future<bool> _persist(Future<bool> Function() write) async {
    if (_disposed) return false;
    try {
      if (!await write()) throw StateError('Preference write was rejected');
      return true;
    } catch (error, stack) {
      AppLogger.w('Cannot persist application update state',
          tag: 'AppUpdateService', error: error, stackTrace: stack);
      return false;
    }
  }

  Future<void> ignoreVersion(String version) async {
    final prefs = await _getPrefs();
    try {
      if (!await prefs.setString(
          prefIgnoredVersion, normalizeVersion(version))) {
        throw StateError('Cannot persist ignored application version');
      }
    } catch (_) {
      // SharedPreferences mutates its memory cache before the platform write.
      try {
        await prefs.reload();
      } catch (error) {
        AppLogger.w('Cannot reload ignored version after a failed write',
            tag: 'AppUpdateService', error: error);
      }
      rethrow;
    }
  }

  Future<bool> isVersionIgnored(String version) async {
    final prefs = await _getPrefs();
    final ignored = prefs.getString(prefIgnoredVersion);
    if (ignored == null) return false;
    try {
      return normalizeVersion(ignored) == normalizeVersion(version);
    } on FormatException {
      return false;
    }
  }

  static Future<bool> openReleaseUrl(String url) async {
    final uri = _releaseUri(url.trim());
    if (uri == null) return false;
    try {
      // Query permissions can report false even when opening a browser works.
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (error) {
      AppLogger.w('Cannot open application release page',
          tag: 'AppUpdateService', error: error);
      return false;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final abort = _abortRequest;
    if (abort != null && !abort.isCompleted) abort.complete();
    _httpClient.close();
  }
}
