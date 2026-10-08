import 'dart:io' as io;

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/parser_transport_policy.dart';

void main() {
  final now = DateTime.utc(2026, 10, 8, 12);
  final origin = Uri.parse('https://www.dtek-krem.com.ua/ua/shutdowns');

  group('Protection documents', () {
    for (final html in [
      '<html><body><footer>Protected by Imperva Incapsula</footer></body></html>',
      '<html><body><!-- Access Denied Error 15 --><h1>Графіки</h1></body></html>',
      '<script>var message="blocked by our security policy";</script>',
      '<template>Access Denied</template><p>Графіки</p>',
      '<html><body><p>FAQ: what does Access Denied mean?</p></body></html>',
      '<header>DTEK</header><h2>FAQ: what does Access Denied mean?</h2>',
      '<header>DTEK</header><h3>How to resolve Error 15?</h3>',
    ]) {
      test('Normal content is accepted: $html', () {
        expect(ParserProtection.classify(html), ParserPageProtection.none);
      });
    }
    for (final html in [
      '<script src="/_Incapsula_Resource?id=1"></script>',
      '<iframe src="/_incapsula_resource?id=2"></iframe>',
      '<script src="/cdn-cgi/challenge-platform/x.js"></script>',
      '<div id="cf-browser-verification">Checking</div>',
      '<title>Just a moment...</title>',
    ]) {
      test('Challenge is recognized: $html', () {
        expect(ParserProtection.classify(html), ParserPageProtection.challenge);
      });
    }
    for (final html in [
      '<title>ACCESS DENIED</title>',
      '<h1>Error 15</h1><p>Powered by Imperva</p>',
      '<p>Адреса країни, яка заблокована нашою політикою безпеки.</p>',
      '<p>Your country is blocked by our security policy.</p>',
      '<title>ДТЕК Київські регіональні електромережі</title>'
          '<header>DTEK</header><h1>Access Denied</h1>',
      '<header>DTEK</header><h2> Error   15 </h2><p>Request rejected</p>',
      '<nav>Home / Security</nav><h3>ACCESS DENIED: request blocked</h3>',
    ]) {
      test('Permanent denial is recognized: $html', () {
        expect(ParserProtection.classify(html), ParserPageProtection.blocked);
      });
    }
  });

  group('HTTP Retry-After', () {
    test('Seconds, HTTP date and a past date', () {
      expect(ParserFetchPolicy.retryAfter(' 12 ', now),
          const Duration(seconds: 12));
      expect(ParserFetchPolicy.retryAfter('0', now), Duration.zero);
      expect(
          ParserFetchPolicy.retryAfter(
              io.HttpDate.format(now.add(const Duration(minutes: 2))), now),
          const Duration(minutes: 2));
      expect(
          ParserFetchPolicy.retryAfter(
              io.HttpDate.format(now.subtract(const Duration(seconds: 1))),
              now),
          Duration.zero);
    });
    test('Invalid values cannot schedule an immediate retry', () {
      for (final value in [null, '', '-1', '1.5', 'tomorrow']) {
        expect(ParserFetchPolicy.retryAfter(value, now), isNull);
      }
      final huge =
          ParserFetchPolicy.retryAfter('999999999999999999999999', now)!;
      expect(huge, greaterThan(const Duration(days: 365)));
      expect(() => now.add(huge), returnsNormally);
    });
    test('Background parsing leaves room inside the FCM time limit', () {
      expect(const ParserFetchPolicy().connectionTimeout,
          const Duration(seconds: 12));
      expect(ParserFetchPolicy.background.connectionTimeout,
          const Duration(seconds: 8));
      expect(ParserFetchPolicy.background.totalTimeout,
          lessThan(const Duration(seconds: 30)));
      expect(ParserFetchPolicy.background.httpTimeout,
          lessThan(ParserFetchPolicy.background.totalTimeout));
    });
  });

  test('Only the main schedule origin and path match', () {
    for (final value in [
      origin.toString(),
      '${origin.toString()}/',
      '${origin.toString()}?refresh=1'
    ]) {
      expect(ParserFetchPolicy.isScheduleUrl(Uri.parse(value), origin), true);
    }
    for (final value in [
      'http://www.dtek-krem.com.ua/ua/shutdowns',
      'https://www.dtek-krem.com.ua:444/ua/shutdowns',
      'https://evil.test/ua/shutdowns',
      'https://www.dtek-krem.com.ua/ua/shutdowns/script.js',
      'https://www.dtek-krem.com.ua/ua/shutdowns-other',
      'https://user@www.dtek-krem.com.ua/ua/shutdowns',
    ]) {
      expect(ParserFetchPolicy.isScheduleUrl(Uri.parse(value), origin), false,
          reason: value);
    }
  });

  group('Schedule cookie jar', () {
    late ParserCookieJar jar;
    setUp(() => jar = ParserCookieJar());
    test('WebView rotation replaces previous cookies and sessions expire', () {
      jar.replaceFromWebView(
          [Cookie(name: 'session', value: 'first')], origin, now);
      expect(jar.header(origin, now), 'session=first');
      jar.replaceFromWebView(
          [Cookie(name: 'session', value: 'second')], origin, now);
      expect(jar.header(origin, now), 'session=second');
      expect(jar.header(origin, now.add(ParserCookieJar.sessionLifetime)),
          isEmpty);
    });
    test('Explicit expiry is honored and other origins are excluded', () {
      jar.replaceFromWebView([
        Cookie(
            name: 'alive',
            value: '1',
            domain: '.dtek-krem.com.ua',
            expiresDate:
                now.add(const Duration(seconds: 10)).millisecondsSinceEpoch),
        Cookie(
            name: 'expired',
            value: '2',
            expiresDate: now
                .subtract(const Duration(seconds: 1))
                .millisecondsSinceEpoch),
        Cookie(name: 'foreign', value: '3', domain: 'evil.test'),
      ], origin, now);
      expect(jar.header(origin, now), 'alive=1');
      expect(
          jar.header(
              Uri.parse('https://other.dtek-krem.com.ua/ua/shutdowns'), now),
          isEmpty);
      expect(jar.header(origin, now.add(const Duration(seconds: 10))), isEmpty);
    });
    test('Secure cookies, path boundaries and longest path first', () {
      jar.updateFromHttp([
        io.Cookie('root', '1')..path = '/',
        io.Cookie('parent', '2')
          ..path = '/ua'
          ..secure = true,
        io.Cookie('exact', '3')..path = '/ua/shutdowns',
        io.Cookie('wrong', '4')..path = '/ua/shut',
      ], origin, now);
      expect(jar.header(origin, now), 'exact=3; parent=2; root=1');
      expect(
          jar.header(origin.replace(scheme: 'http'), now), 'exact=3; root=1');
      expect(jar.header(origin.replace(path: '/uabc'), now), 'root=1');
    });
    test('HTTP updates and Max-Age deletion override Expires', () {
      jar.updateFromHttp([io.Cookie('session', 'old')], origin, now);
      jar.updateFromHttp(
          [io.Cookie('session', 'new')..maxAge = 2], origin, now);
      expect(jar.header(origin, now), 'session=new');
      expect(jar.header(origin, now.add(const Duration(seconds: 2))), isEmpty);
      jar.updateFromHttp([
        io.Cookie('session', 'deleted')
          ..maxAge = 0
          ..expires = now.add(const Duration(days: 1))
      ], origin, now);
      expect(jar.header(origin, now), isEmpty);
    });
    test('Missing path uses the response directory; unsafe values are excluded',
        () {
      jar.updateFromHttp([io.Cookie('session', '1')], origin, now);
      expect(jar.header(origin.replace(path: '/ua'), now), 'session=1');
      expect(jar.header(origin.replace(path: '/unrelated'), now), isEmpty);
      jar.replaceFromWebView([
        Cookie(name: 'bad', value: '1; injected=2'),
        Cookie(name: 'bad\r\n', value: '2')
      ], origin, now);
      expect(jar.header(origin, now), isEmpty);
    });
  });
}
