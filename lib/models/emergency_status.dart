/// A timestamped observation of the current DTEK emergency notice.
class EmergencyObservation {
  final bool active;
  final int observedAt;
  final bool confirmed;
  final bool isPossible;
  final String noticeText;

  const EmergencyObservation(this.active, this.observedAt,
      {this.confirmed = false, this.isPossible = false, this.noticeText = ''});

  static const maxAge = Duration(minutes: 15);

  bool isValidAt(int now) =>
      observedAt > 0 &&
      observedAt <= now + const Duration(minutes: 1).inMilliseconds &&
      now - observedAt <= maxAge.inMilliseconds;

  Map<String, Object> toTransport() => {
        'schemaVersion': 1,
        'active': active,
        'observedAt': observedAt,
        'confirmed': confirmed,
        'isPossible': isPossible,
        'noticeText': noticeText
      };
}

/// Unknown and stale observations must never be presented as a cancellation.
class EmergencyStatus {
  final bool? active;
  final int observedAt;
  final int changedAt;
  final int seenAt;
  final int? cancellationSince;
  final bool isPossible;
  final String noticeText;

  const EmergencyStatus(
      {this.active,
      this.observedAt = 0,
      this.changedAt = 0,
      this.seenAt = 0,
      this.cancellationSince,
      this.isPossible = false,
      this.noticeText = ''});

  static const freshness = Duration(minutes: 30);
  static const cancellationDelay = Duration(seconds: 30);
  static const confirmationWindow = Duration(minutes: 20);

  bool isFreshAt(int now) =>
      active != null &&
      observedAt > 0 &&
      observedAt <= now + const Duration(minutes: 1).inMilliseconds &&
      now - observedAt <= freshness.inMilliseconds;

  EmergencyStatus accept(EmergencyObservation observation, int now) {
    final confirmsPendingCancellation = observation.confirmed &&
        cancellationSince != null &&
        active == true &&
        !observation.active;
    if (!observation.isValidAt(now) ||
        observation.observedAt < seenAt ||
        (observation.observedAt == seenAt && !confirmsPendingCancellation)) {
      return this;
    }
    final time = observation.observedAt;
    // Legacy observations without verified page metadata still need a second
    // capture. Fresh parsed pages and confirmed pushes apply immediately.
    if (active == true && !observation.active && !observation.confirmed) {
      final first = cancellationSince;
      if (first == null || time - first > confirmationWindow.inMilliseconds) {
        return EmergencyStatus(
            active: active,
            observedAt: observedAt,
            changedAt: changedAt,
            seenAt: time,
            isPossible: isPossible,
            noticeText: noticeText,
            cancellationSince: time);
      }
      if (time - first < cancellationDelay.inMilliseconds) {
        return EmergencyStatus(
            active: active,
            observedAt: observedAt,
            changedAt: changedAt,
            seenAt: time,
            isPossible: isPossible,
            noticeText: noticeText,
            cancellationSince: first);
      }
    }
    return EmergencyStatus(
        active: observation.active,
        observedAt: time,
        seenAt: time,
        isPossible: observation.isPossible,
        noticeText: observation.noticeText,
        changedAt:
            active == observation.active && isPossible == observation.isPossible
                ? changedAt
                : time);
  }

  Map<String, Object?> toJson() => {
        'active': active,
        'observedAt': observedAt,
        'changedAt': changedAt,
        'seenAt': seenAt,
        'cancellationSince': cancellationSince,
        'isPossible': isPossible,
        'noticeText': noticeText,
      };

  factory EmergencyStatus.fromJson(Map<String, dynamic> data) {
    if ((data['isPossible'] != null && data['isPossible'] is! bool) ||
        (data['noticeText'] != null && data['noticeText'] is! String) ||
        data['active'] is! bool ||
        !['observedAt', 'changedAt', 'seenAt']
            .every((key) => data[key] is int && (data[key] as int) > 0) ||
        (data['cancellationSince'] != null &&
            data['cancellationSince'] is! int) ||
        data['changedAt'] > data['observedAt'] ||
        data['observedAt'] > data['seenAt'] ||
        (data['cancellationSince'] != null &&
            (data['active'] != true ||
                data['cancellationSince'] < data['observedAt'] ||
                data['cancellationSince'] > data['seenAt']))) {
      throw const FormatException('Invalid emergency status');
    }
    return EmergencyStatus(
        active: data['active'] as bool,
        observedAt: data['observedAt'] as int,
        changedAt: data['changedAt'] as int,
        seenAt: data['seenAt'] as int,
        cancellationSince: data['cancellationSince'] as int?,
        isPossible: data['isPossible'] as bool? ?? false,
        noticeText: data['noticeText'] as String? ?? '');
  }
}

class EmergencyPush {
  final EmergencyObservation observation;
  final int expiresAt;
  const EmergencyPush(this.observation, this.expiresAt);

  static bool isEmergency(Map<String, dynamic> data) =>
      data['group'] == 'EMERGENCY' ||
      ['emergency_alert', 'emergency_started', 'emergency_cancelled']
          .contains(data['type']);

  static EmergencyPush? parse(Map<String, dynamic> data, int now) {
    final value = data['isEmergency'];
    final bool? active = switch (value) {
      true || 'true' => true,
      false || 'false' => false,
      _ => null,
    };
    if (!isEmergency(data) || active == null) {
      return null;
    }
    final observedAt = int.tryParse('${data['observedAt']}');
    final expiresAt = int.tryParse('${data['expiresAt']}');
    if (observedAt == null ||
        expiresAt == null ||
        expiresAt <= now ||
        expiresAt <= observedAt ||
        expiresAt - observedAt > EmergencyObservation.maxAge.inMilliseconds) {
      return null;
    }
    final possible = data['isPossible'];
    if (possible != null &&
        ![true, false, 'true', 'false'].contains(possible)) {
      return null;
    }
    if (data['noticeText'] != null && data['noticeText'] is! String) {
      return null;
    }
    final observation = EmergencyObservation(active, observedAt,
        confirmed: true,
        isPossible: active && (possible == true || possible == 'true'),
        noticeText: data['noticeText'] as String? ?? '');
    return observation.isValidAt(now)
        ? EmergencyPush(observation, expiresAt)
        : null;
  }
}
