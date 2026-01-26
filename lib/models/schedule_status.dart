enum LightStatus {
  on, // yes - Світло є
  off, // no - Світла немає
  semiOn, // first - Світла немає перші 30 хв (Червоний -> Зелений)
  semiOff, // second - Світла немає другі 30 хв (Зелений -> Червоний)
  maybe, // maybe - Можливе відключення (Сірий)
  unknown 
}

class DailySchedule {
  final List<LightStatus> hours;
  DailySchedule(this.hours);

  factory DailySchedule.empty() {
    return DailySchedule(List.filled(24, LightStatus.unknown));
  }

  bool get isEmpty => hours.every((h) => h == LightStatus.unknown);

  int get totalOutageMinutes {
    int minutes = 0;
    for (var h in hours) {
      if (h == LightStatus.off)
        minutes += 60;
      else if (h == LightStatus.semiOn || h == LightStatus.semiOff)
        minutes += 30;
    }
    return minutes;
  }

  String get scheduleHash => toEncodedString();

  String toEncodedString() {
    final buffer = StringBuffer();
    for (var status in hours) {
      switch (status) {
        case LightStatus.on:
          buffer.write('0');
          break;
        case LightStatus.off:
          buffer.write('1');
          break;
        case LightStatus.semiOn:
          buffer.write('2');
          break; 
        case LightStatus.semiOff:
          buffer.write('3');
          break; 
        case LightStatus.maybe:
          buffer.write('4');
          break;
        default:
          buffer.write('9');
          break;
      }
    }
    return buffer.toString();
  }

  factory DailySchedule.fromEncodedString(String encoded) {
    if (encoded.length != 24) return DailySchedule.empty();

    List<LightStatus> hours = [];
    for (int i = 0; i < encoded.length; i++) {
      var char = encoded[i];
      switch (char) {
        case '0':
          hours.add(LightStatus.on);
          break;
        case '1':
          hours.add(LightStatus.off);
          break;
        case '2':
          hours.add(LightStatus.semiOn);
          break;
        case '3':
          hours.add(LightStatus.semiOff);
          break;
        case '4':
          hours.add(LightStatus.maybe);
          break;
        default:
          hours.add(LightStatus.unknown);
          break;
      }
    }
    return DailySchedule(hours);
  }
}

class FullSchedule {
  final DailySchedule today;
  final DailySchedule tomorrow;
  final String lastUpdatedSource; 

  FullSchedule({
    required this.today,
    required this.tomorrow,
    this.lastUpdatedSource = "",
  });

  factory FullSchedule.empty() {
    return FullSchedule(
      today: DailySchedule.empty(),
      tomorrow: DailySchedule.empty(),
      lastUpdatedSource: "Немає даних",
    );
  }
}

class ScheduleVersion {
  final String hash; 
  final DateTime savedAt; 
  final int outageMinutes; 

  ScheduleVersion({
    required this.hash,
    required this.savedAt,
    required this.outageMinutes,
  });

  DailySchedule toSchedule() => DailySchedule.fromEncodedString(hash);

  String get timeString {
    final now = DateTime.now();
    bool isDifferentDay =
        savedAt.year != now.year || savedAt.month != now.month || savedAt.day != now.day;

    final timeStr = "${savedAt.hour.toString().padLeft(2, '0')}:${savedAt.minute.toString().padLeft(2, '0')}";
    
    if (isDifferentDay) {
       return "${savedAt.day.toString().padLeft(2, '0')}.${savedAt.month.toString().padLeft(2, '0')} $timeStr";
    }
    return timeStr;
  }

  String get outageString {
    final hours = outageMinutes ~/ 60;
    final mins = outageMinutes % 60;
    if (mins == 0) return "${hours}г";
    return "${hours}г ${mins}хв";
  }

  Map<String, dynamic> toJson() => {
        'hash': hash,
        'savedAt': savedAt.toIso8601String(),
        'outageMinutes': outageMinutes,
      };

  factory ScheduleVersion.fromJson(Map<String, dynamic> json) {
    return ScheduleVersion(
      hash: json['hash'] as String,
      savedAt: DateTime.parse(json['savedAt'] as String),
      outageMinutes: json['outageMinutes'] as int,
    );
  }

  factory ScheduleVersion.fromSchedule(DailySchedule schedule, {DateTime? at}) {
    return ScheduleVersion(
      hash: schedule.scheduleHash,
      savedAt: at ?? DateTime.now(),
      outageMinutes: schedule.totalOutageMinutes,
    );
  }
}
