import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lumen/services/fcm_event_guard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('concurrent duplicate foreground events are claimed only once',
      () async {
    final results = await Future.wait(
        List.generate(10, (_) => FcmEventGuard.claim('same-event')));
    expect(results.where((v) => v).length, 1);
    expect(await FcmEventGuard.claim('new-event'), true);
    expect(await FcmEventGuard.claim('same-event'), false);
  });
  test('legacy messages without identity work; oversized identities rejected',
      () async {
    expect(await FcmEventGuard.claim(null), true);
    expect(await FcmEventGuard.claim(''), true);
    expect(await FcmEventGuard.claim('a' * 513), false);
  });
  test(
      'bounded identity cache evicts oldest events but retains recent duplicates',
      () async {
    for (var i = 0; i < 201; i++) {
      expect(await FcmEventGuard.claim('event-$i'), true);
    }
    expect(await FcmEventGuard.claim('event-200'), false);
    expect(await FcmEventGuard.claim('event-0'), true);
  });
}
