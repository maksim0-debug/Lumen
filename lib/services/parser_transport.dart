part of 'parser_service.dart';

class _ParserFetchContext {
  final Stopwatch elapsed = Stopwatch()..start();
  final Duration budget;
  bool closed = false;
  ParserFetchResult? latest;
  void Function()? abortHttp;
  void Function()? abortWebView;
  final AndroidDiagnosticTrace? diagnostic = AndroidFetchDiagnostics.current;
  String phase = 'start';
  String reason = 'no_valid_schedule';
  int httpAttempts = 0;
  int reloads = 0;
  bool webViewStarted = false;
  _ParserFetchContext(this.budget);
  Duration get remaining => budget - elapsed.elapsed;
  bool get active => !closed && remaining > Duration.zero;
  void close() {
    if (closed) return;
    closed = true;
    abortHttp?.call();
    abortWebView?.call();
    abortHttp = null;
    abortWebView = null;
    elapsed.stop();
  }

  void retain(ParserFetchResult result) {
    latest = result.retainEmergencyFrom(latest);
  }

  ParserFetchResult get fallback => latest ?? const ParserFetchResult({}, null);

  void event(String stage, Map<String, Object?> fields,
      {AppLogLevel level = AppLogLevel.info}) {
    phase = stage;
    diagnostic?.event(
        stage,
        {
          'fetchElapsedMs': elapsed.elapsedMilliseconds,
          'remainingMs':
              remaining.inMilliseconds.clamp(0, budget.inMilliseconds),
          ...fields,
        },
        level: level);
  }
}

enum _HttpDisposition { parsed, challenge, retry, unavailable, rateLimited }

class _ParserHttpAttempt {
  final _HttpDisposition disposition;
  final Duration? retryAfter;
  const _ParserHttpAttempt(this.disposition, {this.retryAfter});
}

extension _ParserTransport on ParserService {
  // Diagnostics must reach the application's log page as well as DevTools.
  // Persist asynchronously so a failure/timeout does not prolong the fetch.
  // Exception types provide context without exporting response/cookie contents.
  void _parserDiagnostic(String message,
      {AppLogLevel level = AppLogLevel.error}) {
    AppLogger.log('Парсер: $message',
        level: level, tag: 'Parser', persistToHistory: true);
  }

  Future<void> _parserLog(String message, {String level = 'INFO'}) async {
    if (Platform.isAndroid &&
        level != 'ERROR' &&
        AndroidFetchDiagnostics.current?.mode !=
            AndroidDiagnosticMode.verbose) {
      return;
    }
    try {
      await HistoryService()
          .logAction(message, level: level)
          .timeout(const Duration(seconds: 1));
    } catch (error) {
      AppLogger.w('Cannot persist parser log (${error.runtimeType})',
          tag: 'Parser');
    }
  }

  Future<ParserFetchResult> _executeFetchAllSchedules() async {
    final context = _ParserFetchContext(_policy.totalTimeout);
    context.event('fetch_start', {
      'target': AndroidFetchDiagnostics.safeUrl(_target),
      'totalBudgetMs': _policy.totalTimeout.inMilliseconds,
      'httpBudgetMs': _policy.httpTimeout.inMilliseconds,
      'webViewBudgetMs': _policy.webViewTimeout.inMilliseconds,
      'controllerBudgetMs': _policy.controllerTimeout.inMilliseconds,
      'pollAttemptsLimit': _policy.pollAttempts,
      'reloadLimit': _policy.maxReloads,
    });
    Future<ParserFetchResult> fetch() async {
      await _parserLog('Парсер: Старт отримання графіків (HTTP / WebView)');
      if (!context.active || !await _hasNetwork(context)) {
        return context.fallback;
      }
      final allowBrowser = await _fetchWithHttpClient(context);
      if (!context.active ||
          context.latest?.schedules.isNotEmpty == true ||
          !allowBrowser) {
        return context.fallback;
      }
      if (!await _hasNetwork(context)) return context.fallback;
      await _parserLog('Парсер: HTTP не вдалося, запуск WebView');
      context.event('webview_fallback', {'httpOutcome': context.reason});
      if (!context.active) return context.fallback;
      try {
        return await _fetchWithWebView(context);
      } catch (error) {
        context.reason = 'webview_exception';
        context.event(
            'webview_exception', AndroidFetchDiagnostics.errorFields(error),
            level: AppLogLevel.error);
        _parserDiagnostic('Помилка WebView (${error.runtimeType})');
        return context.fallback;
      }
    }

    try {
      return await fetch().timeout(_policy.totalTimeout, onTimeout: () {
        context.reason = 'total_budget_exhausted';
        context.event('fetch_timeout', {'interruptedStage': context.phase},
            level: AppLogLevel.error);
        context.close();
        _parserDiagnostic('Вичерпано загальний час отримання графіків '
            '(${_policy.totalTimeout.inSeconds} с)');
        return context.fallback;
      });
    } finally {
      context.event('fetch_end', {
        'outcome': context.latest?.schedules.isNotEmpty == true
            ? 'schedule_received'
            : context.latest?.emergency != null
                ? 'emergency_only'
                : 'no_schedule',
        'reason': context.reason,
        'groups': context.latest?.schedules.length ?? 0,
        'httpAttempts': context.httpAttempts,
        'webViewStarted': context.webViewStarted,
        'reloads': context.reloads,
      });
      context.close();
    }
  }

