import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/services/schedule_version_filter.dart';

ScheduleVersion publication(String code, int id,
        {bool manual = false, bool reliable = true}) =>
    ScheduleVersion(
      recordId: id,
      hash: code,
      savedAt: DateTime(2026, 10, 7, 0, id),
      outageMinutes: DailySchedule.fromEncodedString(code).totalOutageMinutes,
      isManual: manual,
      hasReliableTimestamp: reliable,
    );

void main() {
  List<int> visible(List<ScheduleVersion> versions, {bool hide = true}) =>
      ScheduleVersionFilter.project(versions, hideUnchanged: hide)
          .visibleIndices;

  test('empty and single histories remain usable', () {
    expect(visible([]), isEmpty);
    final result = ScheduleVersionFilter.project([publication('0' * 24, 1)],
        hideUnchanged: true);
    expect(result.visibleIndices, [0]);
    expect(result.representativeFor(-1), -1);
    expect(result.representativeFor(1), -1);
  });

  test('consecutive repeats retain the latest publication in each run', () {
    final versions = [
      publication('0' * 24, 1),
      publication('0' * 24, 2),
      publication('1' * 24, 3),
      publication('1' * 24, 4),
      publication('0' * 24, 5),
    ];
    final result = ScheduleVersionFilter.project(versions, hideUnchanged: true);
    expect(result.visibleIndices, [1, 3, 4]);
    expect(result.representativeIndices, [1, 1, 3, 3, 4]);
    expect(result.unchanged, [false, true, false, true, false]);
    expect(versions.map((v) => v.recordId), [1, 2, 3, 4, 5]);
  });

  test('returning A after B is a new visible version', () {
    expect(
        visible([
          publication('0' * 24, 1),
          publication('1' * 24, 2),
          publication('0' * 24, 3),
        ]),
        [0, 1, 2]);
  });

  test('four hours moved from 12-16 to 16-20 remain distinct', () {
    final before = publication('0' * 12 + '1' * 4 + '0' * 8, 1);
    final after = publication('0' * 16 + '1' * 4 + '0' * 4, 2);
    expect(before.outageMinutes, 240);
    expect(after.outageMinutes, 240);
    expect(visible([before, after]), [0, 1]);
  });

  test('half-hour direction, maybe and unknown changes stay visible', () {
    final codes = [
      '0' * 24,
      '2${'0' * 23}',
      '3${'0' * 23}',
      '4${'0' * 23}',
      '9${'0' * 23}'
    ];
    expect(
        visible([
          for (var i = 0; i < codes.length; i++) publication(codes[i], i),
        ]),
        [0, 1, 2, 3, 4]);
  });

  test('withdrawal and republication of tomorrow are separate events', () {
    expect(
        visible([
          publication('1' * 24, 1),
          publication('9' * 24, 2),
          publication('9' * 24, 3),
          publication('1' * 24, 4),
        ]),
        [0, 2, 3]);
  });

  test('manual edits form boundaries even when the schedule is identical', () {
    expect(
        visible([
          publication('0' * 24, 1),
          publication('0' * 24, 2, manual: true),
          publication('0' * 24, 3, manual: true),
          publication('0' * 24, 4),
          publication('0' * 24, 5),
        ]),
        [0, 1, 2, 4]);
  });

  test('invalid encodings and untrustworthy legacy dates are never hidden', () {
    for (final code in ['', '0' * 23, '5' * 24, 'x' * 24]) {
      expect(visible([publication(code, 1), publication(code, 2)]), [0, 1]);
    }
    expect(
        visible([
          publication('0' * 24, 1),
          publication('0' * 24, 2, reliable: false),
          publication('0' * 24, 3),
        ]),
        [0, 1, 2]);
  });

  test('disabled filter restores every publication and keeps repeat markers',
      () {
    final versions = [publication('0' * 24, 1), publication('0' * 24, 2)];
    final result =
        ScheduleVersionFilter.project(versions, hideUnchanged: false);
    expect(result.visibleIndices, [0, 1]);
    expect(result.representativeIndices, [0, 1]);
    expect(result.unchanged, [false, true]);
    expect(() => result.visibleIndices.add(7), throwsUnsupportedError);
  });

  test('source authority order is retained even for out-of-order import dates',
      () {
    final versions = [publication('0' * 24, 20), publication('1' * 24, 10)];
    expect(visible(versions), [0, 1]);
  });

  test('local identity does not leak into portable history JSON', () {
    final version = publication('1' * 24, 42, manual: true);
    expect(version.toJson().keys,
        unorderedEquals(['hash', 'savedAt', 'outageMinutes']));
    expect(ScheduleVersion.fromJson(version.toJson()).recordId, isNull);
    expect(version.isSamePublication(publication('1' * 24, 42, manual: true)),
        isTrue);
    expect(version.isSamePublication(publication('1' * 24, 43)), isFalse);
  });

  test('randomized histories preserve every transition and the latest snapshot',
      () {
    final random = Random(71);
    for (var trial = 0; trial < 200; trial++) {
      final versions = List.generate(1 + random.nextInt(150),
          (i) => publication('${random.nextInt(5)}' * 24, i));
      final result =
          ScheduleVersionFilter.project(versions, hideUnchanged: true);
      expect(result.visibleIndices.last, versions.length - 1);
      final actualTransitions =
          result.visibleIndices.map((i) => versions[i].hash).toList();
      final expectedTransitions = <String>[];
      for (final version in versions) {
        if (expectedTransitions.isEmpty ||
            expectedTransitions.last != version.hash) {
          expectedTransitions.add(version.hash);
        }
      }
      expect(actualTransitions, expectedTransitions);
      for (var i = 0; i < versions.length; i++) {
        final representative = result.representativeFor(i);
        expect(versions[representative].hash, versions[i].hash);
        expect(result.visibleIndices, contains(representative));
        expect(representative, greaterThanOrEqualTo(i));
      }
    }
  });
}
