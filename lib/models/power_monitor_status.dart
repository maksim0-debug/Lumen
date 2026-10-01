import 'package:flutter/foundation.dart';

/// Тристановий стан реального електропостачання.
enum RealPowerState {
  online,
  offline,
  unknown;

  bool get isOnline => this == RealPowerState.online;
  bool get isOffline => this == RealPowerState.offline;
  bool get isUnknown => this == RealPowerState.unknown;

  /// Відображуваний текстовий лейбл для бейджа/кнопки
  String get label {
    switch (this) {
      case RealPowerState.online:
        return 'ON';
      case RealPowerState.offline:
        return 'OFF';
      case RealPowerState.unknown:
        return 'UNKNOWN';
    }
  }

  /// Парсинг зі стандартного рядка ('online', 'offline', 'unknown')
  static RealPowerState fromString(String? value) {
    if (value == null) return RealPowerState.unknown;
    switch (value.trim().toLowerCase()) {
      case 'online':
        return RealPowerState.online;
      case 'offline':
        return RealPowerState.offline;
      default:
        return RealPowerState.unknown;
    }
  }

  String toSerializedString() {
    switch (this) {
      case RealPowerState.online:
        return 'online';
      case RealPowerState.offline:
        return 'offline';
      case RealPowerState.unknown:
        return 'unknown';
    }
  }
}

/// Причина визначення поточного статусу (діагностичні метадані)
enum PowerStateReason {
  fresh, // Дані свіжі
  staleLastSeen, // last_seen старіший за допустимий TTL
  staleEvent, // Подія старіша за загальний TTL при відсутності last_seen
  networkError, // Помилка синхронізації з Firebase (>= 3 помилок або немає зв'язку)
  notConfigured, // URL не налаштовано або моніторинг вимкнено
  noData, // База даних порожня, немає жодних подій
  disabled; // Моніторинг вимкнено користувачем

  /// Людиночитне коротке пояснення для UI/підказок
  String get userMessage {
    switch (this) {
      case PowerStateReason.fresh:
        return 'Дані актуальні.';
      case PowerStateReason.staleLastSeen:
        return 'Сенсор не виходив на зв\'язок довше допустимого таймауту.';
      case PowerStateReason.staleEvent:
        return 'Останнє оновлення занадто старе (немає свіжих подій).';
      case PowerStateReason.networkError:
        return 'Помилка синхронізації з Firebase (перевірте інтернет або доступ).';
      case PowerStateReason.notConfigured:
        return 'Моніторинг не налаштовано (вкажіть коректний URL у налаштуваннях).';
      case PowerStateReason.noData:
        return 'Немає записів у базі даних моніторингу.';
      case PowerStateReason.disabled:
        return 'Моніторинг вимкнено користувачем.';
    }
  }
}

/// Незмінний знімок поточного стану сенсора
@immutable
class PowerMonitorSnapshot {
  final RealPowerState status;
  final PowerStateReason reason;
  final DateTime? lastSeen;
  final DateTime? lastEventTime;
  final DateTime? lastSyncTime;
  final String? errorMessage;
  final Duration ttl;

  const PowerMonitorSnapshot({
    required this.status,
    required this.reason,
    this.lastSeen,
    this.lastEventTime,
    this.lastSyncTime,
    this.errorMessage,
    this.ttl = const Duration(minutes: 25),
  });

  factory PowerMonitorSnapshot.unknown({
    PowerStateReason reason = PowerStateReason.noData,
    DateTime? lastSeen,
    DateTime? lastEventTime,
    DateTime? lastSyncTime,
    String? errorMessage,
    Duration ttl = const Duration(minutes: 25),
  }) {
    return PowerMonitorSnapshot(
      status: RealPowerState.unknown,
      reason: reason,
      lastSeen: lastSeen,
      lastEventTime: lastEventTime,
      lastSyncTime: lastSyncTime,
      errorMessage: errorMessage,
      ttl: ttl,
    );
  }

  bool get isStale =>
      reason == PowerStateReason.staleLastSeen ||
      reason == PowerStateReason.staleEvent;

  PowerMonitorSnapshot copyWith({
    RealPowerState? status,
    PowerStateReason? reason,
    DateTime? lastSeen,
    DateTime? lastEventTime,
    DateTime? lastSyncTime,
    String? errorMessage,
    Duration? ttl,
  }) {
    return PowerMonitorSnapshot(
      status: status ?? this.status,
      reason: reason ?? this.reason,
      lastSeen: lastSeen ?? this.lastSeen,
      lastEventTime: lastEventTime ?? this.lastEventTime,
      lastSyncTime: lastSyncTime ?? this.lastSyncTime,
      errorMessage: errorMessage ?? this.errorMessage,
      ttl: ttl ?? this.ttl,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PowerMonitorSnapshot &&
          runtimeType == other.runtimeType &&
          status == other.status &&
          reason == other.reason &&
          lastSeen == other.lastSeen &&
          lastEventTime == other.lastEventTime &&
          lastSyncTime == other.lastSyncTime &&
          errorMessage == other.errorMessage &&
          ttl == other.ttl;

  @override
  int get hashCode => Object.hash(
        status,
        reason,
        lastSeen,
        lastEventTime,
        lastSyncTime,
        errorMessage,
        ttl,
      );

  @override
  String toString() =>
      'PowerMonitorSnapshot(status: $status, reason: $reason, lastSeen: $lastSeen, lastEvent: $lastEventTime)';
}
