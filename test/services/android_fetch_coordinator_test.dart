import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/android_fetch_coordinator.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late AndroidFetchCoordinator first;
  late AndroidFetchCoordinator second;
  setUp(() async {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await AndroidFetchCoordinator.createSchema(db);
    first = AndroidFetchCoordinator(() async => db,
        pollInterval: const Duration(milliseconds: 5));
    second = AndroidFetchCoordinator(() async => db,
        pollInterval: const Duration(milliseconds: 5));
  });
  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  Future<String> fetch(
    AndroidFetchCoordinator coordinator,
    Future<String> Function() action, {
    String target = 'dtek',
    Duration wait = const Duration(seconds: 2),
    Duration lease = const Duration(seconds: 2),
    String? Function(String)? decode,
    void Function(String, Map<String, Object?>)? observe,
  }) =>
      coordinator.run(
          target: target,
          waitTimeout: wait,
          leaseDuration: lease,
          fetch: action,
          encode: (value) => value,
          decode: decode ?? (value) => value,
          observe: observe);

  test(
      'Overlapping independent coordinators run one fetch and share its result',
      () async {
    final started = Completer<void>();
    final release = Completer<String>();
    var requests = 0;
    final owner = fetch(first, () {
      requests++;
      started.complete();
      return release.future;
    });
    await started.future;
    final waiter = fetch(second, () async {
      requests++;
      return 'wrong';
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    release.complete('all 12 groups');
    expect(
        await Future.wait([owner, waiter]), ['all 12 groups', 'all 12 groups']);
    expect(requests, 1);
    expect((await db.query('android_schedule_fetch')).single['owner'], isNull);
  });

  test('A later explicit fetch never silently reuses the previous result',
      () async {
    expect(await fetch(first, () async => 'A'), 'A');
    expect(await fetch(second, () async => 'B'), 'B');
  });

  test('A failed owner releases the lease and a waiting caller retries',
      () async {
    final gate = Completer<String>();
    final started = Completer<void>();
    final failure = StateError('original');
    final owner = fetch(first, () {
      started.complete();
      return gate.future;
    });
    final expectation = expectLater(owner, throwsA(same(failure)));
    await started.future;
    final waiter = fetch(second, () async => 'recovered');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    gate.completeError(failure);
    await expectation;
    expect(await waiter, 'recovered');
  });

  test('A waiting caller respects its deadline without stealing a live lease',
      () async {
    final gate = Completer<String>();
    final started = Completer<void>();
    final owner = fetch(first, () {
      started.complete();
      return gate.future;
    });
    await started.future;
    await expectLater(
        fetch(second, () async => fail('duplicate request'),
            wait: const Duration(milliseconds: 20)),
        throwsA(isA<TimeoutException>()));
    expect(
        (await db.query('android_schedule_fetch')).single['owner'], isNotNull);
    gate.complete('done');
    expect(await owner, 'done');
  });

  for (final expiry in [-1, 600000]) {
    test('An abandoned/clock-shifted lease ($expiry) recovers', () async {
      await db.insert('android_schedule_fetch', {
        'target': 'dtek',
        'owner': 'dead',
        'expires_at': DateTime.now().millisecondsSinceEpoch + expiry
      });
      expect(await fetch(first, () async => 'fresh'), 'fresh');
    });
  }

  test('A late expired owner cannot release or replace a newer owner',
      () async {
    final old = Completer<String>();
    final started = Completer<void>();
    final owner = fetch(first, () {
      started.complete();
      return old.future;
    }, lease: const Duration(milliseconds: 10));
    await started.future;
    await Future<void>.delayed(const Duration(milliseconds: 25));
    final replacement = Completer<String>();
    final replacementStarted = Completer<void>();
    final next = fetch(second, () {
      replacementStarted.complete();
      return replacement.future;
    });
    await replacementStarted.future;
    final newOwner = (await db.query('android_schedule_fetch')).single['owner'];
    old.complete('obsolete');
    await owner;
    expect(
        (await db.query('android_schedule_fetch')).single['owner'], newOwner);
    replacement.complete('new');
    await next;
    expect((await db.query('android_schedule_fetch')).single['payload'], 'new');
  });

  test('A stale or malformed shared payload is not accepted', () async {
    final gate = Completer<String>();
    final started = Completer<void>();
    final owner = fetch(first, () {
      started.complete();
      return gate.future;
    });
    await started.future;
    final waiter = fetch(second, () async => 'valid', decode: (_) => null);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    gate.complete('invalid');
    await owner;
    expect(await waiter, 'valid');
  });

  test('A failed release preserves a successful result', () async {
    expect(
        await fetch(first, () async {
          await db.close();
          return 'valid';
        }),
        'valid');
  });

  test('A failed release preserves the original fetch exception', () async {
    final failure = StateError('fetch failed');
    await expectLater(
        fetch(first, () async {
          await db.close();
          throw failure;
        }),
        throwsA(same(failure)));
  });

  test(
      'Resume reads only a fresh completed snapshot and preserves completion time',
      () async {
    expect(
        await first.recent(
            target: 'dtek',
            maxAge: const Duration(seconds: 30),
            decode: (value) => value),
        isNull);
    await fetch(first, () async => 'fresh');
    final recent = await first.recent(
        target: 'dtek',
        maxAge: const Duration(seconds: 30),
        decode: (value) => value);
    expect(recent!.value, 'fresh');
    final now = DateTime.now().millisecondsSinceEpoch;
    expect(recent.completedAt, lessThanOrEqualTo(now));
    for (final completedAt in [now - 31000, now + 10000]) {
      await db.update('android_schedule_fetch', {'completed_at': completedAt});
      expect(
          await first.recent(
              target: 'dtek',
              maxAge: const Duration(seconds: 30),
              decode: (value) => value),
          isNull);
    }
  });

  test('Different SQLite connections coordinate a real file-backed database',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('lumen-fetch-lease-');
    final file = '${directory.path}/fetch.db';
    final a = await databaseFactoryFfi.openDatabase(file,
        options: OpenDatabaseOptions(singleInstance: false));
    final b = await databaseFactoryFfi.openDatabase(file,
        options: OpenDatabaseOptions(singleInstance: false));
    try {
      await AndroidFetchCoordinator.createSchema(a);
      final one = AndroidFetchCoordinator(() async => a,
          pollInterval: const Duration(milliseconds: 5));
      final two = AndroidFetchCoordinator(() async => b,
          pollInterval: const Duration(milliseconds: 5));
      var count = 0;
      final started = Completer<void>();
      final gate = Completer<String>();
      final owner = fetch(one, () {
        count++;
        started.complete();
        return gate.future;
      });
      await started.future;
      final waiting = Completer<void>();
      final waiter = fetch(two, () async {
        count++;
        return 'duplicate';
      }, observe: (stage, _) {
        if (stage == 'fetch_wait' && !waiting.isCompleted) waiting.complete();
      });
      await waiting.future;
      gate.complete('shared');
      expect(await Future.wait([owner, waiter]), ['shared', 'shared']);
      expect(count, 1);
    } finally {
      await a.close();
      await b.close();
      await directory.delete(recursive: true);
    }
  });
}
