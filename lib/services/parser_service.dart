import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:intl/intl.dart';
import '../models/schedule_status.dart';
import 'history_service.dart';

class ParserService {
  static const String _url = "https://www.dtek-krem.com.ua/ua/shutdowns";
  static const String _homeUrl = "https://www.dtek-krem.com.ua/";

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

  HeadlessInAppWebView? _headlessWebView;

  Future<void> init() async {}

  Future<Map<String, FullSchedule>> fetchAllSchedules() async {
    // 1. Try to fetch via simple HTTP request first (works in background)
    await HistoryService().logAction("Парсер: Старт fetchAllSchedules (v3)");
    final httpResult = await _fetchWithHttpClient();
    if (httpResult != null && httpResult.isNotEmpty) {
      await HistoryService()
          .logAction("Парсер: HTTP метод спрацював, повернення результату");
      return httpResult;
    }

    print("[Parser] 🌍 HTTP не спрацював, запускаємо Headless WebView...");
    await HistoryService().logAction("Парсер: HTTP не вдалося, запуск WebView");

    print("[Parser] 🚀 Запуск Headless браузера (Hybrid)...");
    final completer = Completer<Map<String, FullSchedule>>();

    if (_headlessWebView != null) {
      try {
        await _headlessWebView?.dispose();
      } catch (_) {}
      _headlessWebView = null;
    }

    _headlessWebView = HeadlessInAppWebView(
      // Крок 1: Спочатку відкриваємо головну сторінку для отримання cookies
      initialUrlRequest: URLRequest(url: WebUri(_homeUrl)),
      initialSettings: InAppWebViewSettings(
        isInspectable: kDebugMode,
        javaScriptEnabled: true,
        incognito: false,
        cacheEnabled: true,
        domStorageEnabled: true,
        databaseEnabled: true,
        userAgent:
            "Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/112.0.0.0 Mobile Safari/537.36",
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
        if (reqUrl == _url || reqUrl == _homeUrl || reqUrl == _homeUrl.replaceAll(RegExp(r'/$'), '')) {
          print("[Parser] ⛔ WebView HTTP помилка: $statusCode для $reqUrl");
          await HistoryService().logAction(
              "Парсер WebView помилка: HTTP $statusCode ($reqUrl)",
              level: "ERROR");
        }
      },
      onLoadError: (controller, url, code, message) async {
        print("[Parser] ⛔ WebView помилка мережі: $code — $message");
        await HistoryService().logAction(
            "Парсер WebView помилка мережі: $code — $message",
            level: "ERROR");
      },
      onLoadStop: (controller, url) async {
        final currentUrl = url?.toString() ?? '';

        // Крок 1: Головна сторінка — чекаємо cookies і переходимо до графіків
        if (!currentUrl.contains('/ua/shutdowns')) {
          print(
              "[Parser] \u{1F3E0} Головна сторінка завантажена ($currentUrl). Чекаємо 3 сек для cookies...");
          await HistoryService().logAction(
              "Парсер WebView: Головна сторінка завантажена, очікування cookies");
          await Future.delayed(const Duration(seconds: 3));

          print("[Parser] ➡️ Переходимо на сторінку графіків...");
          await controller.loadUrl(
            urlRequest: URLRequest(
              url: WebUri(_url),
              headers: {'Referer': _homeUrl},
            ),
          );
          return;
        }

        // Крок 2: Сторінка графіків завантажена — шукаємо дані
        print(
            "[Parser] \u{1F4CA} Сторінка графіків завантажена. Шукаємо дані...");

        for (int i = 0; i < 20; i++) {
          try {
            final jsResult = await controller.evaluateJavascript(
                source:
                    "typeof DisconSchedule !== 'undefined' && DisconSchedule.fact ? JSON.stringify(DisconSchedule.fact) : 'null'");

            String jsonString = "";

            if (jsResult != null &&
                jsResult != "null" &&
                jsResult.toString().length > 100) {
              print("[Parser] ✅ Дані знайдено через JS змінну!");
              jsonString = jsResult.toString();
            } else {
              final html = await controller.evaluateJavascript(
                  source: "document.documentElement.outerHTML");
              if (html != null) {
                jsonString = _extractJsonFromHtml(html.toString());
                if (jsonString.isNotEmpty) {
                  print("[Parser] ✅ Дані знайдено через пошук у HTML!");
                }
              }
            }

            if (jsonString.isNotEmpty && jsonString.length > 100) {
              var schedules = await _parseAndSaveAllGroups(jsonString);
              if (!completer.isCompleted) completer.complete(schedules);

              await _headlessWebView?.dispose();
              _headlessWebView = null;
              return;
            } else {
              print("[Parser] Спроба ${i + 1}/20: Дані поки не знайдено...");
              if ((i + 1) % 5 == 0) {
                await HistoryService()
                    .logAction("Парсер: спроба ${i + 1}/20 - дані не знайдено");
              }

              // Debug-логування на першій спробі
              if (kDebugMode && i == 0) {
                final debugHtml = await controller.evaluateJavascript(
                    source: "document.documentElement.outerHTML");
                if (debugHtml != null) {
                  String snippet = debugHtml.toString();
                  if (snippet.length > 500) {
                    snippet = snippet.substring(0, 500);
                  }
                  print("[Parser-DEBUG] HTML Snippet:\n$snippet...");

                  if (snippet.contains('cloudflare') ||
                      snippet.contains('Just a moment')) {
                    print("[Parser-DEBUG] ⚠️ Виявлено захист Cloudflare!");
                    await HistoryService().logAction(
                        "WebView потрапив на екран захисту Cloudflare",
                        level: "WARN");
                  }
                }
              }
            }
          } catch (e) {
            print("[Parser] Помилка ітерації: $e");
            await HistoryService()
                .logAction("Парсер помилка ітерації: $e", level: "ERROR");
          }
          await Future.delayed(const Duration(seconds: 1));
        }

        if (!completer.isCompleted) {
          print("[Parser] ❌ Тайм-аут");
          await HistoryService()
              .logAction("Парсер: Тайм-аут очікування даних", level: "ERROR");
          completer.complete({});
          await _headlessWebView?.dispose();
          _headlessWebView = null;
        }
      },
    );

    // Страховочний тайм-аут: 60 секунд на весь процес WebView
    Future.delayed(const Duration(seconds: 60), () {
      if (!completer.isCompleted) {
        print("[Parser] ❌ Глобальний тайм-аут WebView (60 сек)");
        HistoryService().logAction(
            "Парсер: Глобальний тайм-аут WebView 60 сек",
            level: "ERROR");
        completer.complete({});
        _headlessWebView?.dispose();
        _headlessWebView = null;
      }
    });

    try {
      await _headlessWebView?.run();
    } catch (e) {
      print("[Parser] ❌ Помилка запуску WebView: $e");
      await HistoryService()
          .logAction("Парсер: Помилка запуску WebView: $e", level: "ERROR");
      if (!completer.isCompleted) completer.complete({});
      return {};
    }

    return completer.future;
  }

