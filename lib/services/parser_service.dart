import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:intl/intl.dart';
import '../models/schedule_status.dart';
import 'history_service.dart';

class ParserService {
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

  HeadlessInAppWebView? _headlessWebView;

  Future<void> init() async {}

  Future<Map<String, FullSchedule>> fetchAllSchedules() async {
    // 1. Try to fetch via simple HTTP request first (works in background)
    await HistoryService().logAction("Парсер: Старт fetchAllSchedules (v3)");
    final httpResult = await _fetchWithHttpClient();
    if (httpResult != null && httpResult.isNotEmpty) {
      await HistoryService().logAction("Парсер: HTTP метод спрацював, повернення результату");
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
      initialUrlRequest: URLRequest(url: WebUri(_url)),
      initialSettings: InAppWebViewSettings(
        isInspectable: false,
        javaScriptEnabled: true,
        incognito: true,
        cacheEnabled: false,
        userAgent:
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
      ),
      onLoadStop: (controller, url) async {
        print("[Parser] Страница загружена. Ищем данные...");

        for (int i = 0; i < 20; i++) {
          try {
            final jsResult = await controller.evaluateJavascript(
                source:
                    "typeof DisconSchedule !== 'undefined' && DisconSchedule.fact ? JSON.stringify(DisconSchedule.fact) : 'null'");

            String jsonString = "";

            if (jsResult != null &&
                jsResult != "null" &&
                jsResult.toString().length > 100) {
              print("[Parser] ✅ Данные найдены через JS переменную!");
              jsonString = jsResult.toString();
            }
            else {
              final html = await controller.evaluateJavascript(
                  source: "document.documentElement.outerHTML");
              if (html != null) {
                jsonString = _extractJsonFromHtml(html.toString());
                if (jsonString.isNotEmpty) {
                  print("[Parser] ✅ Данные найдены через поиск в HTML!");
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
              print("[Parser] Попытка ${i + 1}/20: Данные пока не найдены...");
              // Only log every 5th attempt to avoid spamming logs
              if ((i + 1) % 5 == 0) {
                 await HistoryService().logAction("Парсер: спроба ${i + 1}/20 - дані не знайдено");
              }
            }
          } catch (e) {
            print("[Parser] Ошибка итерации: $e");
            await HistoryService().logAction("Парсер помилка ітерації: $e", level: "ERROR");
          }
          await Future.delayed(const Duration(seconds: 1));
        }

        if (!completer.isCompleted) {
          print("[Parser] ❌ Тайм-аут");
          await HistoryService().logAction("Парсер: Тайм-аут очікування даних", level: "ERROR");
          completer.complete({});
          await _headlessWebView?.dispose();
          _headlessWebView = null;
        }
      },
    );

    try {
      await _headlessWebView?.run();
    } catch (e) {
      print("[Parser] ❌ Ошибка запуска WebView: $e");
      await HistoryService().logAction("Парсер: Помилка запуску WebView: $e", level: "ERROR");
      return {};
    }

    return completer.future;
  }

  Future<Map<String, FullSchedule>?> _fetchWithHttpClient() async {
    try {
      print("[Parser] 🌍 Пробуем HTTP запрос...");
      await HistoryService().logAction("Парсер: Старт HTTP запиту");
      final client = HttpClient();
      client.userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
      // Set a timeout
      client.connectionTimeout = const Duration(seconds: 15);
      
      final request = await client.getUrl(Uri.parse(_url));
      final response = await request.close();
      
      await HistoryService().logAction("Парсер HTTP: Код відповіді ${response.statusCode}");
      
      if (response.statusCode == 200) {
        final html = await response.transform(utf8.decoder).join();
        await HistoryService().logAction("Парсер HTTP: Отримано ${html.length} байт HTML");
        
        final jsonString = _extractJsonFromHtml(html);
        if (jsonString.isNotEmpty) {
           print("[Parser] ✅ Данные найдены через HTTP!");
           if (jsonString.length > 50) {
             await HistoryService().logAction("Парсер HTTP: JSON знайдено (${jsonString.length} симв.), спроба розбору...");
           } else {
             await HistoryService().logAction("Парсер HTTP: JSON знайдено, але підозріло короткий: $jsonString", level: "WARN");
           }
           
           try {
              final result = await _parseAndSaveAllGroups(jsonString);
              await HistoryService().logAction("Парсер HTTP: Успішно розібрано ${result.length} груп");
              return result;
           } catch (e) {
              await HistoryService().logAction("Парсер HTTP: Помилка розбору JSON: $e", level: "ERROR");
              throw e;
           }
        } else {
           print("[Parser] HTTP: HTML получен, но JSON не найден");
           await HistoryService().logAction("Парсер HTTP: JSON не знайдено в HTML", level: "WARN");
        }
      } else {
        print("[Parser] HTTP: Status code ${response.statusCode}");
      }
    } catch (e) {
      print("[Parser] HTTP Error: $e");
      await HistoryService().logAction("Парсер HTTP Критична помилка: $e", level: "ERROR");
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

  Future<Map<String, FullSchedule>> _parseAndSaveAllGroups(String rawJson) async {
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
      final todayDate = DateTime.fromMillisecondsSinceEpoch(todayTimestamp * 1000);
      final tomorrowDate = DateTime.fromMillisecondsSinceEpoch(tomorrowTimestamp * 1000);
      final dateFormatter = DateFormat('yyyy-MM-dd');
      final todayDateStr = dateFormatter.format(todayDate);
      final tomorrowDateStr = dateFormatter.format(tomorrowDate);

      Map<String, FullSchedule> result = {};

      for (String group in allGroups) {
        final todaySchedule = _parseDay(dataObj, todayTimestamp.toString(), group);
        final tomorrowSchedule = _parseDay(dataObj, tomorrowTimestamp.toString(), group);

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
      print("[Parser] Ошибка парсинга JSON: $e");
      await HistoryService().logAction("Парсер: Помилка парсингу JSON: $e", level: "ERROR");
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
