import 'dart:io' as io;

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;

/// Bounds the whole operation as well as individual external calls.
class ParserFetchPolicy {
  final Duration totalTimeout;
  final Duration httpTimeout;
  final Duration webViewTimeout;
  final Duration controllerTimeout;
  final Duration cookieTimeout;
  final Duration pollInterval;
  final Duration challengeGrace;
  final Duration recoveryDelay;
  final Duration httpRetryDelay;
  final Duration rateLimitDelay;
  final int pollAttempts;
  final int maxReloads;

  const ParserFetchPolicy({
    this.totalTimeout = const Duration(seconds: 85),
    this.httpTimeout = const Duration(seconds: 20),
    this.webViewTimeout = const Duration(seconds: 40),
    this.controllerTimeout = const Duration(seconds: 5),
    this.cookieTimeout = const Duration(seconds: 1),
    this.pollInterval = const Duration(milliseconds: 500),
    this.challengeGrace = const Duration(seconds: 5),
    this.recoveryDelay = const Duration(milliseconds: 2500),
    this.httpRetryDelay = const Duration(milliseconds: 700),
    this.rateLimitDelay = const Duration(seconds: 5),
    this.pollAttempts = 24,
    this.maxReloads = 2,
  });

  // FCM background handlers may be stopped by the OS after about 30 seconds.
  static const background = ParserFetchPolicy(
      totalTimeout: Duration(seconds: 25), httpTimeout: Duration(seconds: 8));

  // Preserve the previous connection limit while bounding the whole response.
  Duration get connectionTimeout => httpTimeout < const Duration(seconds: 12)
      ? httpTimeout
      : const Duration(seconds: 12);

  static Duration? retryAfter(String? value, DateTime now) {
    if (value == null) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null) {
      // Keep hostile numeric values representable when adding them to a date.
      return seconds < 0
          ? null
          : Duration(seconds: seconds.clamp(0, 3153600000));
    }
    if (RegExp(r'^\d+$').hasMatch(value.trim())) {
      return const Duration(days: 36500);
    }
    try {
      final delay = io.HttpDate.parse(value).difference(now);
      return delay.isNegative ? Duration.zero : delay;
    } on FormatException {
      return null;
    } on io.HttpException {
      return null;
    }
  }

  static bool isScheduleUrl(Uri candidate, Uri target) =>
      candidate.userInfo.isEmpty &&
      candidate.scheme == target.scheme &&
      candidate.host == target.host &&
      candidate.port == target.port &&
      candidate.path.replaceFirst(RegExp(r'/+$'), '') ==
          target.path.replaceFirst(RegExp(r'/+$'), '');
}

enum ParserPageProtection { none, challenge, blocked }

/// Identify a protection document, not a vendor name in normal site content.
class ParserProtection {
  static String _visibleText(dom.Node node) =>
      node is dom.Text ? node.data : node.nodes.map(_visibleText).join(' ');

  static ParserPageProtection classify(String html) {
    if (html.isEmpty) return ParserPageProtection.none;
    final document = html_parser.parse(html);
    final title = (document.querySelector('title')?.text ?? '').trim();
    final challengeResource = document
        .querySelectorAll('script[src], iframe[src]')
        .any((node) => RegExp(r'_Incapsula_Resource|cdn-cgi/challenge-platform',
                caseSensitive: false)
            .hasMatch(node.attributes['src'] ?? ''));
    for (final node
        in document.querySelectorAll('script, style, template, noscript')) {
      node.remove();
    }
    final text =
        _visibleText(document.body ?? document.documentElement ?? document)
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
    final denial =
        RegExp(r'^(?:access denied\b|error\s*15\b)', caseSensitive: false);
    // Branding/navigation may precede the error in body text. Match the start
    // of individual headings without treating FAQ mentions as denial pages.
    final hasDenialHeading = document.querySelectorAll('h1, h2, h3').any(
        (node) =>
            denial.hasMatch(node.text.replaceAll(RegExp(r'\s+'), ' ').trim()));
    if (denial.hasMatch(title) ||
        hasDenialHeading ||
        denial.hasMatch(text) ||
        RegExp(r'заблокована нашою політикою безпеки|blocked by our security policy',
                caseSensitive: false)
            .hasMatch(text)) {
      return ParserPageProtection.blocked;
    }
    // Only URL-bearing protection elements count. Ignore comments and scripts
    // merely mentioning the name of a WAF provider.
    if (challengeResource ||
        document.querySelector('#cf-browser-verification') != null ||
        RegExp(r'^just a moment(?:\.\.\.|…)?$', caseSensitive: false)
            .hasMatch(title)) {
      return ParserPageProtection.challenge;
    }
    return ParserPageProtection.none;
  }
}

