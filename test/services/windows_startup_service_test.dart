import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/windows_startup_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _Registration implements WindowsStartupRegistration {
  bool enabled = false;
  bool refuseChange = false;
  int initializations = 0;
  Future<void> Function()? onInitialize;

  @override
  Future<void> initialize() async {
    initializations++;
    await onInitialize?.call();
  }

  @override
  Future<bool> isEnabled() async => enabled;

  @override
  Future<void> setEnabled(bool value) async {
    if (!refuseChange) enabled = value;
  }
}

class _FailingStore extends InMemorySharedPreferencesStore {
  _FailingStore()
      : super.withData({
          'flutter.${WindowsStartupService.modeKey}': 'tray',
        });

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late WindowsStartupService service;
  late _Registration registration;
  late List<String> calls;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    registration = _Registration();
    service = WindowsStartupService(registration: registration);
    calls = [];
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(WindowsStartupService.channel, (call) async {
      calls.add('${call.method}:${call.arguments}');
      return null;
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(WindowsStartupService.channel, null);
  });

  test('missing, unknown and malformed modes default to tray without a write',
      () async {
    for (final value in [null, 'unknown', true]) {
      SharedPreferences.setMockInitialValues({
        if (value != null) WindowsStartupService.modeKey: value,
      });
      expect(await service.readMode(), WindowsStartupMode.tray);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.get(WindowsStartupService.modeKey), value);
    }
  });

  test(
      'one saved mode survives service recreation and preserves other settings',
      () async {
    SharedPreferences.setMockInitialValues({'selected_group': 'GPV2.1'});
    await service.writeMode(WindowsStartupMode.minimized);
    final restarted = WindowsStartupService(registration: _Registration());
    expect(await restarted.readMode(), WindowsStartupMode.minimized);
    await restarted.writeMode(WindowsStartupMode.tray);
    expect(await service.readMode(), WindowsStartupMode.tray);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('selected_group'), 'GPV2.1');
    expect(prefs.getKeys(), {'selected_group', WindowsStartupService.modeKey});
  });

  test('failed persistence reloads the cached value', () async {
    final original = SharedPreferencesStorePlatform.instance;
    SharedPreferencesStorePlatform.instance = _FailingStore();
    addTearDown(() => SharedPreferencesStorePlatform.instance = original);
    await expectLater(
        service.writeMode(WindowsStartupMode.minimized), throwsStateError);
    expect(await service.readMode(), WindowsStartupMode.tray);
  });

  test('registration initialization is shared by simultaneous readers',
      () async {
    final ready = Completer<void>();
    registration.onInitialize = () => ready.future;
    final first = service.isEnabled();
    final second = service.isEnabled();
    expect(registration.initializations, 1);
    ready.complete();
    expect(await first, false);
    expect(await second, false);
  });

  test('registration initialization can retry after a failure', () async {
    registration.onInitialize = () async => throw StateError('Unavailable');
    await expectLater(service.isEnabled(), throwsStateError);
    registration.onInitialize = null;
    expect(await service.isEnabled(), false);
    expect(registration.initializations, 2);
  });

  test('enable and disable use verified system state', () async {
    await service.setEnabled(true);
    expect(await service.isEnabled(), true);
    await service.setEnabled(false);
    expect(await service.isEnabled(), false);
    registration.refuseChange = true;
    await expectLater(service.setEnabled(true), throwsStateError);
    expect(await service.isEnabled(), false);
  });

  for (final mode in WindowsStartupMode.values) {
    test('manual launch opens and focuses the window for saved ${mode.name}',
        () async {
      await service.writeMode(mode);
      await service.showInitialWindow(arguments: [], trayAvailable: true);
      expect(calls, ['showNormal:null']);
    });
  }

  test('automatic tray launch never shows or focuses the window', () async {
    await service
        .showInitialWindow(arguments: ['--autostart'], trayAvailable: true);
    expect(calls, ['applyAutomaticStartupMode:tray']);
  });

  test('automatic minimized launch uses the native non-activating show',
      () async {
    await service.writeMode(WindowsStartupMode.minimized);
    await service
        .showInitialWindow(arguments: ['--autostart'], trayAvailable: true);
    expect(calls, ['applyAutomaticStartupMode:minimized']);
  });

  test('missing tray recovers automatic tray launch to a visible window',
      () async {
    await service
        .showInitialWindow(arguments: ['--autostart'], trayAvailable: false);
    expect(calls, ['showNormal:null']);
  });

  test('unrelated arguments do not trigger automatic startup', () async {
    await service.showInitialWindow(
        arguments: ['--autostart-other'], trayAvailable: true);
    expect(calls, ['showNormal:null']);
  });

  for (final state in [
    'disabled',
    'disabledByUser',
    'disabledByPolicy',
    'enabled',
    'enabledByPolicy'
  ]) {
    test('MSIX reads Windows StartupTask state $state', () async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
          WindowsStartupService.channel, (call) async => state);
      final packagedService = WindowsStartupService();
      expect(await packagedService.isEnabled(),
          state == 'enabled' || state == 'enabledByPolicy');
    });
  }

  test('MSIX enable and disable target the native task and verify it',
      () async {
    var enabled = false;
    final mutations = <bool>[];
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(WindowsStartupService.channel, (call) async {
      if (call.method == 'setStartupEnabled') {
        enabled = call.arguments as bool;
        mutations.add(enabled);
      }
      return enabled ? 'enabled' : 'disabled';
    });
    final packagedService = WindowsStartupService();
    await packagedService.setEnabled(true);
    await packagedService.setEnabled(false);
    expect(mutations, [true, false]);
  });
}