  Future<bool> _hasNetwork(_ParserFetchContext context) async {
    final probe = _networkAvailable;
    if (probe == null) return true;
    bool? available;
    try {
      available = await probe().timeout(const Duration(milliseconds: 300));
    } catch (error) {
      context.event('network_state_unavailable',
          AndroidFetchDiagnostics.errorFields(error),
          level: AppLogLevel.warning);
    }
    if (available != false) return true;
    context.reason = 'network_unavailable';
    context.event('network_unavailable', {}, level: AppLogLevel.warning);
    return false;
  }

  Future<bool> _waitBeforeRetry(
      _ParserFetchContext context, Duration delay) async {
    if (!context.active || delay >= context.remaining) {
      context
          .event('retry_not_enough_budget', {'delayMs': delay.inMilliseconds});
      return false;
    }
    context.event('retry_wait', {'delayMs': delay.inMilliseconds});
    await Future<void>.delayed(delay);
    return context.active;
  }

  Future<bool> _fetchWithHttpClient(_ParserFetchContext context) async {
    final blockedUntil = _retryNotBefore;
    if (blockedUntil != null && blockedUntil.isAfter(DateTime.now())) {
      if (!await _waitBeforeRetry(
          context, blockedUntil.difference(DateTime.now()))) {
        return false;
      }
    }
    for (var attempt = 1; attempt <= 2 && context.active; attempt++) {
      final response =
          await _singleDirectHttpRequest(context, attempt: attempt);
      if (!context.active) return false;
      if (context.latest?.schedules.isNotEmpty == true) return false;
      if (response.disposition == _HttpDisposition.rateLimited) {
        final delay = response.retryAfter ?? _policy.rateLimitDelay;
        _retryNotBefore = DateTime.now().add(delay);
        await _parserLog(
            'Парсер HTTP: Обмеження частоти запитів; '
            'наступна спроба не раніше ніж через ${delay.inSeconds} с',
            level: 'WARN');
        if (attempt == 2 || !await _waitBeforeRetry(context, delay)) {
          return false;
        }
        continue;
      }
      _retryNotBefore = null;
      if (response.disposition == _HttpDisposition.retry &&
          !await _hasNetwork(context)) {
        return false;
      }
      if (response.disposition == _HttpDisposition.challenge ||
          response.disposition == _HttpDisposition.unavailable) {
        return true;
      }
      if (attempt < 2 &&
          !await _waitBeforeRetry(context, _policy.httpRetryDelay)) {
        return false;
      }
      if (attempt < 2) {
        await _parserLog(
            'Парсер HTTP: Повторна спроба після тимчасової помилки');
      }
    }
    return context.active;
  }

