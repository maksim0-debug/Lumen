import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/app_update_info.dart';
import '../../services/app_logger.dart';
import '../../services/app_update_service.dart';

enum AppUpdateStatus { idle, checking, available, upToDate, error }

@immutable
class AppUpdateState {
  static const _unchanged = Object();

  final AppUpdateStatus status;
  final AppUpdateInfo? updateInfo;
  final bool isBadgeDismissed;
  final bool isIgnored;
  final String? errorMessage;
  final DateTime? lastCheckedAt;

  const AppUpdateState({
    this.status = AppUpdateStatus.idle,
    this.updateInfo,
    this.isBadgeDismissed = false,
    this.isIgnored = false,
    this.errorMessage,
    this.lastCheckedAt,
  });

  // A failed refresh does not invalidate a previously discovered release.
  bool get shouldShowBadge =>
      updateInfo?.hasUpdate == true && !isBadgeDismissed && !isIgnored;

  AppUpdateState copyWith({
    AppUpdateStatus? status,
    Object? updateInfo = _unchanged,
    bool? isBadgeDismissed,
    bool? isIgnored,
    Object? errorMessage = _unchanged,
    Object? lastCheckedAt = _unchanged,
  }) =>
      AppUpdateState(
        status: status ?? this.status,
        updateInfo: identical(updateInfo, _unchanged)
            ? this.updateInfo
            : updateInfo as AppUpdateInfo?,
        isBadgeDismissed: isBadgeDismissed ?? this.isBadgeDismissed,
        isIgnored: isIgnored ?? this.isIgnored,
        errorMessage: identical(errorMessage, _unchanged)
            ? this.errorMessage
            : errorMessage as String?,
        lastCheckedAt: identical(lastCheckedAt, _unchanged)
            ? this.lastCheckedAt
            : lastCheckedAt as DateTime?,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppUpdateState &&
          status == other.status &&
          updateInfo == other.updateInfo &&
          isBadgeDismissed == other.isBadgeDismissed &&
          isIgnored == other.isIgnored &&
          errorMessage == other.errorMessage &&
          lastCheckedAt == other.lastCheckedAt;

  @override
  int get hashCode => Object.hash(status, updateInfo, isBadgeDismissed,
      isIgnored, errorMessage, lastCheckedAt);
}

final appUpdateServiceProvider = Provider<AppUpdateService>((ref) {
  final service = AppUpdateService();
  ref.onDispose(service.dispose);
  return service;
});

class AppUpdateNotifier extends Notifier<AppUpdateState> {
  Future<AppUpdateInfo?>? _activeCheck;
  bool _activeIsManual = false;
  String? _dismissedVersion;
  String? _ignoredInSession;

  @override
  AppUpdateState build() => const AppUpdateState();

  Future<void> checkSilently() async {
    if (!ref.mounted) return;
    await (_activeCheck ?? _startCheck(manual: false));
  }

  Future<AppUpdateInfo?> checkManually() async {
    if (!ref.mounted) return null;
    final active = _activeCheck;
    if (active != null) {
      if (_activeIsManual) return active;
      // A forced refresh must not reuse a startup result read from the cache.
      // Finish that operation before fetching and publishing the manual result.
      await active;
      if (!ref.mounted) return null;
      return checkManually();
    }
    return _startCheck(manual: true);
  }

  Future<AppUpdateInfo?> _startCheck({required bool manual}) {
    _activeIsManual = manual;
    final future = _performCheck(manual: manual);
    _activeCheck = future;
    return future;
  }

  Future<AppUpdateInfo?> _performCheck({required bool manual}) async {
    if (manual) _dismissedVersion = null;
    state = state.copyWith(
      status: AppUpdateStatus.checking,
      errorMessage: null,
      isBadgeDismissed: manual ? false : state.isBadgeDismissed,
    );
    try {
      final service = ref.read(appUpdateServiceProvider);
      final info = await service.checkForUpdate(force: manual);
      if (!ref.mounted) return null;
      if (info == null) {
        state = state.copyWith(
            status: AppUpdateStatus.error,
            errorMessage:
                "Не вдалося перевірити оновлення. Спробуйте пізніше.");
        return null;
      }
      var ignored = await service.isVersionIgnored(info.latestVersion);
      if (!ref.mounted) return null;
      // A user's ignore action can finish while this preference read is pending.
      ignored = ignored || _ignoredInSession == info.latestVersion;
      state = state.copyWith(
        status: info.hasUpdate
            ? AppUpdateStatus.available
            : AppUpdateStatus.upToDate,
        updateInfo: info,
        isIgnored: ignored,
        isBadgeDismissed: _dismissedVersion == info.latestVersion,
        errorMessage: null,
        lastCheckedAt: DateTime.now(),
      );
      return info;
    } catch (error, stack) {
      AppLogger.w('Application update check failed',
          tag: 'AppUpdateNotifier', error: error, stackTrace: stack);
      if (ref.mounted) {
        state = state.copyWith(
            status: AppUpdateStatus.error,
            errorMessage: 'Помилка під час перевірки оновлення');
      }
      return null;
    } finally {
      _activeCheck = null;
      _activeIsManual = false;
    }
  }

  void dismissBadge([String? version]) {
    if (!ref.mounted) return;
    final target = version ?? state.updateInfo?.latestVersion;
    if (target == null || state.updateInfo?.latestVersion != target) return;
    _dismissedVersion = target;
    state = state.copyWith(isBadgeDismissed: true);
  }

  /// Returns false when the preference cannot be persisted; the UI stays open.
  Future<bool> ignoreVersion(String version) async {
    if (!ref.mounted) return false;
    try {
      final normalized = AppUpdateService.normalizeVersion(version);
      await ref.read(appUpdateServiceProvider).ignoreVersion(normalized);
      if (!ref.mounted) return false;
      _ignoredInSession = normalized;
      if (state.updateInfo == null ||
          state.updateInfo?.latestVersion == normalized) {
        _dismissedVersion = normalized;
        state = state.copyWith(isIgnored: true, isBadgeDismissed: true);
      }
      return true;
    } catch (error, stack) {
      AppLogger.w('Cannot ignore application version',
          tag: 'AppUpdateNotifier', error: error, stackTrace: stack);
      return false;
    }
  }

  Future<bool> openReleaseUrl(
      [String? targetUrl, String? targetVersion]) async {
    if (!ref.mounted) return false;
    final url = targetUrl ?? state.updateInfo?.releaseUrl;
    final version = targetVersion ?? state.updateInfo?.latestVersion;
    if (url == null) return false;
    final success = await AppUpdateService.openReleaseUrl(url);
    if (success && ref.mounted && version != null) dismissBadge(version);
    return success;
  }
}

final appUpdateProvider =
    NotifierProvider<AppUpdateNotifier, AppUpdateState>(AppUpdateNotifier.new);
