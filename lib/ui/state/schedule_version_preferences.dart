import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/app_logger.dart';
import '../../services/preferences_helper.dart';

class ScheduleVersionPreferencesState {
  final bool hideUnchanged;
  final bool isLoaded;
  final bool isSaving;
  final bool loadFailed;

  const ScheduleVersionPreferencesState({
    this.hideUnchanged = true,
    this.isLoaded = false,
    this.isSaving = false,
    this.loadFailed = false,
  });
}

class ScheduleVersionPreferences
    extends Notifier<ScheduleVersionPreferencesState> {
  final Future<bool> Function() _read;
  final Future<void> Function(bool) _write;
  Future<void>? _loadFuture;

  ScheduleVersionPreferences({
    Future<bool> Function()? read,
    Future<void> Function(bool)? write,
  })  : _read = read ?? PreferencesHelper.readHideUnchangedScheduleVersions,
        _write = write ?? PreferencesHelper.writeHideUnchangedScheduleVersions;

  @override
  ScheduleVersionPreferencesState build() {
    unawaited(Future.microtask(ensureLoaded));
    return const ScheduleVersionPreferencesState();
  }

  Future<void> ensureLoaded() =>
      ref.mounted ? (_loadFuture ??= _load()) : Future.value();

  Future<void> _load() async {
    try {
      final value = await _read();
      if (!ref.mounted) return;
      state =
          ScheduleVersionPreferencesState(hideUnchanged: value, isLoaded: true);
    } catch (error, stack) {
      AppLogger.e('Cannot load schedule version preference',
          tag: 'ScheduleVersions',
          error: error,
          stackTrace: stack,
          persistToHistory: false);
      if (!ref.mounted) return;
      state = const ScheduleVersionPreferencesState(
          isLoaded: true, loadFailed: true);
    }
  }

  /// Publish the new value only after persistence succeeds.
  Future<bool> setHideUnchanged(bool value) async {
    await ensureLoaded();
    if (!ref.mounted || state.isSaving) return false;
    if (value == state.hideUnchanged && !state.loadFailed) return true;
    final previous = state;
    state = ScheduleVersionPreferencesState(
        hideUnchanged: previous.hideUnchanged,
        isLoaded: true,
        isSaving: true,
        loadFailed: previous.loadFailed);
    try {
      await _write(value);
      if (!ref.mounted) return false;
      state =
          ScheduleVersionPreferencesState(hideUnchanged: value, isLoaded: true);
      return true;
    } catch (error, stack) {
      AppLogger.e('Cannot save schedule version preference',
          tag: 'ScheduleVersions',
          error: error,
          stackTrace: stack,
          persistToHistory: false);
      if (ref.mounted) state = previous;
      return false;
    }
  }
}

final scheduleVersionPreferencesProvider = NotifierProvider<
    ScheduleVersionPreferences, ScheduleVersionPreferencesState>(
  ScheduleVersionPreferences.new,
);
