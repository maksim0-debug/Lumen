import 'package:workmanager/workmanager.dart';
import 'package:flutter/foundation.dart';

import 'parser_service.dart';
import 'widget_service.dart';
import 'notification_service.dart';
import 'history_service.dart';
import 'preferences_helper.dart';
import '../models/schedule_status.dart';

const String taskUpdateSchedule = "taskUpdateSchedule";

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    print("[Background] 🕒 Запуск фонового завдання: $task");
    await HistoryService().logAction("Бекграунд завдання запущено: $task");

    try {
      if (task == taskUpdateSchedule) {
        final prefs = await PreferencesHelper.getSafeInstance();
        List<String> notificationGroups =
            prefs.getStringList('notification_groups') ?? [];

        if (notificationGroups.isEmpty) {
          final selectedGroup = prefs.getString('selected_group') ?? "GPV2.1";
          notificationGroups = [selectedGroup];
        }

        print("[Background] Групи для сповіщень: $notificationGroups");
        await HistoryService()
            .logAction("Групи для оновлення: $notificationGroups");

        final parser = ParserService();

        final allSchedules = await parser.fetchAllSchedules();

        if (allSchedules.isNotEmpty) {
          await HistoryService()
              .logAction("Дані успішно отримані. Груп: ${allSchedules.length}");

          // History is saved inside ParserService now
          // await HistoryService().saveHistory(allSchedules);

          final widgetService = WidgetService();
          await widgetService.updateWidget(allSchedules);

          final notificationService = NotificationService();
          await notificationService.init();

          bool first = true;

          for (String group in notificationGroups) {
            final mySchedule = allSchedules[group];
            if (mySchedule != null && !mySchedule.today.isEmpty) {
              await notificationService.scheduleNotificationsForToday(
                  mySchedule,
                  groupName: group,
                  cancelExisting: first);
              first = false;
              print("[Background] 🔔 Сповіщення оновлено для $group");

              final bool notifyChange =
                  prefs.getBool('notify_schedule_change') ?? true;
              if (notifyChange) {
                final keyHash = "prev_hash_${group}_today";
                final keyDate = "prev_date_${group}_today";
                final keyLastNotif = "last_change_notif_time_$group";

                final oldHash = prefs.getString(keyHash);
                final savedDate = prefs.getString(keyDate);
                final lastNotifTime = prefs.getInt(keyLastNotif) ?? 0;

                final now = DateTime.now();
                final todayStr = "${now.year}-${now.month}-${now.day}";
                final nowMs = now.millisecondsSinceEpoch;

                final newHash = mySchedule.today.scheduleHash;
                final newMinutes = mySchedule.today.totalOutageMinutes;

                final cooldownMs = 5 * 60 * 1000;
                final canNotify = (nowMs - lastNotifTime) > cooldownMs;

                bool shouldUpdateMetadata = true;

                if (savedDate == todayStr &&
                    oldHash != null &&
                    oldHash != newHash) {
                  if (canNotify) {
                    int oldMinutes = 0;
                    for (int i = 0; i < oldHash.length && i < 24; i++) {
                      final char = oldHash[i];
                      if (char == '1')
                        oldMinutes += 60;
                      else if (char == '2' || char == '3') oldMinutes += 30;
                    }

                    final diff = newMinutes - oldMinutes;
                    if (diff != 0) {
                      final diffHours = (diff.abs() / 60);
                      final diffStr = diffHours == diffHours.toInt()
                          ? diffHours.toInt().toString()
                          : diffHours.toStringAsFixed(1);
                      final msg = diff > 0
                          ? "Світла стало МЕНШЕ на $diffStr год. 😔"
                          : "Світла стало БІЛЬШЕ на $diffStr год. 🎉";

                      print(
                          "[Background] 📢 Виявлено зміну графіку для $group: $msg");

                      try {
                        await notificationService.showImmediate(
                            "Графік змінено!", msg,
                            groupName: group);
                        await HistoryService()
                            .logAction("Сповіщення про зміну надіслано: $msg");
                      } catch (e) {
                        await HistoryService().logAction(
                            "Помилка надсилання сповіщення: $e",
                            level: "ERROR");
                      }

                      await prefs.setInt(keyLastNotif, nowMs);
                    }
                  } else {
                    print(
                        "[Background] ⏳ Зміни є ($group), але охолодження. Чекаємо...");
                    await HistoryService().logAction(
                        "Зміни є, але спрацювало обмеження (cooldown)");
                    shouldUpdateMetadata = false;
                  }
                } else if (savedDate != todayStr) {
                  print(
                      "[Background] 📅 Новий день ($savedDate -> $todayStr). База оновлена без сповіщень.");
                  await HistoryService().logAction(
                      "Новий день ($savedDate -> $todayStr). База оновлена.");
                }

                if (shouldUpdateMetadata) {
                  await prefs.setString(keyHash, newHash);
                  await prefs.setString(keyDate, todayStr);
                }
              }
              await HistoryService().logAction("Оброблено групу $group");
            }
          }

          print("[Background] ✅ Фонову задачу успішно виконано");
          await HistoryService().logAction("Бекграунд завдання завершено");
        } else {
          print("[Background] ⚠️ Дані не отримано (порожній список)");
          await HistoryService()
              .logAction("Помилка: Пустий список графіків", level: "ERROR");
          return Future.value(false);
        }
      }
    } catch (e) {
      print("[Background] ❌ Критична помилка: $e");
      await HistoryService().logAction("Помилка виконання: $e", level: "ERROR");
      return Future.value(false);
    }

    return Future.value(true);
  });
}

class BackgroundManager {
  static final BackgroundManager _instance = BackgroundManager._internal();
  factory BackgroundManager() => _instance;
  BackgroundManager._internal();

  Future<void> init() async {
    if (kIsWeb || (defaultTargetPlatform == TargetPlatform.windows)) return;

    try {
      await Workmanager().initialize(
        callbackDispatcher,
        isInDebugMode: false,
      );
      print("[BackgroundManager] Ініціалізація успішна");
    } catch (e) {
      print("[BackgroundManager] Помилка ініціалізації: $e");
    }
  }

  void registerPeriodicTask() {
    if (kIsWeb || (defaultTargetPlatform == TargetPlatform.windows)) return;

    try {
      Workmanager().registerPeriodicTask(
        "periodic_update_task",
        taskUpdateSchedule,
        frequency: const Duration(minutes: 15),
        constraints: Constraints(
          networkType: NetworkType.connected,
        ),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
        initialDelay: const Duration(seconds: 10),
      );
      print("[BackgroundManager] Періодичну задачу зареєстровано");
    } catch (e) {
      print("[BackgroundManager] Помилка реєстрації задачі: $e");
    }
  }
}
