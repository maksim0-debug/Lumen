import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'dtek_snapshot.dart';
import '../models/schedule_status.dart';
import 'app_logger.dart';
import 'history_service.dart';

class ParserFetchResult {
  final Map<String, FullSchedule> schedules;
  final String? html;
  const ParserFetchResult(this.schedules, this.html);
}

class ParserService {
  static final ParserService _instance = ParserService._internal();

  factory ParserService() => _instance;

  ParserService._internal();

  static const String _url = "https://www.dtek-krem.com.ua/ua/shutdowns";

  static const List<String> allGroups = [
    "GPV1.1",
    "GPV1.2",
    "GPV2.1",
    "GPV2.2",
    "GPV3.1",
    "GPV3.2",
    "GPV4.1",
    "GPV4.2",
    "GPV5.1",
    "GPV5.2",
    "GPV6.1",
    "GPV6.2",
  ];

  /// Returns the next or previous group in the cycle based on [direction] (+1 next, -1 previous).
  static String cycleGroup(String currentGroup, int direction) {
    if (direction == 0) return currentGroup;
    final currentIndex = allGroups.indexOf(currentGroup);
    final validIndex = currentIndex == -1 ? 0 : currentIndex;
    final newIndex = (validIndex + direction) % allGroups.length;
    final targetIndex = newIndex < 0 ? newIndex + allGroups.length : newIndex;
    return allGroups[targetIndex];
  }

  Future<ParserFetchResult>? _ongoingFetch;

  Future<void> init() async {}

  Future<Map<String, FullSchedule>> fetchAllSchedules() async {
    return (await fetchSnapshot()).schedules;
  }

  /// HTML and schedules belong to the same completed fetch, including coalesced callers.
  Future<ParserFetchResult> fetchSnapshot() async {
    if (_ongoingFetch != null) {
      AppLogger.d("⏳ Парсинг вже виконується, очікуємо спільний результат...",
          tag: 'Parser');
      return _ongoingFetch!;
    }

    _ongoingFetch = _executeFetchAllSchedules();
    try {
      return await _ongoingFetch!;
    } finally {
      _ongoingFetch = null;
    }
  }

