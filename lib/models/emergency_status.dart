/// A timestamped observation of the current DTEK emergency notice.
class EmergencyObservation {
  final bool active;
  final int observedAt;
  final bool confirmed;

  const EmergencyObservation(this.active, this.observedAt,
      {this.confirmed = false});

  static const maxAge = Duration(minutes: 15);

  bool isValidAt(int now) =>
      observedAt > 0 &&
      observedAt <= now + const Duration(minutes: 1).inMilliseconds &&
      now - observedAt <= maxAge.inMilliseconds;

  Map<String, Object> toTransport() =>
      {'schemaVersion': 1, 'active': active, 'observedAt': observedAt};
}

/// Unknown and stale observations must never be presented as a cancellation.
class EmergencyStatus {
  final bool? active;
  final int observedAt;
  final int changedAt;
  final int seenAt;
  final int? cancellationSince;

  const EmergencyStatus(
      {this.active,
      this.observedAt = 0,
      this.changedAt = 0,
      this.seenAt = 0,
      this.cancellationSince});

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
    // A missing modal needs a second fresh observation; a transient/truncated
    // response must not announce that an ongoing emergency has ended.
    if (active == true && !observation.active && !observation.confirmed) {
      final first = cancellationSince;
      if (first == null || time - first > confirmationWindow.inMilliseconds) {
        return EmergencyStatus(
            active: active,
            observedAt: observedAt,
            changedAt: changedAt,
            seenAt: time,
            cancellationSince: time);
      }
      if (time - first < cancellationDelay.inMilliseconds) {
        return EmergencyStatus(
            active: active,
            observedAt: observedAt,
            changedAt: changedAt,
            seenAt: time,
            cancellationSince: first);
      }
    }
    return EmergencyStatus(
        active: observation.active,
        observedAt: time,
        seenAt: time,
        changedAt: active == observation.active ? changedAt : time);
  }

  Map<String, Object?> toJson() => {
        'active': active,
        'observedAt': observedAt,
        'changedAt': changedAt,
        'seenAt': seenAt,
        'cancellationSince': cancellationSince
      };

  factory EmergencyStatus.fromJson(Map<String, dynamic> data) {
    if (data['active'] is! bool ||
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
        cancellationSince: data['cancellationSince'] as int?);
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
    final observation =
        EmergencyObservation(active, observedAt, confirmed: true);
    return observation.isValidAt(now)
        ? EmergencyPush(observation, expiresAt)
        : null;
  }
}
