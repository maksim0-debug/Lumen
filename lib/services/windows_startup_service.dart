import 'dart:io';

import 'package:flutter/services.dart';
import 'package:launch_at_startup/launch_at_startup.dart';

import 'app_logger.dart';
import 'preferences_helper.dart';

enum WindowsStartupMode { tray, minimized }

abstract class WindowsStartupRegistration {
  Future<void> initialize();
  Future<bool> isEnabled();
  Future<void> setEnabled(bool enabled);
}

class WindowsStartupService {
  WindowsStartupService({WindowsStartupRegistration? registration})
      : _registration = registration ?? _WindowsStartupRegistration();

  static final instance = WindowsStartupService();
  static const autoStartArgument = '--autostart';
  static const modeKey = 'windows_startup_mode';
  static const channel = MethodChannel('lumen/windows_startup');

  final WindowsStartupRegistration _registration;
  Future<void>? _initialization;

  Future<void> initialize() async {
    final pending = _initialization ??= _registration.initialize();
    try {
      await pending;
    } catch (_) {
      if (identical(_initialization, pending)) _initialization = null;
      rethrow;
    }
  }

  Future<bool> isEnabled() async {
    await initialize();
    return _registration.isEnabled();
  }

  Future<void> setEnabled(bool enabled) async {
    await initialize();
    await _registration.setEnabled(enabled);
    if (await _registration.isEnabled() != enabled) {
      throw StateError('Windows did not apply the startup setting');
    }
  }

  Future<WindowsStartupMode> readMode() async {
    final prefs = await PreferencesHelper.getSafeInstance();
    return prefs.get(modeKey) == WindowsStartupMode.minimized.name
        ? WindowsStartupMode.minimized
        : WindowsStartupMode.tray;
  }

  Future<void> writeMode(WindowsStartupMode mode) async {
    final prefs = await PreferencesHelper.getSafeInstance();
    try {
      if (!await prefs.setString(modeKey, mode.name)) {
        throw StateError('Cannot persist Windows startup mode');
      }
    } catch (_) {
      try {
        await prefs.reload();
      } catch (error) {
        AppLogger.w('Cannot reload Windows startup preferences',
            tag: 'WindowsStartup', error: error, persistToHistory: false);
      }
      rethrow;
    }
  }

  Future<void> showInitialWindow({
    required List<String> arguments,
    required bool trayAvailable,
  }) async {
    if (arguments.contains(autoStartArgument)) {
      final mode = await readMode();
      if (mode == WindowsStartupMode.minimized || trayAvailable) {
        await channel.invokeMethod<void>(
            'applyAutomaticStartupMode', mode.name);
        return;
      }
    }
    // A manual launch always opens the app. A missing tray must never leave an
    // automatic launch hidden without a way to bring the window back.
    await channel.invokeMethod<void>('showNormal');
  }
}

class _WindowsStartupRegistration implements WindowsStartupRegistration {
  bool _packaged = false;

  @override
  Future<void> initialize() async {
    _packaged = await WindowsStartupService.channel
            .invokeMethod<String>('getStartupState') !=
        null;
    if (_packaged) return;

    // Preserve an enabled registration created by older Lumen versions. The
    // package compares the entire command, so read it before adding arguments.
    launchAtStartup.setup(
        appName: 'Lumen', appPath: Platform.resolvedExecutable);
    final legacyEnabled = await launchAtStartup.isEnabled();
    launchAtStartup.setup(
      appName: 'Lumen',
      // launch_at_startup 0.5.1 concatenates this value without quoting it.
      appPath: '"${Platform.resolvedExecutable}"',
      args: const [WindowsStartupService.autoStartArgument],
    );
    if (legacyEnabled && !await launchAtStartup.enable()) {
      throw StateError('Cannot migrate the Windows startup registration');
    }
  }

  @override
  Future<bool> isEnabled() async {
    if (!_packaged) return launchAtStartup.isEnabled();
    final state = await WindowsStartupService.channel
        .invokeMethod<String>('getStartupState');
    return state == 'enabled' || state == 'enabledByPolicy';
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    if (_packaged) {
      await WindowsStartupService.channel
          .invokeMethod<String>('setStartupEnabled', enabled);
    } else {
      final success = enabled
          ? await launchAtStartup.enable()
          : await launchAtStartup.disable();
      if (!success) throw StateError('Cannot update Windows startup');
    }
  }
}
