import '../models/schedule_status.dart';

/// Information about the countdown to the next power status change.
class CountdownInfo {
  final int minutesRemaining;
  final SlotStatus currentStatus;
  final SlotStatus targetStatus;
  final String formattedRemaining;
  final String message;

  const CountdownInfo({
    required this.minutesRemaining,
    required this.currentStatus,
    required this.targetStatus,
    required this.formattedRemaining,
    required this.message,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CountdownInfo &&
          runtimeType == other.runtimeType &&
          minutesRemaining == other.minutesRemaining &&
          currentStatus == other.currentStatus &&
          targetStatus == other.targetStatus &&
          formattedRemaining == other.formattedRemaining &&
          message == other.message;

  @override
  int get hashCode => Object.hash(
        minutesRemaining,
        currentStatus,
        targetStatus,
        formattedRemaining,
        message,
      );

  @override
  String toString() =>
      'CountdownInfo(minutesRemaining: $minutesRemaining, currentStatus: $currentStatus, targetStatus: $targetStatus, formattedRemaining: "$formattedRemaining", message: "$message")';
}

/// Service for calculating the countdown to the next schedule status change.
class CountdownService {
  CountdownService._();

  static const int _slotsPerDay = 48;
  static const int _minutesPerSlot = 30;
  static const int _minutesPerHour = 60;

  /// Calculates the countdown to the nearest scheduled power outage or restoration.
  ///
  /// Returns `null` if:
  /// - Today's schedule is missing or the current slot is `unknown`;
  /// - The status does not change until the end of today and tomorrow's schedule is not published yet;
  /// - There are no upcoming status changes in the known schedule.
  static CountdownInfo? calculateCountdown({
    required DailySchedule? today,
    required DailySchedule? tomorrow,
    required DateTime now,
  }) {
    if (today == null || today.isEmpty) return null;

    final currentMinuteOfDay = now.hour * _minutesPerHour + now.minute;
    final currentSlotIndex = currentMinuteOfDay ~/ _minutesPerSlot;
    if (currentSlotIndex >= _slotsPerDay) return null;

    final todaySlots = today.toSlots();
    if (currentSlotIndex >= todaySlots.length) return null;

    final currentStatus = todaySlots[currentSlotIndex];
    if (currentStatus == SlotStatus.unknown) return null;

    int nextChangeIndex = -1;
    SlotStatus? targetStatus;
    bool isDataInterrupted = false;

    // Bound search to available slots to strictly prevent RangeError on malformed schedules
    final int todayLimit =
        todaySlots.length < _slotsPerDay ? todaySlots.length : _slotsPerDay;

    // Search for the first status change in the remainder of today
    for (int i = currentSlotIndex + 1; i < todayLimit; i++) {
      final status = todaySlots[i];
      if (status == SlotStatus.unknown) {
        // Data interrupted/missing — stop predicting further
        isDataInterrupted = true;
        break;
      }
      if (status != currentStatus) {
        nextChangeIndex = i;
        targetStatus = status;
        break;
      }
    }

    // If today's schedule was truncated before reaching the end of the day, mark interrupted
    if (todaySlots.length < _slotsPerDay && nextChangeIndex == -1) {
      isDataInterrupted = true;
    }

    // If status remains constant until midnight and data was not interrupted, check tomorrow
    if (nextChangeIndex == -1 && !isDataInterrupted) {
      if (tomorrow != null && !tomorrow.isEmpty) {
        final tomorrowSlots = tomorrow.toSlots();
        final int tomorrowLimit = tomorrowSlots.length < _slotsPerDay
            ? tomorrowSlots.length
            : _slotsPerDay;
        for (int i = 0; i < tomorrowLimit; i++) {
          final status = tomorrowSlots[i];
          if (status == SlotStatus.unknown) {
            // Tomorrow's data ends or is missing from this slot
            break;
          }
          if (status != currentStatus) {
            nextChangeIndex = i + _slotsPerDay;
            targetStatus = status;
            break;
          }
        }
      }
    }

    if (nextChangeIndex == -1 || targetStatus == null) {
      return null;
    }

    final minutesToNextChange =
        (nextChangeIndex * _minutesPerSlot) - currentMinuteOfDay;
    if (minutesToNextChange <= 0) return null;

    final hours = minutesToNextChange ~/ _minutesPerHour;
    final minutes = minutesToNextChange % _minutesPerHour;

    String timeStr = "";
    if (hours > 0) timeStr += "$hoursг ";
    timeStr += "$minutesхв";

    String msg = "";
    if (targetStatus == SlotStatus.off) {
      msg = "До відключення: $timeStr";
    } else if (targetStatus == SlotStatus.on) {
      msg = "До ввімкнення: $timeStr";
    } else if (targetStatus == SlotStatus.maybe) {
      msg = currentStatus == SlotStatus.on
          ? "До можл. відключення: $timeStr"
          : "До зміни статусу: $timeStr";
    } else {
      msg = "До зміни статусу: $timeStr";
    }

    return CountdownInfo(
      minutesRemaining: minutesToNextChange,
      currentStatus: currentStatus,
      targetStatus: targetStatus,
      formattedRemaining: timeStr,
      message: msg,
    );
  }
}