  Future<ParserFetchResult> _executeFetchAllSchedules() async {
    // 1. Try fast direct HTTP request first (works in background, < 500ms)
    await HistoryService()
        .logAction("Парсер: Старт fetchAllSchedules (v4 direct)");
    final httpResult = await _fetchWithHttpClient();
    if (httpResult != null && httpResult.schedules.isNotEmpty) {
      await HistoryService()
          .logAction("Парсер: HTTP метод спрацював, повернення результату");
      return httpResult;
    }

    AppLogger.i("🌍 HTTP не спрацював, запускаємо Headless WebView...",
        tag: 'Parser');
    await HistoryService().logAction("Парсер: HTTP не вдалося, запуск WebView");

    AppLogger.i("🚀 Запуск Headless браузера (Hybrid)...", tag: 'Parser');
    final completer = Completer<ParserFetchResult>();
    HeadlessInAppWebView? webView;
    bool isDisposed = false;
    Timer? fallbackTimeoutTimer;

    void completeOnce(ParserFetchResult result) {
      if (!completer.isCompleted) {
        completer.complete(result);
      }
    }

    Future<void> safeDispose() async {
      fallbackTimeoutTimer?.cancel();
      fallbackTimeoutTimer = null;
      if (isDisposed) return;
      isDisposed = true;
      try {
        final wv = webView;
        webView = null;
        await wv?.dispose().timeout(const Duration(seconds: 3));
      } catch (_) {}
    }

    int loadStopGeneration = 0;

    webView = HeadlessInAppWebView(
      // Завантажуємо сторінку графіків напряму без зайвого переходу з головної
      initialUrlRequest: URLRequest(url: WebUri(_url)),
      initialSettings: InAppWebViewSettings(
        isInspectable: kDebugMode,
        javaScriptEnabled: true,
        incognito: false,
        cacheEnabled: true,
        domStorageEnabled: true,
        databaseEnabled: true,
        userAgent:
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
      ),
      // Приховуємо ознаки автоматизації (navigator.webdriver)
      initialUserScripts: UnmodifiableListView([
        UserScript(
          source:
              "Object.defineProperty(navigator, 'webdriver', {get: () => undefined}); if (!window.chrome) { window.chrome = { runtime: {} }; }",
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      ]),
      onReceivedHttpError: (controller, request, errorResponse) async {
        final reqUrl = request.url.toString();
        final statusCode = errorResponse.statusCode;
        if (reqUrl == _url || reqUrl.contains('/ua/shutdowns')) {
          AppLogger.w("⛔ WebView HTTP помилка: $statusCode для $reqUrl",
              tag: 'Parser');
          await HistoryService().logAction(
              "Парсер WebView помилка: HTTP $statusCode ($reqUrl)",
              level: "ERROR");
        }
      },
      onReceivedError: (controller, request, error) async {
        AppLogger.e(
            "⛔ WebView помилка мережі: ${error.type} — ${error.description}",
            tag: 'Parser');
        await HistoryService().logAction(
            "Парсер WebView помилка мережі: ${error.type} — ${error.description}",
            level: "ERROR");
      },
      onLoadStop: (controller, url) async {
        if (isDisposed || completer.isCompleted) return;
        final currentGen = ++loadStopGeneration;
        final currentUrl = url?.toString() ?? '';

        AppLogger.d(
            "📊 Сторінка графіків завантажена ($currentUrl, покоління #$currentGen). Шукаємо дані...",
            tag: 'Parser');

        for (int i = 0; i < 24; i++) {
          if (isDisposed ||
              completer.isCompleted ||
              currentGen != loadStopGeneration) {
            return;
          }

          try {
            final jsResult = await controller.evaluateJavascript(
                source:
                    "typeof DisconSchedule !== 'undefined' && DisconSchedule.fact ? JSON.stringify(DisconSchedule.fact) : 'null'");

            String jsonString = "";

            if (jsResult != null &&
                jsResult != "null" &&
                jsResult.toString().length > 100) {
              AppLogger.i("✅ Дані знайдено через JS змінну!", tag: 'Parser');
              jsonString = jsResult.toString();
            } else {
              final html = await controller.evaluateJavascript(
                  source: "document.documentElement.outerHTML");
              if (html != null) {
                jsonString = extractJsonFromHtml(html.toString());
                if (jsonString.isNotEmpty) {
                  AppLogger.i("✅ Дані знайдено через пошук у HTML!",
                      tag: 'Parser');
                }
              }
            }

            if (jsonString.isNotEmpty && jsonString.length > 100) {
              var schedules = await _parseAndSaveAllGroups(jsonString);
              if (isDisposed ||
                  completer.isCompleted ||
                  currentGen != loadStopGeneration) {
                return;
              }
              if (schedules.schedules.isNotEmpty) {
                completeOnce(schedules);
                await safeDispose();
                return;
              }
            } else {
              AppLogger.d("Спроба ${i + 1}/24: Дані поки не знайдено...",
                  tag: 'Parser');
              if ((i + 1) % 6 == 0) {
                await HistoryService()
                    .logAction("Парсер: спроба ${i + 1}/24 - дані не знайдено");
              }

              // Debug-логування на першій спробі
              if (kDebugMode && i == 0 && !isDisposed) {
                try {
                  final debugHtml = await controller.evaluateJavascript(
                      source: "document.documentElement.outerHTML");
                  if (debugHtml != null) {
                    String snippet = debugHtml.toString();
                    if (snippet.length > 500) {
                      snippet = snippet.substring(0, 500);
                    }
                    AppLogger.d("HTML Snippet:\n$snippet...",
                        tag: 'Parser-DEBUG');

                    if (isBotChallengeHtml(snippet)) {
                      AppLogger.w("⚠️ Виявлено захист Imperva/Cloudflare!",
                          tag: 'Parser-DEBUG');
                      await HistoryService().logAction(
                          "WebView потрапив на екран захисту Imperva/Cloudflare",
                          level: "WARN");
                    }
                  }
                } catch (_) {}
              }
            }
          } catch (e) {
            AppLogger.e("Помилка ітерації", tag: 'Parser', error: e);
            await HistoryService()
                .logAction("Парсер помилка ітерації: $e", level: "ERROR");
          }
          await Future.delayed(const Duration(milliseconds: 500));
        }

        if (!completer.isCompleted && currentGen == loadStopGeneration) {
          AppLogger.w("❌ Тайм-аут", tag: 'Parser');
          completeOnce(const ParserFetchResult({}, null));
          await HistoryService()
              .logAction("Парсер: Тайм-аут очікування даних", level: "ERROR");
          await safeDispose();
        }
      },
    );

    // Страховочний тайм-аут: 25 секунд на весь процес WebView
    fallbackTimeoutTimer = Timer(const Duration(seconds: 25), () async {
      if (!completer.isCompleted) {
        AppLogger.e("❌ Глобальний тайм-аут WebView (25 сек)", tag: 'Parser');
        completeOnce(const ParserFetchResult({}, null));
        await HistoryService().logAction(
            "Парсер: Глобальний тайм-аут WebView 25 сек",
            level: "ERROR");
        await safeDispose();
      }
    });

    try {
      await webView?.run().timeout(const Duration(seconds: 25));
    } catch (e) {
      AppLogger.e("❌ Помилка запуску WebView", tag: 'Parser', error: e);
      completeOnce(const ParserFetchResult({}, null));
      await HistoryService()
          .logAction("Парсер: Помилка запуску WebView: $e", level: "ERROR");
      await safeDispose();
      return const ParserFetchResult({}, null);
    }

    return completer.future;
  }

  /// Допоміжний метод: встановлює стандартні заголовки браузера
  void _setHttpHeaders(HttpClientRequest request, {String? referer}) {
    request.headers.set('Accept',
        'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7');
    request.headers
        .set('Accept-Language', 'uk,ru-RU;q=0.9,ru;q=0.8,en-US;q=0.7,en;q=0.6');
    request.headers.set('Accept-Encoding', 'gzip, deflate');
    request.headers.set('Cache-Control', 'max-age=0');
    request.headers.set('Connection', 'keep-alive');
    request.headers.set('Sec-Fetch-Dest', 'document');
    request.headers.set('Sec-Fetch-Mode', 'navigate');
    request.headers.set('Sec-Fetch-User', '?1');
    request.headers.set('Upgrade-Insecure-Requests', '1');
    request.headers.set('sec-ch-ua',
        '"Not_A Brand";v="8", "Chromium";v="120", "Google Chrome";v="120"');
    request.headers.set('sec-ch-ua-mobile', '?0');
    request.headers.set('sec-ch-ua-platform', '"Windows"');
    if (referer != null) {
      request.headers.set('Referer', referer);
      request.headers.set('Sec-Fetch-Site', 'same-origin');
    } else {
      request.headers.set('Sec-Fetch-Site', 'none');
    }
  }

  /// Перевірка чи HTML є антибот-челенджем (Imperva Incapsula / Cloudflare)
  static bool isBotChallengeHtml(String html) {
    if (html.isEmpty) return false;
    if (html.contains('_Incapsula_Resource') ||
        html.contains('cf-browser-verification') ||
        html.contains('Just a moment...')) {
      return true;
    }
    if (html.length < 500 && html.contains('robots')) {
      return true;
    }
    return false;
  }

  /// Прямий швидкий HTTP-запит з інтелектуальним авто-ретраєм
  Future<ParserFetchResult?> _fetchWithHttpClient() async {
    // Спроба 1: Прямий запит
    final firstAttempt = await _singleDirectHttpRequest(attempt: 1);
    if (firstAttempt.result != null &&
        firstAttempt.result!.schedules.isNotEmpty) {
      return firstAttempt.result;
    }

    // Якщо натрапили на антибот-челендж WAF (Cloudflare/Imperva),
    // повторний звичайний HTTP-запит не допоможе — відразу переходимо до Headless WebView
    if (firstAttempt.wasChallenge) {
      AppLogger.i(
          "Парсер: Виявлено WAF-челендж, перемикаємось на Headless WebView...",
          tag: 'Parser');
      return null;
    }

    // Швидкий ретрай через 700мс для мережевих розривів або 5xx помилок сервера
    AppLogger.d("Парсер: Пауза 700мс перед швидким повторним HTTP-запитом...",
        tag: 'Parser');
    await Future.delayed(const Duration(milliseconds: 700));

    final retryAttempt = await _singleDirectHttpRequest(attempt: 2);
    if (retryAttempt.result != null &&
        retryAttempt.result!.schedules.isNotEmpty) {
      return retryAttempt.result;
    }

    return null;
  }

  Future<({ParserFetchResult? result, bool wasChallenge})>
      _singleDirectHttpRequest({required int attempt}) async {
    final client = HttpClient();
    client.userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
    client.connectionTimeout = const Duration(seconds: 12);
    // connectionTimeout alone does not bound response headers or a stalled response body.
    final deadline =
        Timer(const Duration(seconds: 20), () => client.close(force: true));

    try {
      AppLogger.i("🌍 Пробуємо прямий HTTP запит (спроба $attempt)...",
          tag: 'Parser');
      await HistoryService()
          .logAction("Парсер: Старт прямого HTTP запиту (спроба $attempt)");

      final request = await client.getUrl(Uri.parse(_url));
      _setHttpHeaders(request);

      final response = await request.close();
      await HistoryService().logAction(
          "Парсер HTTP: Код відповіді ${response.statusCode} (спроба $attempt)");

      if (response.statusCode == 200) {
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 2 * 1024 * 1024) {
            throw const FormatException('DTEK response exceeds 2 MiB');
          }
          bytes.addAll(chunk);
        }
        final html = utf8.decode(bytes);
        await HistoryService()
            .logAction("Парсер HTTP: Отримано ${html.length} байт HTML");

        if (isBotChallengeHtml(html)) {
          AppLogger.w(
              "⚠️ Парсер HTTP: Отримано антибот-челендж (${html.length} байт)",
              tag: 'Parser');
          await HistoryService().logAction(
              "Парсер HTTP: Антибот-челендж (${html.length} байт)",
              level: "WARN");
          return (result: null, wasChallenge: true);
        }

        final jsonString = extractJsonFromHtml(html);
        if (jsonString.isNotEmpty) {
          AppLogger.i("✅ Дані знайдено через прямий HTTP!", tag: 'Parser');
          if (jsonString.length > 50) {
            await HistoryService().logAction(
                "Парсер HTTP: JSON знайдено (${jsonString.length} симв.)");
          }

          try {
            final result = await _parseAndSaveAllGroups(jsonString);
            await HistoryService().logAction(
                "Парсер HTTP: Успішно розібрано ${result.schedules.length} груп");
            return (result: result, wasChallenge: false);
          } catch (e) {
            await HistoryService().logAction(
                "Парсер HTTP: Помилка розбору JSON: $e",
                level: "ERROR");
            rethrow;
          }
        } else {
          AppLogger.w("HTTP: HTML отримано, але JSON не знайдено",
              tag: 'Parser');
          await HistoryService()
              .logAction("Парсер HTTP: JSON не знайдено в HTML", level: "WARN");
        }
      } else {
        // Звільняємо сокет операційної системи, якщо код не 200
        await response.drain<void>();
        AppLogger.w("HTTP: Status code ${response.statusCode}", tag: 'Parser');
        await HistoryService().logAction(
            "Парсер HTTP: Не-200 відповідь: ${response.statusCode}",
            level: "WARN");
      }
    } catch (e) {
      AppLogger.e("HTTP Error (спроба $attempt)", tag: 'Parser', error: e);
      await HistoryService()
          .logAction("Парсер HTTP Помилка ($attempt): $e", level: "WARN");
    } finally {
      deadline.cancel();
      client.close(force: true);
    }
    return (result: null, wasChallenge: false);
  }

  /// Публічний екстрактор для тестування та внутрішнього використання
  String extractJsonFromHtml(String html) => DtekSnapshot.extractJson(html);

  Future<ParserFetchResult> _parseAndSaveAllGroups(String rawJson) async {
    try {
      final snapshot = DtekSnapshot.parse(rawJson, allGroups);
      try {
        await HistoryService().persistSnapshot(
          schedules: snapshot.schedules,
          todayDate: snapshot.todayDate,
          tomorrowDate: snapshot.tomorrowDate,
          dtekUpdatedAt: snapshot.update,
        );
      } catch (historyError) {
        AppLogger.w(
            'Failed to persist snapshot history (non-fatal): $historyError',
            tag: 'Parser');
        await HistoryService()
            .logAction('Парсер історія: $historyError', level: 'WARN');
      }
      return ParserFetchResult(snapshot.schedules,
          '<script>DisconSchedule.fact = ${jsonEncode(snapshot.fact)};</script>');
    } catch (error) {
      AppLogger.e('Invalid DTEK snapshot', tag: 'Parser', error: error);
      await HistoryService()
          .logAction('Парсер: Некоректний графік: $error', level: 'ERROR');
      return const ParserFetchResult({}, null);
    }
  }
}
