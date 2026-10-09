import 'package:flutter/material.dart';

/// Категорія досягнення.
enum AchievementCategory {
  tutorial, // 👶 Перші кроки
  casual, // 🌤 Повсякденність
  survival, // 💀 Виживання
  oracle, // 🔮 Оракул
  lifestyle, // ⚡ Стиль життя
  secret, // 🥚 Секретні
}

/// Визначення одного досягнення (статичне).
class AchievementDef {
  final String id;
  final String title;
  final String description;
  final String conditionText; // Текст умови (для НЕ секретних)
  final AchievementCategory category;
  final IconData icon;
  final Color color;
  final bool isSecret;

  const AchievementDef({
    required this.id,
    required this.title,
    required this.description,
    required this.conditionText,
    required this.category,
    required this.icon,
    required this.color,
    this.isSecret = false,
  });
}

/// Стан досягнення у користувача.
class AchievementState {
  final String achievementId;
  final bool unlocked;
  final DateTime? unlockedAt;
  final double progress; // 0.0 — 1.0 (для прогрес-бару)

  const AchievementState({
    required this.achievementId,
    this.unlocked = false,
    this.unlockedAt,
    this.progress = 0.0,
  });

  Map<String, dynamic> toMap() => {
        'achievement_id': achievementId,
        'unlocked': unlocked ? 1 : 0,
        'unlocked_at': unlockedAt?.toIso8601String(),
        'progress': progress,
      };

