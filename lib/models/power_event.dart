/// Модель події електроенергії від Firebase RTDB сенсора.
class PowerEvent {
  final int? id;
  final String firebaseKey;
  final String status; // 'online' / 'offline'
  final DateTime timestamp;
  final String device;
  final bool isManual;

  PowerEvent({
    this.id,
    required this.firebaseKey,
    required this.status,
    required this.timestamp,
    this.device = '',
    this.isManual = false,
  });

  bool get isOnline => status.toLowerCase() == 'online';
  bool get isOffline => status.toLowerCase() == 'offline';

  Map<String, dynamic> toMap() => {
        'firebase_key': firebaseKey,
        'status': status,
        'timestamp':
            '${timestamp.year}-${timestamp.month.toString().padLeft(2, '0')}-${timestamp.day.toString().padLeft(2, '0')} '
                '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}:${timestamp.second.toString().padLeft(2, '0')}',
        'device': device,
        'is_manual': isManual ? 1 : 0,
        'synced_at': DateTime.now().toIso8601String(),
      };

  factory PowerEvent.fromMap(Map<String, dynamic> map) {
    return PowerEvent(
      id: map['id'] as int?,
      firebaseKey: map['firebase_key'] as String,
      status: (map['status'] as String).toLowerCase(),
      timestamp: DateTime.parse(map['timestamp'] as String),
      device: (map['device'] as String?) ?? '',
      isManual: (map['is_manual'] as int?) == 1,
    );
  }

  factory PowerEvent.fromFirebase(String key, Map<String, dynamic> data) {
    final timestamp = _parseTimestamp(data['timestamp'] as String? ?? '');
    if (timestamp == null) {
      throw FormatException('Invalid timestamp for event $key');
    }
    return PowerEvent(
      firebaseKey: key,
      status: (data['status'] as String? ?? 'unknown').toLowerCase(),
      timestamp: timestamp,
      device: data['device'] as String? ?? '',
      isManual: false, // Firebase events are never manual by default
    );
  }

  static DateTime? _parseTimestamp(String ts) {
    // Формат: "YYYY-MM-DD HH:mm:ss" або "YYYY-M-D H:m:s"
    try {
      if (ts.isEmpty) return null;

      // Спробуємо стандартний парсер
      try {
        return DateTime.parse(ts);
      } catch (_) {
        // Якщо стандартний парсер не зміг, спробуємо розібрати вручну (для випадків типу "2026-2-11 3:14:35")
        final parts = ts.split(' ');
        if (parts.length != 2) return null;

        final dateParts = parts[0].split('-');
        final timeParts = parts[1].split(':');

        if (dateParts.length != 3 || timeParts.length != 3) {
          return null;
        }

        final year = int.parse(dateParts[0]);
        final month = int.parse(dateParts[1]);
        final day = int.parse(dateParts[2]);
        final hour = int.parse(timeParts[0]);
        final minute = int.parse(timeParts[1]);
        final second = int.parse(timeParts[2]);

        return DateTime(year, month, day, hour, minute, second);
      }
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() => 'PowerEvent($status @ $timestamp, key=$firebaseKey)';
}

/// Інтервал відключення електроенергії (offline → online).
class PowerOutageInterval {
  final DateTime start; // момент offline
  final DateTime? end; // момент online (null = ще без світла)
  final int? startEventId;
  final int? endEventId;

  PowerOutageInterval({
    required this.start,
    this.end,
    this.startEventId,
    this.endEventId,
  });

  Duration get duration => (end ?? DateTime.now()).difference(start);

  bool get isOngoing => end == null;

  String get durationString {
    final d = duration;
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    if (hours > 0 && minutes > 0) return '${hours}г ${minutes}хв';
    if (hours > 0) return '${hours}г';
    return '${minutes}хв';
  }

  /// Чи перетинається цей інтервал з вказаною датою.
  bool overlapsDate(DateTime date) {
    final dayStart = DateTime(date.year, date.month, date.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final intervalEnd = end ?? DateTime.now();
    return start.isBefore(dayEnd) && intervalEnd.isAfter(dayStart);
  }

  /// Час відключення в межах конкретної години (0-59 хвилин offline).
  int minutesOfflineInHour(DateTime date, int hour) {
    final hourStart = DateTime(date.year, date.month, date.day, hour);
    final hourEnd = hourStart.add(const Duration(hours: 1));
    final intervalEnd = end ?? DateTime.now();

    if (start.isAfter(hourEnd) || intervalEnd.isBefore(hourStart)) return 0;

    final effectiveStart = start.isAfter(hourStart) ? start : hourStart;
    final effectiveEnd = intervalEnd.isBefore(hourEnd) ? intervalEnd : hourEnd;

    return effectiveEnd.difference(effectiveStart).inMinutes.clamp(0, 60);
  }
}
