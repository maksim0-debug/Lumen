import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'app_logger.dart';

/// Service providing application metadata and version details from pubspec.yaml.
class AppInfoService {
  AppInfoService._();

  static PackageInfo? _cachedPackageInfo;
  static Future<PackageInfo>? _initFuture;

  /// Retrieves [PackageInfo] asynchronously with in-memory caching and fallback safety.
  static Future<PackageInfo> getPackageInfo() async {
    if (_cachedPackageInfo != null) {
      return _cachedPackageInfo!;
    }

    if (_initFuture != null) {
      return _initFuture!;
    }

    _initFuture = _fetchPackageInfo();
    return _initFuture!;
  }

  static Future<PackageInfo> _fetchPackageInfo() async {
    try {
      _cachedPackageInfo = await PackageInfo.fromPlatform().timeout(
        const Duration(seconds: 3),
      );
      return _cachedPackageInfo!;
    } catch (e, stack) {
      AppLogger.w(
        "Failed to retrieve PackageInfo from platform, falling back to defaults: $e",
        tag: 'AppInfoService',
        error: e,
        stackTrace: stack,
      );
      _cachedPackageInfo = PackageInfo(
        appName: 'Lumen',
        packageName: 'lumen',
        version: '0.0.0',
        buildNumber: '',
        buildSignature: '',
      );
      return _cachedPackageInfo!;
    } finally {
      _initFuture = null;
    }
  }

  /// Returns the formatted application version string (e.g. "2.92.18+19" or "2.92.18").
  static Future<String> getAppVersion() async {
    final info = await getPackageInfo();
    final ver = info.version;
    final build = info.buildNumber;

    if (ver.isEmpty || ver == '0.0.0') {
      return build.isNotEmpty ? build : 'Unknown';
    }

    if (build.isNotEmpty && !ver.contains('+')) {
      return '$ver+$build';
    }

    return ver;
  }

  /// Injects or clears mock [PackageInfo] for automated tests.
  @visibleForTesting
  static void setMockPackageInfo(PackageInfo? info) {
    _cachedPackageInfo = info;
    _initFuture = null;
  }
}
