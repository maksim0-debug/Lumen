import 'package:workmanager/workmanager.dart';
import 'package:flutter/foundation.dart';

import 'app_logger.dart';
import 'parser_service.dart';
import 'widget_service.dart';
import 'notification_service.dart';
import 'history_service.dart';
import 'preferences_helper.dart';
import 'fcm_service.dart';
import '../models/schedule_status.dart';
import '../utils/app_formatters.dart';

const String taskUpdateSchedule = "taskUpdateSchedule";

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    AppLogger.i("🕒 Запуск фонового завдання: $task", tag: 'Background');
    await HistoryService().logAction("Бекграунд завдання запущено: $task");

    try {
      if (task == taskUpdateSchedule) {
        final prefs = await PreferencesHelper.getSafeInstance();
        final List<String> notificationGroups =
            PreferencesHelper.getActiveNotificationGroups(prefs);

        AppLogger.i("Групи для сповіщень: $notificationGroups",
            tag: 'Background');
        await HistoryService()
            .logAction("Групи для оновлення: $notificationGroups");

        final parser = ParserService.background();

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
              AppLogger.i("🔔 Сповіщення оновлено для $group",
                  tag: 'Background');

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
                final todayStr = AppFormatters.formatDateKey(now);
                final nowMs = now.millisecondsSinceEpoch;

                final newHash = mySchedule.today.scheduleHash;
                final newMinutes = mySchedule.today.totalOutageMinutes;

                const cooldownMs = 5 * 60 * 1000;
                final canNotify = (nowMs - lastNotifTime) > cooldownMs;

                bool shouldUpdateMetadata = true;

                if (savedDate == todayStr &&
                    oldHash != null &&
                    oldHash != newHash) {
                  final fcmTopics =
                      prefs.getStringList('fcm_subscribed_topics') ?? [];
                  final todayTopic =
                      FcmService.groupToTopic(group, dayType: 'today');
                  final isFcmConfigured = fcmTopics.contains(todayTopic);
                  final isFcmInitialized =
                      prefs.getBool('fcm_initialized') ?? false;
                  final isFcmActive = isFcmConfigured && isFcmInitialized;

                  if (isFcmActive) {
                    final keyPendingHash = "fcm_pending_hash_${group}_today";
                    final keyPendingTime = "fcm_pending_time_${group}_today";
                    final pendingHash = prefs.getString(keyPendingHash);
                    final pendingTime = prefs.getInt(keyPendingTime) ?? 0;

                    // Очікуємо доставку серверного FCM-пуша до 10 хвилин (cooldown/grace period)
                    const fcmGracePeriodMs = 10 * 60 * 1000;
                    final hasGracePeriodExpired = (pendingHash == newHash) &&
                        ((nowMs - pendingTime) > fcmGracePeriodMs);

                    if (!hasGracePeriodExpired) {
                      if (pendingHash != newHash) {
                        await prefs.setString(keyPendingHash, newHash);
                        await prefs.setInt(keyPendingTime, nowMs);
                      }
                      AppLogger.i(
                          "ℹ️ Зміна графіку для $group очікує первинну доставку через FCM ($todayTopic). Локальне сповіщення відкладено для уникнення дублікатів.",
                          tag: 'Background');
                      await HistoryService().logAction(
                          "Зміна графіку для $group очікує доставки через FCM ($todayTopic)");
                      // Не перезаписуємо prev_hash завчасно, щоб зберегти надійний fallback
                      shouldUpdateMetadata = false;
                    } else if (canNotify) {
                      AppLogger.w(
                          "⚠️ FCM не доставив сповіщення для $group за 10 хв. Спрацьовує резервне локальне сповіщення Workmanager!",
                          tag: 'Background');
                      await HistoryService().logAction(
                          "Резервне сповіщення Workmanager для $group (FCM timeout)",
                          level: 'WARN');

                      await _sendScheduleChangeNotification(
                        notificationService: notificationService,
                        group: group,
                        oldHash: oldHash,
                        newMinutes: newMinutes,
                      );
                      await prefs.setInt(keyLastNotif, nowMs);
                      await prefs.remove(keyPendingHash);
                      await prefs.remove(keyPendingTime);
                      shouldUpdateMetadata = true;
                    } else {
                      shouldUpdateMetadata = false;
                    }
                  } else if (canNotify) {
                    await _sendScheduleChangeNotification(
                      notificationService: notificationService,
                      group: group,
                      oldHash: oldHash,
                      newMinutes: newMinutes,
                    );
                    await prefs.setInt(keyLastNotif, nowMs);
                    shouldUpdateMetadata = true;
                  } else {
                    AppLogger.i(
                        "⏳ Зміни є ($group), але охолодження. Чекаємо...",
                        tag: 'Background');
                    await HistoryService().logAction(
                        "Зміни є, але спрацювало обмеження (cooldown)");
                    shouldUpdateMetadata = false;
                  }
                } else if (savedDate != todayStr) {
                  AppLogger.i(
                      "📅 Новий день ($savedDate -> $todayStr). База оновлена без сповіщень.",
                      tag: 'Background');
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

          AppLogger.i("✅ Фонову задачу успішно виконано", tag: 'Background');
          await HistoryService().logAction("Бекграунд завдання завершено");
        } else {
          AppLogger.w("⚠️ Дані не отримано (порожній список)",
              tag: 'Background');
          await HistoryService()
              .logAction("Помилка: Пустий список графіків", level: "ERROR");
          return false;
        }
      }
    } catch (e) {
      AppLogger.e("❌ Критична помилка", tag: 'Background', error: e);
      await HistoryService().logAction("Помилка виконання: $e", level: "ERROR");
      return false;
    }

    return true;
  });
}

Future<void> _sendScheduleChangeNotification({
  required NotificationService notificationService,
  required String group,
  required String oldHash,
  required int newMinutes,
}) async {
  final oldMinutes =
      DailySchedule.fromEncodedString(oldHash).totalOutageMinutes;
  final msg = AppFormatters.formatScheduleChangeMessage(
    oldMinutes: oldMinutes,
    newMinutes: newMinutes,
  );

  AppLogger.i("📢 Виявлено зміну графіку для $group: $msg", tag: 'Background');

  try {
    await notificationService.showImmediate(
      "Графік змінено!",
      msg,
      groupName: group,
    );
    await HistoryService().logAction("Сповіщення про зміну надіслано: $msg");
  } catch (e) {
    await HistoryService()
        .logAction("Помилка надсилання сповіщення: $e", level: "ERROR");
  }
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
      );
      AppLogger.i("Ініціалізація успішна", tag: 'BackgroundManager');
    } catch (e) {
      AppLogger.e("Помилка ініціалізації", tag: 'BackgroundManager', error: e);
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
      AppLogger.i("Періодичну задачу зареєстровано", tag: 'BackgroundManager');
    } catch (e) {
      AppLogger.e("Помилка реєстрації задачі",
          tag: 'BackgroundManager', error: e);
    }
  }
}