class _SessionCookie {
  final String name;
  final String value;
  final String domain;
  final String originHost;
  final String path;
  final bool secure;
  final DateTime expires;
  const _SessionCookie(this.name, this.value, this.domain, this.originHost,
      this.path, this.secure, this.expires);
  String get key => '$domain\n$path\n$name';
}

/// A bounded cookie jar for the one schedule origin. No cookie values are logged.
class ParserCookieJar {
  static const sessionLifetime = Duration(minutes: 10);
  final _cookies = <String, _SessionCookie>{};
  void clear() => _cookies.clear();

  void _store(String name, String? value, String? domain, String? path,
      bool secure, DateTime expires, Uri origin) {
    final host =
        (domain ?? origin.host).toLowerCase().replaceFirst(RegExp(r'^\.'), '');
    if (value == null ||
        RegExp(r'[\r\n;]').hasMatch('$name=$value') ||
        !(origin.host == host || origin.host.endsWith('.$host'))) {
      return;
    }
    final cookie = _SessionCookie(
        name, value, host, origin.host, path ?? '/', secure, expires);
    _cookies[cookie.key] = cookie;
  }

  void replaceFromWebView(List<Cookie> cookies, Uri origin, DateTime now) {
    clear();
    for (final cookie in cookies) {
      _store(
          cookie.name,
          cookie.value,
          cookie.domain,
          cookie.path,
          cookie.isSecure ?? origin.scheme == 'https',
          cookie.expiresDate != null && cookie.expiresDate! > 0
              ? DateTime.fromMillisecondsSinceEpoch(cookie.expiresDate!)
              : now.add(sessionLifetime),
          origin);
    }
  }

  void updateFromHttp(List<io.Cookie> cookies, Uri origin, DateTime now) {
    for (final cookie in cookies) {
      final defaultPath = origin.path.lastIndexOf('/') > 0
          ? origin.path.substring(0, origin.path.lastIndexOf('/'))
          : '/';
      _store(
          cookie.name,
          cookie.value,
          cookie.domain,
          cookie.path ?? defaultPath,
          cookie.secure,
          cookie.maxAge != null
              ? now.add(Duration(seconds: cookie.maxAge!.clamp(-1, 3153600000)))
              : cookie.expires ?? now.add(sessionLifetime),
          origin);
    }
  }

  String header(Uri target, DateTime now) {
    _cookies.removeWhere((_, cookie) => !cookie.expires.isAfter(now));
    final matching = _cookies.values
        .where((cookie) =>
            target.host == cookie.originHost &&
            (target.host == cookie.domain ||
                target.host.endsWith('.${cookie.domain}')) &&
            (!cookie.secure || target.scheme == 'https') &&
            (target.path == cookie.path ||
                target.path.startsWith(cookie.path.endsWith('/')
                    ? cookie.path
                    : '${cookie.path}/')))
        .toList()
      ..sort((a, b) => b.path.length.compareTo(a.path.length));
    return matching
        .map((cookie) => '${cookie.name}=${cookie.value}')
        .join('; ');
  }
}
