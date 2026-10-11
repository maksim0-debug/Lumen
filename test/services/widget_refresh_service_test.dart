import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/widget_refresh_service.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = WidgetRefreshService.channel;
  const codec = StandardMethodCodec();
  late bool pending;
  late int consumed;
  late int refreshes;
  late WidgetRefreshService service;
  Future<void> Function()? refresh;

  Future<void> signal() async {
    await binding.defaultBinaryMessenger.handlePlatformMessage(channel.name,
        codec.encodeMethodCall(const MethodCall('refreshRequested')), (_) {});
  }

  setUp(() {
    pending = false;
    consumed = 0;
    refreshes = 0;
    refresh = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      expect(call.method, 'consumePendingRefresh');
      consumed++;
      final result = pending;
      pending = false;
      return result;
    });
    service = WidgetRefreshService(onRefresh: () async {
      refreshes++;
      await refresh?.call();
    });
  });

  tearDown(() {
    service.dispose();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('ordinary app launch does not request a manual refresh', () async {
    expect(await service.start(), false);
    expect(refreshes, 0);
  });

  test('cold widget launch consumes pending request exactly once', () async {
    pending = true;
    expect(await service.start(), true);
    await signal();
    expect(refreshes, 1);
    expect(pending, false);
  });

  test('warm widget launch refreshes and later independent tap works',
      () async {
    await service.start();
    pending = true;
    await signal();
    pending = true;
    await signal();
    expect(refreshes, 2);
  });

  test('overlapping taps join active refresh without replay afterwards',
      () async {
    final completion = Completer<void>();
    final started = Completer<void>();
    refresh = () {
      started.complete();
      return completion.future;
    };
    pending = true;
    final initial = service.start();
    await started.future;
    pending = true;
    await signal();
    pending = true;
    await signal();
    expect(refreshes, 1);
    completion.complete();
    expect(await initial, true);
    await signal();
    expect(refreshes, 1);
    expect(pending, false);
  });

  test('refresh failure releases guard and does not request startup retry',
      () async {
    refresh = () async => throw StateError('test failure');
    pending = true;
    expect(await service.start(), true);
    refresh = null;
    pending = true;
    await signal();
    expect(refreshes, 2);
  });

  test('channel failure leaves normal startup available and can recover',
      () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel, (_) async => throw PlatformException(code: 'unavailable'));
    expect(await service.start(), false);
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => true);
    await signal();
    expect(refreshes, 1);
  });

  test('dispose during pending consume prevents callback', () async {
    final response = Completer<bool>();
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) => response.future);
    final initial = service.start();
    service.dispose();
    response.complete(true);
    expect(await initial, false);
    expect(refreshes, 0);
  });

  test('disposed listener does not consume new native requests', () async {
    await service.start();
    service.dispose();
    pending = true;
    await signal();
    expect(await service.start(), false);
    expect(consumed, 1);
    expect(pending, true);
    expect(refreshes, 0);
  });

  test('unknown platform events do not trigger or consume refresh', () async {
    await service.start();
    pending = true;
    await binding.defaultBinaryMessenger.handlePlatformMessage(channel.name,
        codec.encodeMethodCall(const MethodCall('unrelated')), (_) {});
    expect(refreshes, 0);
    expect(consumed, 1);
    expect(pending, true);
  });
}
