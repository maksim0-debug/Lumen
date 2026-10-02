import 'dart:io';

import '../../models/data_source_mode.dart';
import '../../models/schedule_status.dart';
import '../../utils/app_formatters.dart';
import '../parser_service.dart';
import '../preferences_helper.dart';

/// Result object for group resolution with explicit validation error detection.
class GroupResolution {
  final String? group;
  final String? error;
  final bool isValid;

  const GroupResolution.success(this.group)
      : error = null,
        isValid = true;

  const GroupResolution.failure(this.error)
      : group = null,
        isValid = false;
}

/// Centralized helper utilities for request parameter normalization and structured data conversion.
class ApiHelpers {
  /// Resolves the GPV group from query parameter or user preferences.
  /// If an invalid group query parameter is explicitly provided, returns a failure rather than silently defaulting.
  static Future<GroupResolution> resolveGroup(HttpRequest request) async {
    final queryGroup = request.uri.queryParameters['group'];
    if (queryGroup != null && queryGroup.trim().isNotEmpty) {
      final normalized = queryGroup.trim().toUpperCase();
      if (ParserService.allGroups.contains(normalized)) {
        return GroupResolution.success(normalized);
      }
      return GroupResolution.failure(
        'Невідома група "$queryGroup". Доступні групи: ${ParserService.allGroups.join(", ")}',
      );
    }

    try {
      final prefs = await PreferencesHelper.getSafeInstance();
      final saved = prefs.getString('selected_group');
      if (saved != null && ParserService.allGroups.contains(saved)) {
        return GroupResolution.success(saved);
      }
    } catch (_) {}

    return const GroupResolution.success('GPV2.1');
  }

  /// Resolves data source mode (real vs predicted).
  static DataSourceMode resolveMode(HttpRequest request) {
    final modeStr = request.uri.queryParameters['mode']?.toLowerCase().trim();
    if (modeStr == 'predicted') {
      return DataSourceMode.predicted;
    }
    return DataSourceMode.real;
  }

  /// Converts a DailySchedule into combined machine-readable and UI-friendly interval representations.
  static List<Map<String, dynamic>> buildStructuredIntervals(
      DailySchedule schedule) {
    if (schedule.isEmpty) return [];

    final slots = schedule.toSlots();
    final List<Map<String, dynamic>> intervals = [];
    int i = 0;

    while (i < slots.length) {
      final currentStatus = slots[i];
      int j = i + 1;
      while (j < slots.length && slots[j] == currentStatus) {
        j++;
      }

      final start = AppFormatters.formatTime(i * 30);
      final end = AppFormatters.formatTime(j * 30);
      final durationMins = (j - i) * 30;

      String statusStr;
      String statusLabel;
      switch (currentStatus) {
        case SlotStatus.on:
          statusStr = 'on';
          statusLabel = 'ON';
          break;
        case SlotStatus.off:
          statusStr = 'off';
          statusLabel = 'OFF';
          break;
        case SlotStatus.maybe:
          statusStr = 'maybe';
          statusLabel = 'MAYBE';
          break;
        case SlotStatus.unknown:
          statusStr = 'unknown';
          statusLabel = '?';
          break;
      }

      intervals.add({
        'start': start,
        'end': end,
        'status': statusStr,
        'status_label': statusLabel,
        'duration_minutes': durationMins,
        'duration_formatted': AppFormatters.formatDuration(durationMins),
        'time_range': '$start - $end',
      });

      i = j;
    }

    return intervals;
  }
}
