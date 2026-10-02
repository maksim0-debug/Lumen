import 'package:flutter/widgets.dart';
import '../../models/data_source_mode.dart';

/// Intent to navigate schedule date by day offset (-1 for yesterday/past, +1 for tomorrow/future).
class NavigateDateIntent extends Intent {
  final int offset;
  const NavigateDateIntent(this.offset);
}

/// Intent to jump directly to today.
class JumpToTodayIntent extends Intent {
  const JumpToTodayIntent();
}

/// Intent to jump directly to yesterday.
class JumpToYesterdayIntent extends Intent {
  const JumpToYesterdayIntent();
}

/// Intent to jump directly to tomorrow.
class JumpToTomorrowIntent extends Intent {
  const JumpToTomorrowIntent();
}

/// Intent to toggle between predicted schedule and real outages mode.
class ToggleDataSourceModeIntent extends Intent {
  const ToggleDataSourceModeIntent();
}

/// Intent to explicitly set data source mode (predicted or real).
class SetDataSourceModeIntent extends Intent {
  final DataSourceMode mode;
  const SetDataSourceModeIntent(this.mode);
}

/// Intent to cycle through schedule groups (+1 next, -1 previous).
class CycleGroupIntent extends Intent {
  final int direction;
  const CycleGroupIntent(this.direction);
}

/// Intent to select group by digit index (1..6).
class SelectGroupNumberIntent extends Intent {
  final int groupNumber;
  const SelectGroupNumberIntent(this.groupNumber);
}

/// Intent to refresh schedule and outage data.
class RefreshDataIntent extends Intent {
  const RefreshDataIntent();
}

/// Intent to open custom date picker calendar.
class OpenDatePickerIntent extends Intent {
  const OpenDatePickerIntent();
}

/// Intent to open schedule version picker sheet.
class OpenVersionPickerIntent extends Intent {
  const OpenVersionPickerIntent();
}

/// Intent to open analytics screen.
class OpenAnalyticsIntent extends Intent {
  const OpenAnalyticsIntent();
}

/// Intent to open settings page.
class OpenSettingsIntent extends Intent {
  const OpenSettingsIntent();
}

/// Intent to open achievements screen.
class OpenAchievementsIntent extends Intent {
  const OpenAchievementsIntent();
}

/// Intent to open logs page.
class OpenLogsIntent extends Intent {
  const OpenLogsIntent();
}

/// Intent to open the keyboard shortcuts help dialog/overlay.
class ToggleShortcutHelpIntent extends Intent {
  const ToggleShortcutHelpIntent();
}

/// Intent to dismiss the active modal, sheet or pop the current screen.
class CloseTopModalOrGoBackIntent extends Intent {
  const CloseTopModalOrGoBackIntent();
}

/// Intent to switch to the next tab in analytics.
class AnalyticsNextTabIntent extends Intent {
  const AnalyticsNextTabIntent();
}

/// Intent to switch to the previous tab in analytics.
class AnalyticsPrevTabIntent extends Intent {
  const AnalyticsPrevTabIntent();
}

/// Intent to switch directly to a specific tab index in analytics (0..4).
class AnalyticsSelectTabIntent extends Intent {
  final int tabIndex;
  const AnalyticsSelectTabIntent(this.tabIndex);
}

/// Intent to copy formatted schedule and outage summary to clipboard.
class CopyScheduleSummaryIntent extends Intent {
  const CopyScheduleSummaryIntent();
}

/// Intent to copy all displayed technical logs to clipboard.
class CopyLogsIntent extends Intent {
  const CopyLogsIntent();
}

/// Intent to cycle through schedule versions (+1 newer, -1 older).
class CycleVersionIntent extends Intent {
  final int direction;
  const CycleVersionIntent(this.direction);
}

/// Intent to toggle between dark and light theme.
class ToggleThemeIntent extends Intent {
  const ToggleThemeIntent();
}

/// Intent to select a log filter category by index (0: all, 1: errors, 2: parser, 3: monitor).
class SelectLogFilterCategoryIntent extends Intent {
  final int categoryIndex;
  const SelectLogFilterCategoryIntent(this.categoryIndex);
}

/// Intent to save data in editors/forms (e.g. Ctrl + S in ManualScheduleEditor).
class SaveEditorDataIntent extends Intent {
  const SaveEditorDataIntent();
}