  Future<_ParserHttpAttempt> _singleDirectHttpRequest(
      _ParserFetchContext context,
      {required int attempt}) async {
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    context.httpAttempts++;
    final attemptElapsed = Stopwatch()..start();
    var httpPhase = 'connect';
    var deadlineFired = false;
    int? status;
    var receivedBytes = 0;
    final client = _httpClientFactory();
    client.userAgent = _httpUserAgent ?? ParserService._fallbackHttpUserAgent;
    client.connectionTimeout = _policy.connectionTimeout;
    context.abortHttp = () => client.close(force: true);
    final deadline = Timer(_policy.httpTimeout, () {
      deadlineFired = true;
      context.event(
          'http_deadline',
          {
            'attempt': attempt,
            'httpPhase': httpPhase,
            'attemptElapsedMs': attemptElapsed.elapsedMilliseconds,
          },
          level: AppLogLevel.warning);
      client.close(force: true);
    });
    try {
      context.event('http_start', {
        'attempt': attempt,
        'userAgentSource': _httpUserAgent == null ? 'fallback' : 'webview',
      });
      await _parserLog('Парсер: Старт прямого HTTP запиту (спроба $attempt)');
      if (!context.active) {
        return const _ParserHttpAttempt(_HttpDisposition.unavailable);
      }
      final request = await client.getUrl(_target);
      httpPhase = 'response_headers';
      request.headers
          .set('Accept', 'text/html,application/xhtml+xml,*/*;q=0.8');
      request.headers.set('Accept-Language', 'uk-UA,uk;q=0.9,en;q=0.7');
      request.headers.set('Cache-Control', 'no-cache, no-store');
      request.headers.set('Sec-Fetch-Dest', 'document');
      request.headers.set('Sec-Fetch-Mode', 'navigate');
      request.headers.set('Sec-Fetch-Site', 'none');
      request.headers.set('Sec-Fetch-User', '?1');
      request.headers.set('Upgrade-Insecure-Requests', '1');
      // Do not attach fixed Chromium/Windows client hints: the captured UA may
      // belong to Android, another browser version, or a non-Chromium engine.
      final cookies = _cookies.header(_target, DateTime.now());
      context.event('http_connected', {
        'attempt': attempt,
        'attemptElapsedMs': attemptElapsed.elapsedMilliseconds,
        'cookiesPresent': cookies.isNotEmpty,
      });
      if (cookies.isNotEmpty) request.headers.set('Cookie', cookies);
      final response = await request.close();
      status = response.statusCode;
      context.event('http_response', {
        'attempt': attempt,
        'status': status,
        'attemptElapsedMs': attemptElapsed.elapsedMilliseconds,
        'declaredBytes': response.contentLength,
        'redirects': response.redirects.length,
      });
      if (!context.active) {
        return const _ParserHttpAttempt(_HttpDisposition.unavailable);
      }
      await _parserLog(
          'Парсер HTTP: Код відповіді ${response.statusCode} (спроба $attempt)',
          level: response.statusCode == 200 ? 'INFO' : 'WARN');
      if (response.statusCode == 429) {
        context.reason = 'http_rate_limited';
        return _ParserHttpAttempt(_HttpDisposition.rateLimited,
            retryAfter: ParserFetchPolicy.retryAfter(
                response.headers.value('retry-after'), DateTime.now()));
      }
      if (response.statusCode == 403) {
        context.reason = 'http_forbidden';
        _cookies.clear();
        return const _ParserHttpAttempt(_HttpDisposition.challenge);
      }
      if (response.statusCode != 200) {
        context.reason = 'http_status_${response.statusCode}';
        return _ParserHttpAttempt(
            response.statusCode >= 500 || response.statusCode == 408
                ? _HttpDisposition.retry
                : _HttpDisposition.unavailable);
      }
      final bytes = <int>[];
      httpPhase = 'response_body';
      await for (final chunk in response) {
        if (!context.active) {
          return const _ParserHttpAttempt(_HttpDisposition.unavailable);
        }
        if (bytes.length + chunk.length > 2 * 1024 * 1024) {
          throw const FormatException('DTEK response exceeds 2 MiB');
        }
        bytes.addAll(chunk);
        receivedBytes = bytes.length;
      }
      final html = utf8.decode(bytes);
      httpPhase = 'parse';
      if (!context.active) {
        return const _ParserHttpAttempt(_HttpDisposition.unavailable);
      }
      _cookies.updateFromHttp(response.cookies, _target, DateTime.now());
      await _parserLog(
          'Парсер HTTP: HTML успішно отримано (${bytes.length} байт)');
      final protection = ParserProtection.classify(html);
      context.event('http_body', {
        'attempt': attempt,
        'bytes': bytes.length,
        'protection': protection.name,
        'attemptElapsedMs': attemptElapsed.elapsedMilliseconds,
      });
      if (protection != ParserPageProtection.none) {
        context.reason = 'http_waf_${protection.name}';
        await _parserLog('Парсер HTTP: Отримано сторінку захисту WAF',
            level: 'WARN');
        return const _ParserHttpAttempt(_HttpDisposition.challenge);
      }
      final json = extractJsonFromHtml(html);
      if (json.isEmpty && EmergencyStatusParser.parse(html) == null) {
        context.reason = 'http_data_missing';
        await _parserLog(
            'Парсер HTTP: HTML отримано, але дані графіків '
            'та екстрений статус не знайдено',
            level: 'WARN');
        return const _ParserHttpAttempt(_HttpDisposition.retry);
      }
      if (json.isNotEmpty) {
        await _parserLog(
            'Парсер HTTP: Знайдено JSON графіків (${json.length} символів)');
      }
      final result = await parseFetchedPage(json,
          originalHtml: html,
          isCurrent: () => context.active,
          observedAt: _responseObservationTime(response, startedAt));
      if (!context.active) {
        return const _ParserHttpAttempt(_HttpDisposition.unavailable);
      }
      context.retain(result);
      context.reason = result.schedules.isNotEmpty
          ? 'http_success'
          : 'http_no_valid_schedule';
      if (result.schedules.isNotEmpty) {
        await _parserLog('Парсер: HTTP метод спрацював, повернення результату');
      } else {
        await _parserLog(
            'Парсер HTTP: Відповідь не містить повного валідного '
            'графіка; екстрений статус ${result.emergency == null ? 'не підтверджено' : 'перевірено'}',
            level: 'WARN');
      }
      return const _ParserHttpAttempt(_HttpDisposition.parsed);
    } catch (error) {
      final details = AndroidFetchDiagnostics.errorFields(error);
      if (context.active) {
        context.reason = deadlineFired
            ? 'http_deadline'
            : 'http_${details['errorCategory']}';
      }
      context.event(
          'http_error',
          {
            'attempt': attempt,
            'httpPhase': httpPhase,
            'deadlineFired': deadlineFired,
            'totalBudgetExpired': !context.active,
            'attemptElapsedMs': attemptElapsed.elapsedMilliseconds,
            'receivedBytes': receivedBytes,
            if (status != null) 'status': status,
            ...details,
          },
          level: AppLogLevel.error);
      _parserDiagnostic(
          'Помилка HTTP запиту (спроба $attempt, ${error.runtimeType})');
      return const _ParserHttpAttempt(_HttpDisposition.retry);
    } finally {
      deadline.cancel();
      client.close(force: true);
      context.abortHttp = null;
    }
  }

