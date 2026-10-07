import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lumen/services/preferences_helper.dart';
import 'package:lumen/ui/state/schedule_version_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
      'missing key defaults to true without writing or changing other preferences',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(
        container.read(scheduleVersionPreferencesProvider).isLoaded, isFalse);
    await container
        .read(scheduleVersionPreferencesProvider.notifier)
        .ensureLoaded();
    expect(container.read(scheduleVersionPreferencesProvider).hideUnchanged,
        isTrue);
    expect(container.read(scheduleVersionPreferencesProvider).isLoaded, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(
        prefs.containsKey(PreferencesHelper.hideUnchangedScheduleVersionsKey),
        isFalse);
  });

  test('saved false is loaded and survives provider recreation', () async {
    SharedPreferences.setMockInitialValues({'selected_group': 'GPV2.1'});
    final container = ProviderContainer();
    final notifier =
        container.read(scheduleVersionPreferencesProvider.notifier);
    await notifier.ensureLoaded();
    expect(await notifier.setHideUnchanged(false), isTrue);
    expect(container.read(scheduleVersionPreferencesProvider).hideUnchanged,
        isFalse);
    container.dispose();
    final restarted = ProviderContainer();
    addTearDown(restarted.dispose);
    await restarted
        .read(scheduleVersionPreferencesProvider.notifier)
        .ensureLoaded();
    expect(restarted.read(scheduleVersionPreferencesProvider).hideUnchanged,
        isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PreferencesHelper.hideUnchangedScheduleVersionsKey),
        isFalse);
    expect(prefs.getString('selected_group'), 'GPV2.1');
  });

  test('read is shared, and changes wait for the stored value', () async {
    final read = Completer<bool>();
    final written = <bool>[];
    var reads = 0;
    final container = ProviderContainer(overrides: [
      scheduleVersionPreferencesProvider
          .overrideWith(() => ScheduleVersionPreferences(
                read: () {
                  reads++;
                  return read.future;
                },
                write: (value) async => written.add(value),
              )),
    ]);
    addTearDown(container.dispose);
    final notifier =
        container.read(scheduleVersionPreferencesProvider.notifier);
    final load = notifier.ensureLoaded();
    final change = notifier.setHideUnchanged(true);
    expect(
        container.read(scheduleVersionPreferencesProvider).isLoaded, isFalse);
    read.complete(false);
    await load;
    expect(await change, isTrue);
    expect(reads, 1);
    expect(written, [true]);
    expect(container.read(scheduleVersionPreferencesProvider).hideUnchanged,
        isTrue);
  });

  test('saving publishes only after success and prevents overlapping writes',
      () async {
    final write = Completer<void>();
    var writes = 0;
    final container = ProviderContainer(overrides: [
      scheduleVersionPreferencesProvider
          .overrideWith(() => ScheduleVersionPreferences(
                read: () async => true,
                write: (_) {
                  writes++;
                  return write.future;
                },
              )),
    ]);
    addTearDown(container.dispose);
    final notifier =
        container.read(scheduleVersionPreferencesProvider.notifier);
    await notifier.ensureLoaded();
    final first = notifier.setHideUnchanged(false);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(scheduleVersionPreferencesProvider).isSaving, isTrue);
    expect(container.read(scheduleVersionPreferencesProvider).hideUnchanged,
        isTrue);
    expect(await notifier.setHideUnchanged(true), isFalse);
    write.complete();
    expect(await first, isTrue);
    expect(writes, 1);
    expect(container.read(scheduleVersionPreferencesProvider).hideUnchanged,
        isFalse);
    expect(
        container.read(scheduleVersionPreferencesProvider).isSaving, isFalse);
  });

  test('failed write retains previous value and permits retry', () async {
    var fail = true;
    final container = ProviderContainer(overrides: [
      scheduleVersionPreferencesProvider
          .overrideWith(() => ScheduleVersionPreferences(
                read: () async => false,
                write: (_) async {
                  if (fail) throw StateError('Storage unavailable');
                },
              )),
    ]);
    addTearDown(container.dispose);
    final notifier =
        container.read(scheduleVersionPreferencesProvider.notifier);
    await notifier.ensureLoaded();
    expect(await notifier.setHideUnchanged(true), isFalse);
    expect(container.read(scheduleVersionPreferencesProvider).hideUnchanged,
        isFalse);
    expect(
        container.read(scheduleVersionPreferencesProvider).isSaving, isFalse);
    fail = false;
    expect(await notifier.setHideUnchanged(true), isTrue);
  });

  test('setting an already stored value avoids unnecessary writes', () async {
    var writes = 0;
    final container = ProviderContainer(overrides: [
      scheduleVersionPreferencesProvider
          .overrideWith(() => ScheduleVersionPreferences(
                read: () async => false,
                write: (_) async {
                  writes++;
                },
              )),
    ]);
    addTearDown(container.dispose);
    final notifier =
        container.read(scheduleVersionPreferencesProvider.notifier);
    await notifier.ensureLoaded();
    expect(await notifier.setHideUnchanged(false), isTrue);
    expect(writes, 0);
  });

  test('disposal before initialization does not start storage work', () async {
    var reads = 0;
    final container = ProviderContainer(overrides: [
      scheduleVersionPreferencesProvider
          .overrideWith(() => ScheduleVersionPreferences(read: () async {
                reads++;
                return true;
              })),
    ]);
    container.read(scheduleVersionPreferencesProvider);
    container.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(reads, 0);
  });

  test('failed load exposes fallback and a successful write recovers',
      () async {
    final written = <bool>[];
    final container = ProviderContainer(overrides: [
      scheduleVersionPreferencesProvider
          .overrideWith(() => ScheduleVersionPreferences(
                read: () async => throw StateError('Storage unavailable'),
                write: (value) async => written.add(value),
              )),
    ]);
    addTearDown(container.dispose);
    final notifier =
        container.read(scheduleVersionPreferencesProvider.notifier);
    await notifier.ensureLoaded();
    expect(
        container.read(scheduleVersionPreferencesProvider).loadFailed, isTrue);
    expect(container.read(scheduleVersionPreferencesProvider).hideUnchanged,
        isTrue);
    expect(await notifier.setHideUnchanged(false), isTrue);
    expect(
        container.read(scheduleVersionPreferencesProvider).loadFailed, isFalse);
    expect(written, [false]);
  });

  test('disposal during pending read or write is safe', () async {
    final read = Completer<bool>();
    final container = ProviderContainer(overrides: [
      scheduleVersionPreferencesProvider
          .overrideWith(() => ScheduleVersionPreferences(
                read: () => read.future,
              )),
    ]);
    final load = container
        .read(scheduleVersionPreferencesProvider.notifier)
        .ensureLoaded();
    container.dispose();
    read.complete(false);
    await load;

    final write = Completer<void>();
    final other = ProviderContainer(overrides: [
      scheduleVersionPreferencesProvider
          .overrideWith(() => ScheduleVersionPreferences(
                read: () async => true,
                write: (_) => write.future,
              )),
    ]);
    final notifier = other.read(scheduleVersionPreferencesProvider.notifier);
    await notifier.ensureLoaded();
    final save = notifier.setHideUnchanged(false);
    await Future<void>.delayed(Duration.zero);
    other.dispose();
    write.complete();
    expect(await save, isFalse);
  });
}
