part of 'parser_service.dart';

class _ParserFetchContext {
  final Stopwatch elapsed = Stopwatch()..start();
  final Duration budget;
  bool closed = false;
  ParserFetchResult? latest;
  void Function()? abortHttp;
  void Function()? abortWebView;
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
    Future<ParserFetchResult> fetch() async {
      await _parserLog('Парсер: Старт отримання графіків (HTTP / WebView)');
      if (!context.active) return context.fallback;
      final allowBrowser = await _fetchWithHttpClient(context);
      if (!context.active ||
          context.latest?.schedules.isNotEmpty == true ||
          !allowBrowser) {
        return context.fallback;
      }
      await _parserLog('Парсер: HTTP не вдалося, запуск WebView');
      if (!context.active) return context.fallback;
      try {
        return await _fetchWithWebView(context);
      } catch (error) {
        _parserDiagnostic('Помилка WebView (${error.runtimeType})');
        return context.fallback;
      }
    }

    try {
      return await fetch().timeout(_policy.totalTimeout, onTimeout: () {
        context.close();
        _parserDiagnostic('Вичерпано загальний час отримання графіків '
            '(${_policy.totalTimeout.inSeconds} с)');
        return context.fallback;
      });
    } finally {
      context.close();
    }
  }

  Future<bool> _waitBeforeRetry(
      _ParserFetchContext context, Duration delay) async {
    if (!context.active || delay >= context.remaining) return false;
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
    final client = _httpClientFactory();
    client.userAgent = _httpUserAgent ?? ParserService._fallbackHttpUserAgent;
    client.connectionTimeout = _policy.connectionTimeout;
    context.abortHttp = () => client.close(force: true);
    final deadline =
        Timer(_policy.httpTimeout, () => client.close(force: true));
    try {
      await _parserLog('Парсер: Старт прямого HTTP запиту (спроба $attempt)');
      if (!context.active) {
        return const _ParserHttpAttempt(_HttpDisposition.unavailable);
      }
      final request = await client.getUrl(_target);
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
      if (cookies.isNotEmpty) request.headers.set('Cookie', cookies);
      final response = await request.close();
      if (!context.active) {
        return const _ParserHttpAttempt(_HttpDisposition.unavailable);
      }
      await _parserLog(
          'Парсер HTTP: Код відповіді ${response.statusCode} (спроба $attempt)',
          level: response.statusCode == 200 ? 'INFO' : 'WARN');
      if (response.statusCode == 429) {
        return _ParserHttpAttempt(_HttpDisposition.rateLimited,
            retryAfter: ParserFetchPolicy.retryAfter(
                response.headers.value('retry-after'), DateTime.now()));
      }
      if (response.statusCode == 403) {
        _cookies.clear();
        return const _ParserHttpAttempt(_HttpDisposition.challenge);
      }
      if (response.statusCode != 200) {
        return _ParserHttpAttempt(
            response.statusCode >= 500 || response.statusCode == 408
                ? _HttpDisposition.retry
                : _HttpDisposition.unavailable);
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        if (!context.active) {
          return const _ParserHttpAttempt(_HttpDisposition.unavailable);
        }
        if (bytes.length + chunk.length > 2 * 1024 * 1024) {
          throw const FormatException('DTEK response exceeds 2 MiB');
        }
        bytes.addAll(chunk);
      }
      final html = utf8.decode(bytes);
      if (!context.active) {
        return const _ParserHttpAttempt(_HttpDisposition.unavailable);
      }
      _cookies.updateFromHttp(response.cookies, _target, DateTime.now());
      await _parserLog(
          'Парсер HTTP: HTML успішно отримано (${bytes.length} байт)');
      if (ParserService.isBotChallengeHtml(html)) {
        await _parserLog('Парсер HTTP: Отримано сторінку захисту WAF',
            level: 'WARN');
        return const _ParserHttpAttempt(_HttpDisposition.challenge);
      }
      final json = extractJsonFromHtml(html);
      if (json.isEmpty && EmergencyStatusParser.parse(html) == null) {
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
    WebViewEnvironment? environment;
    try {
      environment = await _getWebViewEnvironment();
    } catch (error) {
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
        await webView.dispose().timeout(_policy.controllerTimeout);
      } catch (error) {
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
        }

        await read().timeout(_policy.cookieTimeout);
      } catch (error) {
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
        _parserDiagnostic(
            reloadCount >= _policy.maxReloads
                ? 'WebView: Вичерпано ліміт перезавантажень ($reloadCount)'
                : 'WebView: Час очікування повтору перевищує залишок бюджету',
            level: AppLogLevel.warning);
        finish();
        return;
      }
      final token = generation;
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
          await controller
              .loadUrl(urlRequest: freshRequest())
              .timeout(_policy.controllerTimeout);
        } catch (error) {
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
      String? parsedJson;
      String? parsedHtml;
      await _parserLog(
          'Парсер WebView: Сторінку завантажено; перевіряємо дані груп');
      for (var attempt = 0;
          attempt < _policy.pollAttempts && current(token);
          attempt++) {
        try {
          final value = await controller.evaluateJavascript(source: '''
JSON.stringify({
  fact: typeof DisconSchedule !== 'undefined' ? DisconSchedule.fact : null,
  html: document.documentElement.outerHTML,
  url: location.href,
  fromCache: (() => {
    const entry = performance.getEntriesByType('navigation')[0];
    return !!entry && (entry.deliveryType === 'cache' || entry.workerStart > 0 ||
      (entry.transferSize === 0 && entry.decodedBodySize > 0));
  })()
})
''').timeout(_policy.controllerTimeout);
          if (!current(token)) return;
          final capture = ParserService.decodeRuntimeCapture(value);
          if (capture.url != null &&
              !ParserFetchPolicy.isScheduleUrl(
                  Uri.parse(capture.url!), _target)) {
            return;
          }
          if (capture.fromCache) {
            await _parserLog(
                'Парсер WebView: Кешована відповідь не підтверджує '
                'актуальний графік або екстрений статус',
                level: 'WARN');
            if (current(token)) recover(controller, _policy.recoveryDelay);
            return;
          }
          final html = capture.html;
          final protection = html == null
              ? ParserPageProtection.none
              : ParserProtection.classify(html);
          if (protection == ParserPageProtection.blocked) {
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
          _parserDiagnostic(
              'Не вдалося налаштувати навігацію WebView (${error.runtimeType})');
          finish();
        }
      },
      onLoadStart: (_, url) {
        if (closed) return;
        generation++;
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
        finish();
      },
    );
    context.abortWebView = () => finish();
    webViewTimer = Timer(_policy.webViewTimeout, () {
      _parserDiagnostic(
          'Тайм-аут WebView (${_policy.webViewTimeout.inSeconds} с) '
          '— сторінку або дані не отримано');
      finish();
    });
    try {
      // A timeout cannot cancel platform creation. Dispose again when a late
      // run finishes, even if the fetch has already returned to its callers.
      unawaited(webView.run().then((_) async {
        running = true;
        if (closed) await dispose();
      }, onError: (Object error, StackTrace stack) {
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
