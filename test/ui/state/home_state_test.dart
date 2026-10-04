import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/data_source_mode.dart';
import 'package:lumen/models/hour_segment.dart';
import 'package:lumen/models/power_event.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/models/schedule_view_mode.dart';
import 'package:lumen/ui/state/home_state.dart';

void main() {
  group('HomeState.hasDisplayData Tests', () {
    final validSchedule = DailySchedule(List.filled(24, LightStatus.on));
    final emptySchedule = DailySchedule.empty();
    final sampleSegments = List.generate(
      24,
      (i) => [
        const HourSegment(0, 1, Colors.green,
            status: LightStatus.on, isFuture: false)
      ],
    );
    final sampleIntervals = [
      PowerOutageInterval(
        start: DateTime(2026, 10, 3, 10, 0),
        end: DateTime(2026, 10, 3, 12, 0),
      ),
    ];
    final sampleVersions = [
      ScheduleVersion(
        hash: '1' * 24,
        savedAt: DateTime(2026, 10, 3, 8, 0),
        outageMinutes: 0,
      ),
    ];

    group('Predicted Mode', () {
      test('returns true when currentDisplaySchedule is non-empty', () {
        final state = HomeState(
          dataSourceMode: DataSourceMode.predicted,
          currentDisplaySchedule: validSchedule,
        );
        expect(state.hasDisplayData, isTrue);
      });

      test('returns false when currentDisplaySchedule is null or empty', () {
        const stateNull = HomeState(
          dataSourceMode: DataSourceMode.predicted,
          currentDisplaySchedule: null,
        );
        expect(stateNull.hasDisplayData, isFalse);

        final stateEmpty = HomeState(
          dataSourceMode: DataSourceMode.predicted,
          currentDisplaySchedule: emptySchedule,
        );
        expect(stateEmpty.hasDisplayData, isFalse);
      });
    });

    group('Real Mode - Today', () {
      test('returns true when realHourSegments is available', () {
        final state = HomeState(
          powerMonitorEnabled: true,
          dataSourceMode: DataSourceMode.real,
          viewMode: ScheduleViewMode.today,
          realHourSegments: sampleSegments,
        );
        expect(state.hasDisplayData, isTrue);
      });

      test('returns false when realHourSegments is null', () {
        const state = HomeState(
          powerMonitorEnabled: true,
          dataSourceMode: DataSourceMode.real,
          viewMode: ScheduleViewMode.today,
          realHourSegments: null,
        );
        expect(state.hasDisplayData, isFalse);
      });
    });

    group('Real Mode - Tomorrow', () {
      test('returns true when realHourSegments and schedule are present', () {
        final state = HomeState(
          powerMonitorEnabled: true,
          dataSourceMode: DataSourceMode.real,
          viewMode: ScheduleViewMode.tomorrow,
          currentDisplaySchedule: validSchedule,
          realHourSegments: sampleSegments,
        );
        expect(state.hasDisplayData, isTrue);
      });

      test('returns false when schedule is missing or empty', () {
        final stateNull = HomeState(
          powerMonitorEnabled: true,
          dataSourceMode: DataSourceMode.real,
          viewMode: ScheduleViewMode.tomorrow,
          currentDisplaySchedule: null,
          realHourSegments: sampleSegments,
        );
        expect(stateNull.hasDisplayData, isFalse);

        final stateEmpty = HomeState(
          powerMonitorEnabled: true,
          dataSourceMode: DataSourceMode.real,
          viewMode: ScheduleViewMode.tomorrow,
          currentDisplaySchedule: emptySchedule,
          realHourSegments: sampleSegments,
        );
        expect(stateEmpty.hasDisplayData, isFalse);
      });
    });

    group('Real Mode - History / Past', () {
      test('returns true when realOutageIntervals has items', () {
        final state = HomeState(
          powerMonitorEnabled: true,
          dataSourceMode: DataSourceMode.real,
          viewMode: ScheduleViewMode.history,
          realHourSegments: sampleSegments,
          realOutageIntervals: sampleIntervals,
          historyVersions: const [],
        );
        expect(state.hasDisplayData, isTrue);
      });

      test(
          'returns false in real mode when intervals and coverage empty even if historyVersions has items',
          () {
        final state = HomeState(
          powerMonitorEnabled: true,
          dataSourceMode: DataSourceMode.real,
          viewMode: ScheduleViewMode.yesterday,
          realHourSegments: sampleSegments,
          realOutageIntervals: const [],
          historyVersions: sampleVersions,
          hasRealCoverage: false,
        );
        expect(state.hasDisplayData, isFalse);
      });

      test(
          'returns true when hasRealCoverage is true even if intervals and versions empty',
          () {
        final state = HomeState(
          powerMonitorEnabled: true,
          dataSourceMode: DataSourceMode.real,
          viewMode: ScheduleViewMode.yesterday,
          realHourSegments: sampleSegments,
          realOutageIntervals: const [],
          historyVersions: const [],
          hasRealCoverage: true,
        );
        expect(state.hasDisplayData, isTrue);
      });

      test(
          'returns false when both realOutageIntervals and historyVersions are empty and no coverage',
          () {
        final state = HomeState(
          powerMonitorEnabled: true,
          dataSourceMode: DataSourceMode.real,
          viewMode: ScheduleViewMode.history,
          realHourSegments: sampleSegments,
          realOutageIntervals: const [],
          historyVersions: const [],
          hasRealCoverage: false,
        );
        expect(state.hasDisplayData, isFalse);
      });
    });

    group('HomeState.isMissingRealDataSource Tests', () {
      test(
          'returns true when real mode today, no intervals, and source not configured',
          () {
        const state = HomeState(
          powerMonitorEnabled: true,
          dataSourceMode: DataSourceMode.real,
          viewMode: ScheduleViewMode.today,
          realOutageIntervals: [],
          isRealSourceConfigured: false,
        );
        expect(state.isMissingRealDataSource, isTrue);
      });

      test('returns false when isRealSourceConfigured is true', () {
        const state = HomeState(
          powerMonitorEnabled: true,
          dataSourceMode: DataSourceMode.real,
          viewMode: ScheduleViewMode.today,
          realOutageIntervals: [],
          isRealSourceConfigured: true,
        );
        expect(state.isMissingRealDataSource, isFalse);
      });

      test('returns false when realOutageIntervals is not empty', () {
        final state = HomeState(
          powerMonitorEnabled: true,
          dataSourceMode: DataSourceMode.real,
          viewMode: ScheduleViewMode.today,
          realOutageIntervals: sampleIntervals,
          isRealSourceConfigured: false,
        );
        expect(state.isMissingRealDataSource, isFalse);
      });

      test('returns false when viewMode is not today', () {
        const state = HomeState(
          powerMonitorEnabled: true,
          dataSourceMode: DataSourceMode.real,
          viewMode: ScheduleViewMode.tomorrow,
          realOutageIntervals: [],
          isRealSourceConfigured: false,
        );
        expect(state.isMissingRealDataSource, isFalse);
      });

      test('returns false when not in real mode', () {
        const state = HomeState(
          powerMonitorEnabled: true,
          dataSourceMode: DataSourceMode.predicted,
          viewMode: ScheduleViewMode.today,
          realOutageIntervals: [],
          isRealSourceConfigured: false,
        );
        expect(state.isMissingRealDataSource, isFalse);
      });
    });
  });
}