  factory AchievementState.fromMap(Map<String, dynamic> map) {
    return AchievementState(
      achievementId: map['achievement_id'] as String,
      unlocked: (map['unlocked'] as int?) == 1,
      unlockedAt: map['unlocked_at'] != null
          ? DateTime.tryParse(map['unlocked_at'] as String)
          : null,
      progress: (map['progress'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

/// Каталог усіх досягнень.
class AchievementCatalog {
  static const List<AchievementDef> all = [
    // ═══════════════════════════════════════
    // � ПЕРШІ КРОКИ (Tutorial)
    // ═══════════════════════════════════════
    AchievementDef(
      id: 'citizen',
      title: 'Громадянин',
      description: 'Обрати свою групу відключень.',
      conditionText: 'Перший вибір групи в налаштуваннях.',
      category: AchievementCategory.tutorial,
      icon: Icons.how_to_reg,
      color: Color(0xFF43A047),
    ),
    AchievementDef(
      id: 'connected',
      title: 'На зв\'язку',
      description: 'Увімкнути сповіщення про відключення.',
      conditionText: 'Активовано хоча б одне сповіщення.',
      category: AchievementCategory.tutorial,
      icon: Icons.notifications_active,
      color: Color(0xFF1E88E5),
    ),
    AchievementDef(
      id: 'always_visible',
      title: 'Завжди перед очима',
      description: 'Використати віджет на головному екрані.',
      conditionText: 'Відкрити застосунок через віджет.',
      category: AchievementCategory.tutorial,
      icon: Icons.widgets,
      color: Color(0xFF00ACC1),
    ),

    // ═══════════════════════════════════════
    // 🌤 ПОВСЯКДЕННІСТЬ (Casual)
    // ═══════════════════════════════════════
    AchievementDef(
      id: 'seemed_like',
      title: 'Здалося',
      description: 'Світло зникло та повернулося менш ніж за 5 хвилин.',
      conditionText: 'Інтервал offline < 5 хвилин.',
      category: AchievementCategory.casual,
      icon: Icons.blur_on,
      color: Color(0xFFFFB300),
    ),
    AchievementDef(
      id: 'bright_streak',
      title: 'Світла смуга',
      description: 'Прожити цілий день без жодного відключення.',
      conditionText: 'За добу (00:00–23:59) жодного offline.',
      category: AchievementCategory.casual,
      icon: Icons.wb_sunny,
      color: Color(0xFFFDD835),
    ),
    AchievementDef(
      id: 'situation_control',
      title: 'Контроль ситуації',
      description: 'Зайти в застосунок 5 разів за один день.',
      conditionText: 'Лічильник сесій за добу ≥ 5.',
      category: AchievementCategory.casual,
      icon: Icons.repeat,
      color: Color(0xFF26A69A),
    ),

    // ═══════════════════════════════════════
    // 💀 ВИЖИВАННЯ (Survival)
    // ═══════════════════════════════════════
    AchievementDef(
      id: 'initiated_into_darkness',
      title: 'Посвячений у темряву',
      description: 'Пережити перше зафіксоване відключення.',
      conditionText: 'Перша подія offline у базі даних.',
      category: AchievementCategory.survival,
      icon: Icons.flash_off,
      color: Color(0xFFE53935),
    ),
    AchievementDef(
      id: 'dungeon_child',
      title: 'Дитя підземелля',
      description: 'Провести сумарно 100 годин без світла.',
      conditionText: 'Сумарний час offline > 100 годин.',
      category: AchievementCategory.survival,
      icon: Icons.nightlight_round,
      color: Color(0xFF7B1FA2),
    ),
    AchievementDef(
      id: 'born_in_darkness',
      title: 'Народжений у темряві',
      description: '1000 годин без світла. Ви адаптувалися.',
      conditionText: 'Сумарний час offline > 1000 годин.',
      category: AchievementCategory.survival,
      icon: Icons.visibility_off,
      color: Color(0xFF1A237E),
    ),
    AchievementDef(
      id: 'marathon_runner',
      title: 'Марафонець',
      description: 'Одне безперервне відключення тривало понад 12 годин.',
      conditionText: 'Тривалість одного інтервалу offline > 12 год.',
      category: AchievementCategory.survival,
      icon: Icons.directions_run,
      color: Color(0xFFFF6F00),
    ),
    AchievementDef(
      id: 'blackout_survivor',
      title: 'Переможець блекауту',
      description: 'Доба без світла (менше ніж 2 години зі світлом за 24 год).',
      conditionText: 'Сумарний час offline > 22 год за календарну добу.',
      category: AchievementCategory.survival,
      icon: Icons.shield,
      color: Color(0xFF212121),
    ),

    // ═══════════════════════════════════════
    // 🔮 ОРАКУЛ (Oracle)
    // ═══════════════════════════════════════
    AchievementDef(
      id: 'deceived_investor',
      title: 'Ошуканий вкладник',
      description: 'Відключили в «білій зоні» (коли світло гарантовано).',
      conditionText: 'Графік — yes, а статус offline > 15 хвилин.',
      category: AchievementCategory.oracle,
      icon: Icons.money_off,
      color: Color(0xFFF9A825),
    ),
    AchievementDef(
      id: 'hachiko',
      title: 'Хатіко',
      description: 'Світло дали із запізненням понад годину.',
      conditionText:
          'Графік змінився на yes, сенсор — online лише через 60+ хв.',
      category: AchievementCategory.oracle,
      icon: Icons.pets,
      color: Color(0xFF8D6E63),
    ),
    AchievementDef(
      id: 'matrix_glitch',
      title: 'Збій у Матриці',
      description: 'Графік ДТЕК збігся з реальністю на 100% за тиждень.',
      conditionText: 'Точність = 100% за 7 днів.',
      category: AchievementCategory.oracle,
      icon: Icons.psychology,
      color: Color(0xFF00E676),
    ),
    AchievementDef(
      id: 'archivist',
      title: 'Архіваріус',
      description: 'Переглянути історію графіків за минулий місяць.',
      conditionText: 'Перегляд історії на дату Now - 30 днів.',
      category: AchievementCategory.oracle,
      icon: Icons.history_edu,
      color: Color(0xFF5C6BC0),
    ),

    // ═══════════════════════════════════════
    // ⚡ СТИЛЬ ЖИТТЯ (Lifestyle)
    // ═══════════════════════════════════════
    AchievementDef(
      id: 'night_watch',
      title: 'Нічний перекус',
      description: 'Світло увімкнули між 03:00 та 05:00 ранку.',
      conditionText: 'Подія online з таймстемпом у інтервалі 03:00–05:00.',
      category: AchievementCategory.lifestyle,
      icon: Icons.bedtime,
      color: Color(0xFF0D47A1),
    ),
    AchievementDef(
      id: 'light_disco',
      title: 'Світлодискотека',
      description: 'Світло увімкнулося і вимкнулося 5 разів за одну годину.',
      conditionText: '5 пар подій online/offline за 60 хвилин.',
      category: AchievementCategory.lifestyle,
      icon: Icons.flare,
      color: Color(0xFFD500F9),
    ),

    // ═══════════════════════════════════════
    // 🥚 СЕКРЕТНІ (Easter Eggs)
    // ═══════════════════════════════════════
    AchievementDef(
      id: 'nervous_tic',
      title: 'Нервовий тик',
      description: 'Оновити дані 20 разів за хвилину.',
      conditionText: '???',
      category: AchievementCategory.secret,
      icon: Icons.touch_app,
      color: Color(0xFFFF1744),
      isSecret: true,
    ),
    AchievementDef(
      id: 'paranoid',
      title: 'Параноїк',
      description: 'Зайти в налаштування і 10 разів змінити тему або мову.',
      conditionText: '???',
      category: AchievementCategory.secret,
      icon: Icons.swap_horiz,
      color: Color(0xFF651FFF),
      isSecret: true,
    ),
    AchievementDef(
      id: 'second_wind',
      title: 'Друге дихання',
      description:
          'Світло увімкнули лише на 30 хвилин між двома відключеннями.',
      conditionText: '???',
      category: AchievementCategory.secret,
      icon: Icons.air,
      color: Color(0xFF00BFA5),
      isSecret: true,
    ),
  ];

  static AchievementDef? getById(String id) {
    try {
      return all.firstWhere((a) => a.id == id);
    } catch (_) {
      return null;
    }
  }

  static List<AchievementDef> byCategory(AchievementCategory cat) =>
      all.where((a) => a.category == cat).toList();

  static String categoryTitle(AchievementCategory cat) {
    switch (cat) {
      case AchievementCategory.tutorial:
        return '👶  Перші кроки';
      case AchievementCategory.casual:
        return '🌤  Повсякденність';
      case AchievementCategory.survival:
        return '💀  Виживання';
      case AchievementCategory.oracle:
        return '🔮  Оракул';
      case AchievementCategory.lifestyle:
        return '⚡  Стиль життя';
      case AchievementCategory.secret:
        return '🥚  Секретні';
    }
  }

  static String categorySubtitle(AchievementCategory cat) {
    switch (cat) {
      case AchievementCategory.tutorial:
        return 'Досягнення за опанування застосунку';
      case AchievementCategory.casual:
        return 'Легкі ситуативні досягнення';
      case AchievementCategory.survival:
        return 'Досягнення за стійкість і час без світла';
      case AchievementCategory.oracle:
        return 'Графіки проти реальності';
      case AchievementCategory.lifestyle:
        return 'Ситуативні та кумедні досягнення';
      case AchievementCategory.secret:
        return 'Приховані досягнення';
    }
  }
}