  Future<WebViewEnvironment?> _getWebViewEnvironment() async {
    if (!_windows) return null;
    Future<WebViewEnvironment?> create() async {
      if (_environmentFactory != null) return _environmentFactory!();
      final support = await getApplicationSupportDirectory();
      final directory = Directory(path.join(support.path, 'parser_webview'));
      await directory.create(recursive: true);
      return WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(userDataFolder: directory.path));
    }

    final pending = _environment ??= create();
    try {
      return await pending.timeout(_policy.controllerTimeout);
    } on TimeoutException {
      // Platform creation continues after a timeout; reuse its eventual result.
      rethrow;
    } catch (_) {
      if (identical(_environment, pending)) _environment = null;
      rethrow;
    }
  }

  Future<ParserFetchResult> _fetchWithWebView(
      _ParserFetchContext context) async {
    context.webViewStarted = true;
    context.event('webview_start', {});
    WebViewEnvironment? environment;
    try {
      environment = await _getWebViewEnvironment();
    } catch (error) {
      context.reason = 'webview_environment_error';
      context.event('webview_environment_error',
          AndroidFetchDiagnostics.errorFields(error),
          level: AppLogLevel.error);
      _parserDiagnostic(
          'Не вдалося створити середовище WebView (${error.runtimeType})');
      return context.fallback;
    }
    if (!context.active) return context.fallback;
    final completion = Completer<ParserFetchResult>();
    late final HeadlessInAppWebView webView;
    Timer? recoveryTimer;
    Timer? webViewTimer;
    var closed = false;
    var running = false;
    var disposed = false;
    var generation = 0;
    var reloadCount = 0;
    int? httpError;
    Duration? rateLimitWait;
    var observedAt = DateTime.now().millisecondsSinceEpoch;

    bool current(int token) => !closed && context.active && token == generation;
    void cancelRecovery() {
      recoveryTimer?.cancel();
      recoveryTimer = null;
    }

    Future<void> dispose() async {
      if (!running || disposed) return;
      disposed = true;
      try {
        context.event('webview_dispose_start', {});
        await webView.dispose().timeout(_policy.controllerTimeout);
        context.event('webview_disposed', {});
      } catch (error) {
        context.event(
            'webview_dispose_error', AndroidFetchDiagnostics.errorFields(error),
            level: AppLogLevel.warning);
        _parserDiagnostic('Не вдалося звільнити WebView (${error.runtimeType})',
            level: AppLogLevel.warning);
      }
    }

    void finish([ParserFetchResult? result]) {
      if (closed) return;
      closed = true;
      generation++;
      cancelRecovery();
      webViewTimer?.cancel();
      completion.complete(result ?? context.fallback);
    }

    URLRequest freshRequest() => URLRequest(
        url: WebUri(_target.toString()),
        headers: {'Cache-Control': 'no-cache, no-store', 'Pragma': 'no-cache'});

    Future<void> captureSession(
        InAppWebViewController controller, int token) async {
      var reading = true;
      try {
        Future<void> read() async {
          final cookies =
              await CookieManager.instance(webViewEnvironment: environment)
                  .getCookies(url: WebUri(_target.toString()));
          if (!reading || !current(token)) return;
          final userAgent = await controller.evaluateJavascript(
              source: 'navigator.userAgent');
          if (!reading || !current(token)) return;
          _cookies.replaceFromWebView(cookies, _target, DateTime.now());
          if (userAgent is String && userAgent.isNotEmpty) {
            _httpUserAgent = userAgent;
          }
          context.event('webview_session_captured', {
            'cookieCount': cookies.length,
            'userAgentPresent': userAgent is String && userAgent.isNotEmpty,
          });
        }

        await read().timeout(_policy.cookieTimeout);
      } catch (error) {
        context.event(
            'webview_session_error', AndroidFetchDiagnostics.errorFields(error),
            level: AppLogLevel.warning);
        _parserDiagnostic(
            'Не вдалося отримати cookies або User-Agent '
            '(${error.runtimeType}); повертаємо перевірені графіки',
            level: AppLogLevel.warning);
      } finally {
        reading = false;
      }
    }

    void recover(InAppWebViewController controller, Duration delay) {
      if (closed || !context.active || recoveryTimer != null) return;
      if (reloadCount >= _policy.maxReloads || delay >= context.remaining) {
        context.reason = reloadCount >= _policy.maxReloads
            ? 'webview_reload_limit'
            : 'webview_retry_exceeds_budget';
        context.event(
            'webview_recovery_skipped',
            {
              'reason': context.reason,
              'delayMs': delay.inMilliseconds,
              'reloads': reloadCount,
            },
            level: AppLogLevel.warning);
        _parserDiagnostic(
            reloadCount >= _policy.maxReloads
                ? 'WebView: Вичерпано ліміт перезавантажень ($reloadCount)'
                : 'WebView: Час очікування повтору перевищує залишок бюджету',
            level: AppLogLevel.warning);
        finish();
        return;
      }
      final token = generation;
      context.event('webview_recovery_wait', {
        'delayMs': delay.inMilliseconds,
        'reloads': reloadCount,
        'reason': context.reason,
      });
      recoveryTimer = Timer(delay, () async {
        recoveryTimer = null;
        if (!current(token)) return;
        generation++; // Cancel every capture belonging to the old document.
        final navigationToken = generation;
        await _parserLog(
            'Парсер WebView: Перезавантаження після захисту '
            '(${reloadCount + 1}/${_policy.maxReloads})',
            level: 'WARN');
        if (!current(navigationToken)) return;
        try {
          reloadCount++;
          context.reloads = reloadCount;
          context.event('webview_reload', {'reload': reloadCount});
          await controller
              .loadUrl(urlRequest: freshRequest())
              .timeout(_policy.controllerTimeout);
        } catch (error) {
          context.reason = 'webview_reload_error';
          context.event('webview_reload_error',
              AndroidFetchDiagnostics.errorFields(error),
              level: AppLogLevel.error);
          _parserDiagnostic(
              'Помилка перезавантаження WebView (${error.runtimeType})');
          finish();
        }
      });
    }

    Future<void> poll(InAppWebViewController controller, WebUri? url) async {
      if (closed ||
          !context.active ||
          url == null ||
          !ParserFetchPolicy.isScheduleUrl(
              Uri.parse(url.toString()), _target)) {
        return;
      }
      cancelRecovery();
      final token = ++generation;
      final elapsed = Stopwatch()..start();
      context.event('webview_load_stop', {
        'generation': generation,
        'scheduleUrl': true,
      });
      String? parsedJson;
      String? parsedHtml;
      String? capturedHtml;
      ParserPageProtection? capturedProtection;
      await _parserLog(
          'Парсер WebView: Сторінку завантажено; перевіряємо дані груп');
      for (var attempt = 0;
          attempt < _policy.pollAttempts && current(token);
          attempt++) {
        try {
          final value = await controller.evaluateJavascript(source: '''
(() => {
  const html = document.documentElement.outerHTML;
  const key = '__lumenReadOnlyCapture';
  const generation = '$token';
  const previous = window[key];
  const unchanged = !!previous && previous.generation === generation && previous.html === html;
  window[key] = {generation, html};
  return JSON.stringify({
    fact: typeof DisconSchedule !== 'undefined' ? DisconSchedule.fact : null,
    html: unchanged ? null : html,
    htmlUnchanged: unchanged,
    url: location.href,
    fromCache: (() => {
      const entry = performance.getEntriesByType('navigation')[0];
      return !!entry && (entry.deliveryType === 'cache' || entry.workerStart > 0 ||
        (entry.transferSize === 0 && entry.decodedBodySize > 0));
    })()
  });
})()
''').timeout(_policy.controllerTimeout);
          if (!current(token)) return;
          final capture = ParserService.decodeRuntimeCapture(value);
          if (capture.url != null &&
              !ParserFetchPolicy.isScheduleUrl(
                  Uri.parse(capture.url!), _target)) {
            context.reason = 'webview_unexpected_url';
            context.event('webview_unexpected_url', {},
                level: AppLogLevel.warning);
            return;
          }
          if (capture.fromCache) {
            context.reason = 'webview_cached_page';
            context.event('webview_cached_page', {'pollAttempt': attempt + 1},
                level: AppLogLevel.warning);
            await _parserLog(
                'Парсер WebView: Кешована відповідь не підтверджує '
                'актуальний графік або екстрений статус',
                level: 'WARN');
            if (current(token)) recover(controller, _policy.recoveryDelay);
            return;
          }
          if (capture.htmlUnchanged && capturedHtml == null) {
            throw const FormatException('Missing previous runtime HTML');
          }
          final html = capture.htmlUnchanged ? capturedHtml : capture.html;
          final protection = capture.htmlUnchanged
              ? capturedProtection!
              : html == null
                  ? ParserPageProtection.none
                  : ParserProtection.classify(html);
          capturedHtml = html;
          capturedProtection = protection;
          if (attempt == 0 || (attempt + 1) % 6 == 0) {
            context.event('webview_capture', {
              'pollAttempt': attempt + 1,
              'htmlChars': html?.length ?? 0,
              'htmlReused': capture.htmlUnchanged,
              'runtimeDataPresent':
                  capture.json != 'null' && capture.json.isNotEmpty,
              'protection': protection.name,
              'httpStatus': httpError,
              'documentElapsedMs': elapsed.elapsedMilliseconds,
            });
          }
          if (protection == ParserPageProtection.blocked) {
            context.reason = 'webview_waf_blocked';
            await _parserLog(
                'Парсер WebView: Доступ заблоковано політикою сайту',
                level: 'WARN');
            if (current(token)) finish();
            return;
          }
          if (httpError == 429) {
            recover(controller, rateLimitWait ?? _policy.rateLimitDelay);
            return;
          }
          if (protection == ParserPageProtection.challenge ||
              httpError == 403) {
            context.reason = 'webview_waf_challenge';
            if (httpError == 403 || elapsed.elapsed >= _policy.challengeGrace) {
              recover(controller, _policy.recoveryDelay);
              return;
            }
          } else {
            var json = capture.json;
            final fromRuntime = json != 'null' && json.isNotEmpty;
            if (json == 'null' || json.isEmpty) {
              json = html == null ? '' : extractJsonFromHtml(html);
            }
            if (json.isNotEmpty ||
                (html != null && EmergencyStatusParser.parse(html) != null)) {
              // Runtime data may appear later. Poll for changes, but do not
              // repeatedly persist an identical status-only/invalid payload.
              if (parsedJson == json && parsedHtml == html) {
                await Future<void>.delayed(_policy.pollInterval);
                continue;
              }
              if (!current(token)) return;
              final result = await parseFetchedPage(json,
                  originalHtml: html,
                  observedAt: observedAt,
                  isCurrent: () => current(token));
              if (!current(token)) return;
              parsedJson = json;
              parsedHtml = html;
              context.retain(result);
              if (result.schedules.isNotEmpty) {
                context.reason = 'webview_success';
                context.event('webview_schedule_received', {
                  'groups': result.schedules.length,
                  'pollAttempt': attempt + 1,
                  'dataSource': fromRuntime ? 'runtime_js' : 'html',
                });
                await _parserLog(
                    'Парсер WebView: Отримано графіки для ${result.schedules.length} груп '
                    'з ${fromRuntime ? 'JS DisconSchedule' : 'HTML'} '
                    '(HTML: ${html?.length ?? 0} символів)');
                await captureSession(controller, token);
                if (current(token)) finish(context.fallback);
                return;
              }
            }
          }
        } catch (error) {
          if (!current(token)) return;
          context.reason = 'webview_read_error';
          context.event(
              'webview_read_error',
              {
                'pollAttempt': attempt + 1,
                ...AndroidFetchDiagnostics.errorFields(error),
              },
              level: AppLogLevel.error);
          _parserDiagnostic('WebView: Помилка читання сторінки '
              '(спроба ${attempt + 1}/${_policy.pollAttempts}, ${error.runtimeType})');
        }
        if (current(token) && (attempt + 1) % 6 == 0) {
          await _parserLog(
              'Парсер WebView: Спроба ${attempt + 1}/${_policy.pollAttempts} '
              '— повний валідний графік поки не отримано');
        }
        await Future<void>.delayed(_policy.pollInterval);
      }
      if (current(token)) {
        context.event(
            'webview_poll_exhausted',
            {
              'pollAttempts': _policy.pollAttempts,
              'lastReason': context.reason,
            },
            level: AppLogLevel.warning);
        context.reason = 'webview_poll_exhausted';
        _parserDiagnostic('WebView: Вичерпано ${_policy.pollAttempts} спроб '
            'очікування даних; повний валідний графік не отримано');
        finish();
      }
    }

    webView = HeadlessInAppWebView(
      webViewEnvironment: environment,
      // Start blank so Windows cache policy is installed before navigation.
      initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          isInspectable: kDebugMode,
          incognito: false,
          cacheEnabled: false,
          domStorageEnabled: true,
          databaseEnabled: true),
      onWebViewCreated: (controller) async {
        if (closed || !context.active) return;
        context.event('webview_created', {});
        try {
          if (_windows) {
            await controller.callDevToolsProtocolMethod(
                methodName: 'Network.setCacheDisabled',
                parameters: {
                  'cacheDisabled': true
                }).timeout(_policy.controllerTimeout);
            if (closed || !context.active) return;
            await controller.callDevToolsProtocolMethod(
                methodName: 'Network.setBypassServiceWorker',
                parameters: {
                  'bypass': true
                }).timeout(_policy.controllerTimeout);
          }
          if (!closed && context.active) {
            await controller
                .loadUrl(urlRequest: freshRequest())
                .timeout(_policy.controllerTimeout);
          }
        } catch (error) {
          context.reason = 'webview_navigation_error';
          context.event('webview_navigation_error',
              AndroidFetchDiagnostics.errorFields(error),
              level: AppLogLevel.error);
          _parserDiagnostic(
              'Не вдалося налаштувати навігацію WebView (${error.runtimeType})');
          finish();
        }
      },
      onLoadStart: (_, url) {
        if (closed) return;
        generation++;
        context.event('webview_load_start', {
          'generation': generation,
          'scheduleUrl': url != null &&
              ParserFetchPolicy.isScheduleUrl(
                  Uri.parse(url.toString()), _target),
        });
        cancelRecovery();
        httpError = null;
        rateLimitWait = null;
        observedAt = DateTime.now().millisecondsSinceEpoch;
      },
      onLoadStop: (controller, url) => unawaited(poll(controller, url)),
      onReceivedHttpError: (controller, request, response) async {
        if (closed ||
            !context.active ||
            request.isForMainFrame != true ||
            !ParserFetchPolicy.isScheduleUrl(
                Uri.parse(request.url.toString()), _target)) {
          return;
        }
        httpError = response.statusCode;
        context.reason = 'webview_http_${response.statusCode}';
        context.event('webview_http_error', {'status': response.statusCode},
            level: AppLogLevel.warning);
        if (response.statusCode == 429) {
          final headers = response.headers ?? const <String, String>{};
          final retryAfter = headers.entries
              .where((entry) => entry.key.toLowerCase() == 'retry-after');
          rateLimitWait = ParserFetchPolicy.retryAfter(
                  retryAfter.isEmpty ? null : retryAfter.first.value,
                  DateTime.now()) ??
              _policy.rateLimitDelay;
          _retryNotBefore = DateTime.now().add(rateLimitWait!);
        }
        final token = generation;
        await _parserLog(
            'Парсер WebView: Сервер відповів HTTP ${response.statusCode}',
            level: 'WARN');
        if (!current(token)) return;
        if (response.statusCode == 429) {
          recover(controller, rateLimitWait!);
        } else if (response.statusCode == 403) {
          recover(controller, _policy.recoveryDelay);
        } else {
          finish();
        }
      },
      onReceivedError: (_, request, error) {
        if (closed ||
            request.isForMainFrame != true ||
            error.type == WebResourceErrorType.CANCELLED ||
            !ParserFetchPolicy.isScheduleUrl(
                Uri.parse(request.url.toString()), _target)) {
          return;
        }
        _parserDiagnostic('WebView: Помилка мережі (${error.type})');
        context.reason = 'webview_network_${error.type}';
        context.event(
            'webview_network_error',
            {
              'webResourceError': error.type.toString(),
            },
            level: AppLogLevel.error);
        finish();
      },
    );
    context.abortWebView = () => finish();
    webViewTimer = Timer(_policy.webViewTimeout, () {
      context.reason = 'webview_deadline';
      context.event('webview_timeout', {'interruptedStage': context.phase},
          level: AppLogLevel.error);
      _parserDiagnostic(
          'Тайм-аут WebView (${_policy.webViewTimeout.inSeconds} с) '
          '— сторінку або дані не отримано');
      finish();
    });
    try {
      context.event('webview_platform_run', {});
      // A timeout cannot cancel platform creation. Dispose again when a late
      // run finishes, even if the fetch has already returned to its callers.
      unawaited(webView.run().then((_) async {
        running = true;
        context.event('webview_platform_ready', {'lateCompletion': closed});
        if (closed) await dispose();
      }, onError: (Object error, StackTrace stack) {
        if (context.active) context.reason = 'webview_startup_error';
        context.event(
            'webview_startup_error', AndroidFetchDiagnostics.errorFields(error),
            level: AppLogLevel.error);
        _parserDiagnostic('Помилка запуску WebView (${error.runtimeType})');
        finish();
      }));
      return await completion.future;
    } finally {
      context.abortWebView = null;
      finish();
      await dispose();
    }
  }
}
