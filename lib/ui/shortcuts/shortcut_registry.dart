import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/data_source_mode.dart';
import 'app_intents.dart';
import 'app_key_activator.dart';

/// Single item for the shortcut cheatsheet dialog.
class ShortcutHelpItem {
  final String actionName;
  final List<String> keyLabels;
  final String description;

  const ShortcutHelpItem({
    required this.actionName,
    required this.keyLabels,
    required this.description,
  });
}

/// Category grouping for shortcut cheatsheet.
class ShortcutCategory {
  final String title;
  final IconData icon;
  final List<ShortcutHelpItem> items;

  const ShortcutCategory({
    required this.title,
    required this.icon,
    required this.items,
  });
}

/// Central registry of all keyboard shortcuts and their metadata.
class AppKeyboardShortcuts {
  AppKeyboardShortcuts._();

  /// Common shortcuts for standard secondary screens / subpages (Esc, F1, ?).
  static final Map<ShortcutActivator, Intent> modalShortcuts = {
    const SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false):
        const CloseTopModalOrGoBackIntent(),
    const SingleActivator(LogicalKeyboardKey.f1, includeRepeats: false):
        const ToggleShortcutHelpIntent(),
    const SingleActivator(LogicalKeyboardKey.slash,
        shift: true, includeRepeats: false): const ToggleShortcutHelpIntent(),
    const CharacterActivator('?', includeRepeats: false):
        const ToggleShortcutHelpIntent(),
  };

  // Cached static shortcuts maps to eliminate heap allocation on every rebuild.
  static final Map<ShortcutActivator, Intent> _homeShortcuts = {
    // --- Navigation (Dates) ---
    const AppShortcutActivator(LogicalKeyboardKey.keyA,
        physicalKey: PhysicalKeyboardKey.keyA): const NavigateDateIntent(-1),
    const SingleActivator(LogicalKeyboardKey.arrowLeft):
        const NavigateDateIntent(-1),
    const SingleActivator(LogicalKeyboardKey.numpad4):
        const NavigateDateIntent(-1),

    const AppShortcutActivator(LogicalKeyboardKey.keyD,
        physicalKey: PhysicalKeyboardKey.keyD): const NavigateDateIntent(1),
    const SingleActivator(LogicalKeyboardKey.arrowRight):
        const NavigateDateIntent(1),
    const SingleActivator(LogicalKeyboardKey.numpad6):
        const NavigateDateIntent(1),

    const AppShortcutActivator(LogicalKeyboardKey.keyT,
        physicalKey: PhysicalKeyboardKey.keyT): const JumpToTodayIntent(),
    const SingleActivator(LogicalKeyboardKey.home): const JumpToTodayIntent(),
    const SingleActivator(LogicalKeyboardKey.numpad5):
        const JumpToTodayIntent(),

    const AppShortcutActivator(LogicalKeyboardKey.keyY,
        physicalKey: PhysicalKeyboardKey.keyY,
        includeRepeats: false): const JumpToYesterdayIntent(),
    const AppShortcutActivator(LogicalKeyboardKey.keyN,
        physicalKey: PhysicalKeyboardKey.keyN,
        includeRepeats: false): const JumpToTomorrowIntent(),

    const AppShortcutActivator(LogicalKeyboardKey.keyC,
        physicalKey: PhysicalKeyboardKey.keyC,
        includeRepeats: false): const OpenDatePickerIntent(),
    const AppShortcutActivator(LogicalKeyboardKey.keyP,
        physicalKey: PhysicalKeyboardKey.keyP,
        includeRepeats: false): const OpenDatePickerIntent(),

    // --- Clipboard ---
    const AppShortcutActivator(LogicalKeyboardKey.keyC,
        physicalKey: PhysicalKeyboardKey.keyC,
        control: true): const CopyScheduleSummaryIntent(),

    // --- Data Source Mode (Forecast vs Real) ---
    // Note: Tab, ArrowUp and ArrowDown are NOT used here to preserve standard page scrolling and focus.
    const AppShortcutActivator(LogicalKeyboardKey.keyW,
            physicalKey: PhysicalKeyboardKey.keyW):
        const SetDataSourceModeIntent(DataSourceMode.predicted),
    const SingleActivator(LogicalKeyboardKey.numpad8):
        const SetDataSourceModeIntent(DataSourceMode.predicted),

    const AppShortcutActivator(LogicalKeyboardKey.keyS,
            physicalKey: PhysicalKeyboardKey.keyS):
        const SetDataSourceModeIntent(DataSourceMode.real),
    const SingleActivator(LogicalKeyboardKey.numpad2):
        const SetDataSourceModeIntent(DataSourceMode.real),

    const AppShortcutActivator(LogicalKeyboardKey.keyM,
            physicalKey: PhysicalKeyboardKey.keyM):
        const ToggleDataSourceModeIntent(),
    const SingleActivator(LogicalKeyboardKey.space):
        const ToggleDataSourceModeIntent(),
    const SingleActivator(LogicalKeyboardKey.numpad0):
        const ToggleDataSourceModeIntent(),

    // --- Groups (Cherhy) ---
    // Upwards increases group number (+1), downwards decreases (-1).
    const SingleActivator(LogicalKeyboardKey.arrowUp, control: true):
        const CycleGroupIntent(1),
    const SingleActivator(LogicalKeyboardKey.numpad8, control: true):
        const CycleGroupIntent(1),
    const SingleActivator(LogicalKeyboardKey.arrowDown, control: true):
        const CycleGroupIntent(-1),
    const SingleActivator(LogicalKeyboardKey.numpad2, control: true):
        const CycleGroupIntent(-1),

    // Layout-independent bracket keys for cycling groups
    const AppShortcutActivator(LogicalKeyboardKey.bracketRight,
            physicalKey: PhysicalKeyboardKey.bracketRight):
        const CycleGroupIntent(1),
    const AppShortcutActivator(LogicalKeyboardKey.bracketLeft,
            physicalKey: PhysicalKeyboardKey.bracketLeft):
        const CycleGroupIntent(-1),

    const SingleActivator(LogicalKeyboardKey.digit1):
        const SelectGroupNumberIntent(1),
    const SingleActivator(LogicalKeyboardKey.digit2):
        const SelectGroupNumberIntent(2),
    const SingleActivator(LogicalKeyboardKey.digit3):
        const SelectGroupNumberIntent(3),
    const SingleActivator(LogicalKeyboardKey.digit4):
        const SelectGroupNumberIntent(4),
    const SingleActivator(LogicalKeyboardKey.digit5):
        const SelectGroupNumberIntent(5),
    const SingleActivator(LogicalKeyboardKey.digit6):
        const SelectGroupNumberIntent(6),

    // --- Refresh & Versions ---
    const AppShortcutActivator(LogicalKeyboardKey.keyR,
        physicalKey: PhysicalKeyboardKey.keyR): const RefreshDataIntent(),
    const SingleActivator(LogicalKeyboardKey.f5): const RefreshDataIntent(),
    const AppShortcutActivator(LogicalKeyboardKey.keyR,
        physicalKey: PhysicalKeyboardKey.keyR,
        control: true): const RefreshDataIntent(),
    const AppShortcutActivator(LogicalKeyboardKey.keyV,
        physicalKey: PhysicalKeyboardKey.keyV,
        includeRepeats: false): const OpenVersionPickerIntent(),

    // --- Quick Schedule Version Cycling ---
    const SingleActivator(LogicalKeyboardKey.arrowDown,
        alt: true, includeRepeats: false): const CycleVersionIntent(-1),
    const SingleActivator(LogicalKeyboardKey.numpad2,
        alt: true, includeRepeats: false): const CycleVersionIntent(-1),
    const SingleActivator(LogicalKeyboardKey.arrowUp,
        alt: true, includeRepeats: false): const CycleVersionIntent(1),
    const SingleActivator(LogicalKeyboardKey.numpad8,
        alt: true, includeRepeats: false): const CycleVersionIntent(1),
    const AppShortcutActivator(LogicalKeyboardKey.keyV,
        physicalKey: PhysicalKeyboardKey.keyV,
        shift: true,
        includeRepeats: false): const CycleVersionIntent(1),

    // --- Screen Navigation ---
    const SingleActivator(LogicalKeyboardKey.f2, includeRepeats: false):
        const OpenAnalyticsIntent(),
    const AppShortcutActivator(LogicalKeyboardKey.keyG,
        physicalKey: PhysicalKeyboardKey.keyG,
        includeRepeats: false): const OpenAnalyticsIntent(),
    const AppShortcutActivator(LogicalKeyboardKey.keyG,
        physicalKey: PhysicalKeyboardKey.keyG,
        control: true,
        includeRepeats: false): const OpenAnalyticsIntent(),

    const SingleActivator(LogicalKeyboardKey.f3, includeRepeats: false):
        const OpenAchievementsIntent(),
    const AppShortcutActivator(LogicalKeyboardKey.keyL,
        physicalKey: PhysicalKeyboardKey.keyL,
        includeRepeats: false): const OpenAchievementsIntent(),

    const SingleActivator(LogicalKeyboardKey.f10, includeRepeats: false):
        const OpenSettingsIntent(),
    const AppShortcutActivator(LogicalKeyboardKey.keyO,
        physicalKey: PhysicalKeyboardKey.keyO,
        includeRepeats: false): const OpenSettingsIntent(),
    const AppShortcutActivator(LogicalKeyboardKey.comma,
        physicalKey: PhysicalKeyboardKey.comma,
        control: true,
        includeRepeats: false): const OpenSettingsIntent(),

    const SingleActivator(LogicalKeyboardKey.f12, includeRepeats: false):
        const OpenLogsIntent(),

    // --- Theme Toggle ---
    const SingleActivator(LogicalKeyboardKey.f4, includeRepeats: false):
        const ToggleThemeIntent(),
    const AppShortcutActivator(LogicalKeyboardKey.keyD,
        physicalKey: PhysicalKeyboardKey.keyD,
        control: true,
        shift: true,
        includeRepeats: false): const ToggleThemeIntent(),

    // --- Help & Exit ---
    ...modalShortcuts,
  };

  static final Map<ShortcutActivator, Intent> _analyticsShortcuts = {
    // --- Tab Navigation ---
    const AppShortcutActivator(LogicalKeyboardKey.keyA,
        physicalKey: PhysicalKeyboardKey.keyA): const AnalyticsPrevTabIntent(),
    const SingleActivator(LogicalKeyboardKey.arrowLeft):
        const AnalyticsPrevTabIntent(),
    const SingleActivator(LogicalKeyboardKey.numpad4):
        const AnalyticsPrevTabIntent(),

    const AppShortcutActivator(LogicalKeyboardKey.keyD,
        physicalKey: PhysicalKeyboardKey.keyD): const AnalyticsNextTabIntent(),
    const SingleActivator(LogicalKeyboardKey.arrowRight):
        const AnalyticsNextTabIntent(),
    const SingleActivator(LogicalKeyboardKey.numpad6):
        const AnalyticsNextTabIntent(),

    const SingleActivator(LogicalKeyboardKey.digit1):
        const AnalyticsSelectTabIntent(0),
    const SingleActivator(LogicalKeyboardKey.digit2):
        const AnalyticsSelectTabIntent(1),
    const SingleActivator(LogicalKeyboardKey.digit3):
        const AnalyticsSelectTabIntent(2),
    const SingleActivator(LogicalKeyboardKey.digit4):
        const AnalyticsSelectTabIntent(3),
    const SingleActivator(LogicalKeyboardKey.digit5):
        const AnalyticsSelectTabIntent(4),

    // --- Data Source Mode (Predicted ⟷ Real) ---
    const AppShortcutActivator(LogicalKeyboardKey.keyM,
            physicalKey: PhysicalKeyboardKey.keyM):
        const ToggleDataSourceModeIntent(),
    const SingleActivator(LogicalKeyboardKey.numpad0):
        const ToggleDataSourceModeIntent(),

    // --- Group Cycling inside Analytics ---
    // Upwards increases group number (+1), downwards decreases (-1).
    const SingleActivator(LogicalKeyboardKey.arrowUp, control: true):
        const CycleGroupIntent(1),
    const SingleActivator(LogicalKeyboardKey.numpad8, control: true):
        const CycleGroupIntent(1),
    const SingleActivator(LogicalKeyboardKey.arrowDown, control: true):
        const CycleGroupIntent(-1),
    const SingleActivator(LogicalKeyboardKey.numpad2, control: true):
        const CycleGroupIntent(-1),
    const AppShortcutActivator(LogicalKeyboardKey.bracketRight,
            physicalKey: PhysicalKeyboardKey.bracketRight):
        const CycleGroupIntent(1),
    const AppShortcutActivator(LogicalKeyboardKey.bracketLeft,
            physicalKey: PhysicalKeyboardKey.bracketLeft):
        const CycleGroupIntent(-1),

    // --- Achievements from Analytics ---
    const SingleActivator(LogicalKeyboardKey.f3, includeRepeats: false):
        const OpenAchievementsIntent(),
    const AppShortcutActivator(LogicalKeyboardKey.keyL,
        physicalKey: PhysicalKeyboardKey.keyL,
        includeRepeats: false): const OpenAchievementsIntent(),

    // --- Refresh & Back ---
    const AppShortcutActivator(LogicalKeyboardKey.keyR,
        physicalKey: PhysicalKeyboardKey.keyR): const RefreshDataIntent(),
    const SingleActivator(LogicalKeyboardKey.f5): const RefreshDataIntent(),
    const AppShortcutActivator(LogicalKeyboardKey.keyR,
        physicalKey: PhysicalKeyboardKey.keyR,
        control: true): const RefreshDataIntent(),

    ...modalShortcuts,
  };

  /// Shortcuts for LogsPage (Esc, F1, Refresh, Copy, and Category Filter 1..4).
  static final Map<ShortcutActivator, Intent> logsShortcuts = {
    ...modalShortcuts,
    const AppShortcutActivator(LogicalKeyboardKey.keyR,
        physicalKey: PhysicalKeyboardKey.keyR): const RefreshDataIntent(),
    const SingleActivator(LogicalKeyboardKey.f5): const RefreshDataIntent(),
    const AppShortcutActivator(LogicalKeyboardKey.keyR,
        physicalKey: PhysicalKeyboardKey.keyR,
        control: true): const RefreshDataIntent(),
    const AppShortcutActivator(LogicalKeyboardKey.keyC,
        physicalKey: PhysicalKeyboardKey.keyC,
        control: true,
        includeRepeats: false): const CopyLogsIntent(),
    const SingleActivator(LogicalKeyboardKey.digit1):
        const SelectLogFilterCategoryIntent(0),
    const SingleActivator(LogicalKeyboardKey.digit2):
        const SelectLogFilterCategoryIntent(1),
    const SingleActivator(LogicalKeyboardKey.digit3):
        const SelectLogFilterCategoryIntent(2),
    const SingleActivator(LogicalKeyboardKey.digit4):
        const SelectLogFilterCategoryIntent(3),
  };

  /// Shortcuts for ManualScheduleEditor (Esc, F1, and Ctrl + S to save).
  static final Map<ShortcutActivator, Intent> editorShortcuts = {
    ...modalShortcuts,
    const AppShortcutActivator(LogicalKeyboardKey.keyS,
        physicalKey: PhysicalKeyboardKey.keyS,
        control: true,
        includeRepeats: false): const SaveEditorDataIntent(),
  };

  /// Shortcuts for the main HomeScreen.
  static Map<ShortcutActivator, Intent> get homeShortcuts => _homeShortcuts;

  /// Shortcuts for AnalyticsScreen.
  static Map<ShortcutActivator, Intent> get analyticsShortcuts =>
      _analyticsShortcuts;

  /// Cheatsheet data structured for display in the help dialog.
  static List<ShortcutCategory> get cheatSheetCategories => [
        const ShortcutCategory(
          title: '📅 Навігація по датах',
          icon: Icons.calendar_today,
          items: [
            ShortcutHelpItem(
              actionName: 'День назад',
              keyLabels: ['A', '←', 'Num 4'],
              description: 'Перехід на один день у минуле',
            ),
            ShortcutHelpItem(
              actionName: 'День вперед',
              keyLabels: ['D', '→', 'Num 6'],
              description: 'Перехід на один день уперед',
            ),
            ShortcutHelpItem(
              actionName: 'Сьогодні',
              keyLabels: ['T', 'Home', 'Num 5'],
              description: 'Швидке скидання та повернення на сьогодні',
            ),
            ShortcutHelpItem(
              actionName: 'Вчора / Завтра',
              keyLabels: ['Y', 'N'],
              description: 'Прямий стрибок на вчора або завтра',
            ),
            ShortcutHelpItem(
              actionName: 'Календар',
              keyLabels: ['C', 'P'],
              description: 'Вибір довільної дати в календарі',
            ),
            ShortcutHelpItem(
              actionName: 'Скопіювати статус',
              keyLabels: ['Ctrl + C', 'Cmd + C'],
              description: 'Копіювати текстове зведення відключень у буфер',
            ),
          ],
        ),
        const ShortcutCategory(
          title: '⚡ Режим даних (Графік ⟷ Факт)',
          icon: Icons.bolt,
          items: [
            ShortcutHelpItem(
              actionName: 'Перемикання режиму',
              keyLabels: ['M', 'Space', 'Num 0'],
              description:
                  'Циклічно перемикає Прогноз (ДТЕК) та Факт (Монітор)',
            ),
            ShortcutHelpItem(
              actionName: 'Режим: Графік',
              keyLabels: ['W', 'Num 8'],
              description: 'Показує планові відключення за графіком ДТЕК',
            ),
            ShortcutHelpItem(
              actionName: 'Режим: Факт',
              keyLabels: ['S', 'Num 2'],
              description: 'Показує реальний стан наявності світла',
            ),
          ],
        ),
        const ShortcutCategory(
          title: '👥 Вибір групи (Черги)',
          icon: Icons.group_work,
          items: [
            ShortcutHelpItem(
              actionName: 'Наступна черга',
              keyLabels: ['Ctrl + ↑', 'Ctrl + Num 8', ']'],
              description: 'Перемикає чергу вперед: 1.1 → 1.2 → 2.1 тощо',
            ),
            ShortcutHelpItem(
              actionName: 'Попередня черга',
              keyLabels: ['Ctrl + ↓', 'Ctrl + Num 2', '['],
              description: 'Перемикає чергу назад: 2.1 → 1.2 → 1.1 тощо',
            ),
            ShortcutHelpItem(
              actionName: 'Швидкий вибір групи',
              keyLabels: ['1', '2', '3', '4', '5', '6'],
              description: 'GPV1..GPV6 (повторне натискання перемикає .1 ⟷ .2)',
            ),
          ],
        ),
        const ShortcutCategory(
          title: '🔄 Оновлення та версії',
          icon: Icons.sync,
          items: [
            ShortcutHelpItem(
              actionName: 'Оновити графік',
              keyLabels: ['R', 'F5', 'Ctrl + R'],
              description: 'Примусове оновлення розкладу та монітора',
            ),
            ShortcutHelpItem(
              actionName: 'Діалог версій графіка',
              keyLabels: ['V'],
              description:
                  'Відкриває або закриває історію змін графіка за обраний день',
            ),
            ShortcutHelpItem(
              actionName: 'Швидка зміна версії',
              keyLabels: ['Alt + ↓ / ↑', 'Alt + Num 2/8', 'Shift + V'],
              description:
                  'Швидке перемикання між збереженими версіями розкладу за день',
            ),
          ],
        ),
        const ShortcutCategory(
          title: '🧭 Швидкі переходи по екранах',
          icon: Icons.explore,
          items: [
            ShortcutHelpItem(
              actionName: 'Аналітика',
              keyLabels: ['G', 'F2', 'Ctrl + G'],
              description: 'Відкрити розширену аналітику відключень',
            ),
            ShortcutHelpItem(
              actionName: 'Досягнення',
              keyLabels: ['L', 'F3'],
              description: 'Відкрити екран отриманих нагород',
            ),
            ShortcutHelpItem(
              actionName: 'Налаштування',
              keyLabels: ['O', 'F10', 'Ctrl + ,'],
              description: 'Відкрити параметри програми та теми',
            ),
            ShortcutHelpItem(
              actionName: 'Перемикання теми',
              keyLabels: ['F4', 'Ctrl + Shift + D'],
              description: 'Швидке перемикання темної та світлої теми',
            ),
            ShortcutHelpItem(
              actionName: 'Журнал логів',
              keyLabels: ['F12'],
              description: 'Відкрити екран технічних логів',
            ),
            ShortcutHelpItem(
              actionName: 'Назад / Закрити',
              keyLabels: ['Esc'],
              description: 'Закрити поточне вікно або повернутись',
            ),
          ],
        ),
        const ShortcutCategory(
          title: '📊 Навігація в Аналітиці',
          icon: Icons.insights,
          items: [
            ShortcutHelpItem(
              actionName: 'Вкладка вліво / вправо',
              keyLabels: ['A / D', '← / →', 'Num 4 / Num 6'],
              description: 'Перемикання між 5 аналітичними вкладками',
            ),
            ShortcutHelpItem(
              actionName: 'Прямий перехід на вкладку',
              keyLabels: ['1', '2', '3', '4', '5'],
              description:
                  '1: Дашборд, 2: Точність, 3: Рекорди, 4: Графіки, 5: Порівняння',
            ),
            ShortcutHelpItem(
              actionName: 'Зміна черги в аналітиці',
              keyLabels: ['Ctrl + ↑ / ↓', 'Ctrl + Num 8 / 2', '] / ['],
              description: 'Швидка зміна групи та перезавантаження аналітики',
            ),
            ShortcutHelpItem(
              actionName: 'Режим даних в аналітиці',
              keyLabels: ['M', 'Num 0'],
              description: 'Перемикання між фактичними даними та прогнозом',
            ),
            ShortcutHelpItem(
              actionName: 'Досягнення з аналітики',
              keyLabels: ['L', 'F3'],
              description: 'Швидкий перехід до досягнень',
            ),
          ],
        ),
        const ShortcutCategory(
          title: '📋 Логи та редактор',
          icon: Icons.list_alt,
          items: [
            ShortcutHelpItem(
              actionName: 'Фільтри логів',
              keyLabels: ['1', '2', '3', '4'],
              description: '1: Всі, 2: Помилки, 3: Парсер, 4: Монітор',
            ),
            ShortcutHelpItem(
              actionName: 'Скопіювати логи',
              keyLabels: ['Ctrl + C'],
              description: 'Копіювати відфільтровані логи в буфер',
            ),
            ShortcutHelpItem(
              actionName: 'Зберегти в редакторі',
              keyLabels: ['Ctrl + S'],
              description: 'Швидке збереження відредагованого розкладу',
            ),
          ],
        ),
      ];
}