  /// Допоміжний метод: встановлює стандартні заголовки браузера
  void _setHttpHeaders(HttpClientRequest request, {String? referer}) {
    request.headers.set('Accept',
        'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7');
    request.headers.set(
        'Accept-Language', 'uk,ru-RU;q=0.9,ru;q=0.8,en-US;q=0.7,en;q=0.6');
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

  Future<Map<String, FullSchedule>?> _fetchWithHttpClient() async {
    try {
      print("[Parser] 🌍 Пробуємо HTTP запит (двокроковий)...");
      await HistoryService().logAction("Парсер: Старт HTTP запиту (v2)");
      final client = HttpClient();
      client.userAgent =
          "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
      client.connectionTimeout = const Duration(seconds: 15);

      // === Крок 1: Відвідуємо головну сторінку для отримання cookies ===
      print("[Parser] HTTP Крок 1: Запит головної сторінки...");
      final homeRequest = await client.getUrl(Uri.parse(_homeUrl));
      _setHttpHeaders(homeRequest);
      final homeResponse = await homeRequest.close();

      final cookies = homeResponse.cookies;
      final homeStatus = homeResponse.statusCode;
      await homeResponse.drain<void>();

      if (kDebugMode) {
        print(
            "[Parser-DEBUG] HTTP Головна: статус=$homeStatus, cookies=${cookies.length}");
        for (var c in cookies) {
          print(
              "[Parser-DEBUG]   Cookie: ${c.name}=${c.value.length > 20 ? '${c.value.substring(0, 20)}...' : c.value}");
        }
      }
      await HistoryService().logAction(
          "Парсер HTTP: Головна сторінка: $homeStatus, cookies: ${cookies.length}");

      // === Крок 2: Запитуємо цільову сторінку з cookies і Referer ===
      print("[Parser] HTTP Крок 2: Запит сторінки графіків...");
      final request = await client.getUrl(Uri.parse(_url));
      _setHttpHeaders(request, referer: _homeUrl);

      // Додаємо cookies з Кроку 1
      for (var cookie in cookies) {
        request.cookies.add(cookie);
      }

      final response = await request.close();

      await HistoryService()
          .logAction("Парсер HTTP: Код відповіді ${response.statusCode}");

      if (response.statusCode == 200) {
        final html = await response.transform(utf8.decoder).join();
        await HistoryService()
            .logAction("Парсер HTTP: Отримано ${html.length} байт HTML");

        final jsonString = _extractJsonFromHtml(html);
        if (jsonString.isNotEmpty) {
          print("[Parser] ✅ Дані знайдено через HTTP!");
          if (jsonString.length > 50) {
            await HistoryService().logAction(
                "Парсер HTTP: JSON знайдено (${jsonString.length} симв.)");
          } else {
            await HistoryService().logAction(
                "Парсер HTTP: JSON підозріло короткий: $jsonString",
                level: "WARN");
          }

          try {
            final result = await _parseAndSaveAllGroups(jsonString);
            await HistoryService().logAction(
                "Парсер HTTP: Успішно розібрано ${result.length} груп");
            return result;
          } catch (e) {
            await HistoryService().logAction(
                "Парсер HTTP: Помилка розбору JSON: $e",
                level: "ERROR");
            rethrow;
          }
        } else {
          print("[Parser] HTTP: HTML отримано, але JSON не знайдено");
          await HistoryService()
              .logAction("Парсер HTTP: JSON не знайдено в HTML", level: "WARN");

          if (kDebugMode) {
            String snippet = html;
            if (snippet.length > 500) snippet = snippet.substring(0, 500);
            print("[Parser-DEBUG] HTTP HTML Snippet:\n$snippet...");
          }
        }
      } else {
        print("[Parser] HTTP: Status code ${response.statusCode}");
        await HistoryService().logAction(
            "Парсер HTTP: Не-200 відповідь: ${response.statusCode}",
            level: "WARN");

        if (kDebugMode) {
          try {
            final errorBody = await response.transform(utf8.decoder).join();
            String snippet = errorBody;
            if (snippet.length > 500) snippet = snippet.substring(0, 500);
            print("[Parser-DEBUG] HTTP Error Body:\n$snippet...");
          } catch (_) {}
        }
      }
    } catch (e) {
      print("[Parser] HTTP Error: $e");
      await HistoryService()
          .logAction("Парсер HTTP Критична помилка: $e", level: "ERROR");
    }
    return null;
  }

  String _extractJsonFromHtml(String html) {
    try {
      const String searchStart = 'DisconSchedule.fact =';
      int startIndex = html.indexOf(searchStart);
      if (startIndex == -1) return "";

      startIndex += searchStart.length;
      int endIndex = html.indexOf('DisconSchedule.showCurOutage', startIndex);

      if (endIndex == -1) endIndex = html.indexOf('</script>', startIndex);
      if (endIndex == -1) return "";

      String rawJson = html.substring(startIndex, endIndex).trim();

      int lastBrace = rawJson.lastIndexOf('}');
      if (lastBrace != -1) {
        rawJson = rawJson.substring(0, lastBrace + 1);
      }
      return rawJson;
    } catch (e) {
      return "";
    }
  }

  Future<Map<String, FullSchedule>> _parseAndSaveAllGroups(
      String rawJson) async {
    try {
      if (rawJson.startsWith('"') && rawJson.endsWith('"')) {
        rawJson = jsonDecode(rawJson);
      }

      rawJson = rawJson.replaceAll(r'\"', '"');
      if (rawJson.startsWith('"') && rawJson.endsWith('"')) {
        rawJson = rawJson.substring(1, rawJson.length - 1);
      }

      Map<String, dynamic> jsonData = jsonDecode(rawJson);
      String updateTime = jsonData['update'] ?? "Невідомо";
      int todayTimestamp = jsonData['today'];
      int tomorrowTimestamp = todayTimestamp + 86400;
      Map<String, dynamic> dataObj = jsonData['data'];

      // Format dates for history
      final todayDate =
          DateTime.fromMillisecondsSinceEpoch(todayTimestamp * 1000);
      final tomorrowDate =
          DateTime.fromMillisecondsSinceEpoch(tomorrowTimestamp * 1000);
      final dateFormatter = DateFormat('yyyy-MM-dd');
      final todayDateStr = dateFormatter.format(todayDate);
      final tomorrowDateStr = dateFormatter.format(tomorrowDate);

      Map<String, FullSchedule> result = {};

      for (String group in allGroups) {
        final todaySchedule =
            _parseDay(dataObj, todayTimestamp.toString(), group);
        final tomorrowSchedule =
            _parseDay(dataObj, tomorrowTimestamp.toString(), group);

        result[group] = FullSchedule(
          today: todaySchedule,
          tomorrow: tomorrowSchedule,
          lastUpdatedSource: updateTime,
        );

        // Save history for today
        if (!todaySchedule.isEmpty) {
          await HistoryService().persistVersion(
            groupKey: group,
            targetDate: todayDateStr,
            scheduleCode: todaySchedule.toEncodedString(),
            dtekUpdatedAt: updateTime,
          );
        }

        // Save history for tomorrow
        if (!tomorrowSchedule.isEmpty) {
          await HistoryService().persistVersion(
            groupKey: group,
            targetDate: tomorrowDateStr,
            scheduleCode: tomorrowSchedule.toEncodedString(),
            dtekUpdatedAt: updateTime,
          );
        }
      }
      return result;
    } catch (e) {
      print("[Parser] Помилка парсингу JSON: $e");
      await HistoryService()
          .logAction("Парсер: Помилка парсингу JSON: $e", level: "ERROR");
      return {};
    }
  }

  DailySchedule _parseDay(
      Map<String, dynamic> dataObj, String dateKey, String groupKey) {
    if (!dataObj.containsKey(dateKey) ||
        !dataObj[dateKey].containsKey(groupKey)) {
      return DailySchedule.empty();
    }
    Map<String, dynamic> groupHours = dataObj[dateKey][groupKey];
    List<LightStatus> statuses = List.filled(24, LightStatus.unknown);

    groupHours.forEach((hourStr, value) {
      int hour = int.tryParse(hourStr) ?? -1;
      int index = hour - 1;
      if (index >= 0 && index < 24) {
        statuses[index] = _mapStatus(value.toString());
      }
    });
    return DailySchedule(statuses);
  }

  LightStatus _mapStatus(String value) {
    switch (value) {
      case 'yes':
        return LightStatus.on;
      case 'no':
        return LightStatus.off;
      case 'first':
        return LightStatus.semiOn;
      case 'second':
        return LightStatus.semiOff;
      case 'maybe':
        return LightStatus.maybe;
      case 'mfirst':
        return LightStatus.maybe;
      case 'msecond':
        return LightStatus.maybe;
      default:
        return LightStatus.unknown;
    }
  }
}
