import '../models/schedule_status.dart';

/// A presentation-only projection. Source order and records remain untouched.
class ScheduleVersionProjection {
  final List<int> visibleIndices;
  final List<int> representativeIndices;
  final List<bool> unchanged;

  ScheduleVersionProjection._(
    List<int> visibleIndices,
    List<int> representativeIndices,
    List<bool> unchanged,
  )   : visibleIndices = List.unmodifiable(visibleIndices),
        representativeIndices = List.unmodifiable(representativeIndices),
        unchanged = List.unmodifiable(unchanged);

  int representativeFor(int index) =>
      index < 0 || index >= representativeIndices.length
          ? -1
          : representativeIndices[index];
}

class ScheduleVersionFilter {
  static final _validCode = RegExp(r'^[0-49]{24}$');

  /// Only adjacent, trustworthy automatic publications can be collapsed.
  static bool _isRepeat(ScheduleVersion previous, ScheduleVersion current) =>
      !previous.isManual &&
      !current.isManual &&
      previous.hasReliableTimestamp &&
      current.hasReliableTimestamp &&
      _validCode.hasMatch(previous.hash) &&
      previous.hash == current.hash;

  static ScheduleVersionProjection project(
    List<ScheduleVersion> versions, {
    required bool hideUnchanged,
  }) {
    final visible = <int>[];
    final representatives = List<int>.filled(versions.length, -1);
    final unchanged = List<bool>.filled(versions.length, false);
    var runStart = 0;
    for (var i = 0; i < versions.length; i++) {
      unchanged[i] = i > 0 && _isRepeat(versions[i - 1], versions[i]);
      if (!hideUnchanged) {
        visible.add(i);
        representatives[i] = i;
        continue;
      }
      if (i > 0 && !unchanged[i]) {
        visible.add(i - 1);
        for (var j = runStart; j < i; j++) {
          representatives[j] = i - 1;
        }
        runStart = i;
      }
      if (i == versions.length - 1) {
        visible.add(i);
        for (var j = runStart; j <= i; j++) {
          representatives[j] = i;
        }
      }
    }
    return ScheduleVersionProjection._(visible, representatives, unchanged);
  }
}
