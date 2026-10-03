import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/data_source_mode.dart';
import '../models/schedule_status.dart';
import '../models/schedule_view_mode.dart';
import '../services/achievement_service.dart';
import '../services/app_logger.dart';
import '../services/darkness_theme_service.dart';
import '../services/desktop_tray_coordinator.dart';
import '../services/parser_service.dart';
import '../services/preferences_helper.dart';
import '../services/schedule_calculation_service.dart';
import '../utils/app_formatters.dart';
import 'achievements_screen.dart';
import 'analytics_screen.dart';
import 'dialogs/hour_detail_dialog.dart';
import 'dialogs/shortcut_help_dialog.dart';
import 'dialogs/version_picker_sheet.dart';
import 'helpers/horizontal_swipe_detector.dart';
import 'logs_page.dart';
import 'settings_page.dart';
import 'shortcuts/app_intents.dart';
import 'shortcuts/keyboard_shortcut_wrapper.dart';
import 'shortcuts/shortcut_registry.dart';
import 'state/home_notifier.dart';
import 'widgets/home/countdown_card.dart';
import 'widgets/home/darkness_stage_banner.dart';
import 'widgets/home/data_source_toggle.dart';
import 'widgets/home/predicted_mode_grid_cell.dart';
import 'widgets/home/real_mode_grid_cell.dart';
import 'widgets/home/schedule_intervals_list.dart';

class HomeScreen extends ConsumerStatefulWidget {
  final VoidCallback? onThemeChanged;
  final VoidCallback? onScaleChanged;

  const HomeScreen({super.key, this.onThemeChanged, this.onScaleChanged});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final DesktopTrayCoordinator _desktopTrayCoordinator =
      DesktopTrayCoordinator();
  final AchievementService _achievementService = AchievementService();
  final FocusNode _focusNode = FocusNode();
  bool _isNavigating = false;

  int _lastAutoRefreshMinute = -1;
  int _lastRenderedMinute = -1;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _desktopTrayCoordinator.init();
    _initAchievements();
    _schedulePeriodicUpdates();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(homeNotifierProvider.notifier).loadPreferencesAndData();
      ref.read(homeNotifierProvider.notifier).initPowerMonitor();
    });
  }

  void _schedulePeriodicUpdates() {
    _timer?.cancel();
    final now = DateTime.now();
    final msToNextMinute = (60 - now.second) * 1000 - now.millisecond + 100;
    _timer = Timer(Duration(milliseconds: msToNextMinute), () {
      if (!mounted) return;
      final current = DateTime.now();

      if (current.minute % 15 == 0 &&
          current.minute != _lastAutoRefreshMinute) {
        _lastAutoRefreshMinute = current.minute;
        ref.read(homeNotifierProvider.notifier).loadData(silent: true);
      }

      if (current.minute != _lastRenderedMinute) {
        _lastRenderedMinute = current.minute;
        ref.read(homeNotifierProvider.notifier).recalculateDisplayData();
      }
      _schedulePeriodicUpdates();
    });
  }

  Future<void> _initAchievements() async {
    _achievementService.onAchievementUnlocked = (achievement) {
      if (mounted) {
        AchievementUnlockedOverlay.show(context, achievement);
      }
    };
    await _achievementService.loadAllStates();
    if (!mounted) return;
    _achievementService.trackAppSession();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _desktopTrayCoordinator.dispose();
    _timer?.cancel();
    _achievementService.onAchievementUnlocked = null;
    super.dispose();
  }

  void _showVersionPicker(HomeState state) {
    VersionPickerSheet.show(
      context: context,
      versions: state.historyVersions,
      selectedVersionIndex: state.selectedVersionIndex,
      onVersionSelected: (index) {
        ref.read(homeNotifierProvider.notifier).selectVersion(index);
      },
    );
  }

  Future<void> _selectDateAndLoad(HomeState state) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final firstAllowed = DateTime(2024);
    DateTime defaultInitial =
        state.historyDate ?? DateTime(now.year, now.month, now.day - 1);
    if (defaultInitial.isAfter(today)) {
      defaultInitial = today;
    }
    if (defaultInitial.isBefore(firstAllowed)) {
      defaultInitial = firstAllowed;
    }

    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: defaultInitial,
      firstDate: firstAllowed,
      lastDate: today,
      locale: const Locale("uk", "UA"),
    );
    if (picked != null) {
      if (DateUtils.isSameDay(picked, today)) {
        await ref
            .read(homeNotifierProvider.notifier)
            .setViewMode(ScheduleViewMode.today);
      } else {
        await ref.read(homeNotifierProvider.notifier).selectDate(picked);
      }
    } else {
      ref.read(homeNotifierProvider.notifier).cancelDateSelection();
    }
  }

  String _getOutageInfoText(HomeState state) {
    return ScheduleCalculationService.getOutageInfoText(
      state.currentDisplaySchedule,
      state.viewMode == ScheduleViewMode.tomorrow,
      powerMonitorEnabled: state.powerMonitorEnabled,
      dataSourceMode: state.dataSourceMode,
      realOutageIntervals: state.realOutageIntervals,
      displayDate: state.displayDate,
      wasUpdated: state.wasUpdated,
      currentGroup: state.currentGroup,
      lastUpdateOldStats: state.lastUpdateOldStats,
    );
  }

  String? _getScheduleVersionString(HomeState state) {
    if (state.historyVersions.isNotEmpty) {
      final version = (state.selectedVersionIndex >= 0 &&
              state.selectedVersionIndex < state.historyVersions.length)
          ? state.historyVersions[state.selectedVersionIndex]
          : state.historyVersions.last;
      return version.timeString;
    }

    final source = state.allSchedules[state.currentGroup]?.lastUpdatedSource;
    if (source != null) {
      final clean = source
          .replaceFirst('Оновлено ДТЕК:', '')
          .replaceFirst("З пам'яті:", '')
          .trim();
      if (clean.isNotEmpty && clean != 'Невідомо' && clean != 'Немає даних') {
        return clean;
      }
    }

    return null;
  }

  String _getScheduleClipboardText(HomeState state) {
    if (!state.hasDisplayData || state.isMissingRealDataSource) {
      return "";
    }

    final outageText = _getOutageInfoText(state);
    final intervals = state.cachedIntervals.isNotEmpty
        ? state.cachedIntervals
        : (state.powerMonitorEnabled &&
                state.dataSourceMode == DataSourceMode.real
            ? ScheduleCalculationService.generateRealIntervals(
                state.realOutageIntervals,
                state.displayDate,
                isOffline: ref
                    .read(homeNotifierProvider.notifier)
                    .powerMonitor
                    .isOffline,
                baseSchedule: state.currentDisplaySchedule,
              )
            : ScheduleCalculationService.generateIntervals(
                state.currentDisplaySchedule));

    final versionStr = _getScheduleVersionString(state);
    final effectiveMode = state.powerMonitorEnabled
        ? state.dataSourceMode
        : DataSourceMode.predicted;

    return ScheduleCalculationService.formatScheduleClipboardSummary(
      group: state.currentGroup,
      date: state.displayDate,
      dataSourceMode: effectiveMode,
      scheduleVersion: versionStr,
      outageInfoText: outageText,
      intervals: intervals,
    );
  }

  Widget _buildDarknessStageBar() => const DarknessStageBanner();

  Widget _buildDataSourceToggle(HomeState state, HomeNotifier notifier) =>
      DataSourceToggle(
        powerMonitorEnabled: state.powerMonitorEnabled,
        currentMode: state.dataSourceMode,
        onModeChanged: notifier.switchMode,
        powerStatus: state.powerStatus,
      );

  Widget _buildPlaceholder(BuildContext context, String message) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 280, maxHeight: 500),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              color: Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.color
                  ?.withValues(alpha: 0.7),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGrid(HomeState state, int columns) {
    if (state.isMissingRealDataSource) {
      return _buildPlaceholder(
        context,
        "URL бази даних не налаштовано. Перейдіть в Налаштування.",
      );
    }

    if (!state.hasDisplayData) {
      return _buildPlaceholder(context, "Дані відсутні");
    }

    final bool isRealMode = state.powerMonitorEnabled &&
        state.dataSourceMode == DataSourceMode.real;
    final schedule = state.currentDisplaySchedule;
    final realHourSegments = state.realHourSegments;

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        childAspectRatio: 1.5,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: 24,
      itemBuilder: (context, index) {
        final bool isCurrentHour = state.viewMode == ScheduleViewMode.today &&
            DateTime.now().hour == index;

        if (isRealMode &&
            realHourSegments != null &&
            index < realHourSegments.length) {
          return RealModeGridCell(
            hour: index,
            segments: realHourSegments[index],
            isCurrentHour: isCurrentHour,
            viewMode: state.viewMode,
            onLongPress: () => _showHourDetailTooltip(state, index),
          );
        }

        final status = schedule?.hours[index] ?? LightStatus.unknown;
        return PredictedModeGridCell(
          hour: index,
          status: status,
          isCurrentHour: isCurrentHour,
        );
      },
    );
  }

  void _showHourDetailTooltip(HomeState state, int hour) {
    final segments = state.realHourSegments;
    if (segments == null || hour >= segments.length) return;
    HourDetailDialog.show(
      context: context,
      hour: hour,
      segments: segments[hour],
    );
  }

  void _showIntervalMenu(BuildContext context, dynamic interval) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Меню не підтримується для цього режиму")),
    );
  }

  void _openAnalytics(String groupKey) {
    if (_isNavigating) return;
    _isNavigating = true;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AnalyticsScreen(groupKey: groupKey),
      ),
    ).whenComplete(() {
      _isNavigating = false;
    });
  }

  Future<void> _openSettings() async {
    if (_isNavigating) return;
    _isNavigating = true;
    try {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => SettingsPage(
            onThemeChanged: widget.onThemeChanged,
            onScaleChanged: widget.onScaleChanged,
          ),
        ),
      );
    } finally {
      _isNavigating = false;
    }
    if (!mounted) return;
    ref.read(homeNotifierProvider.notifier).loadPreferencesAndData();
    ref.read(homeNotifierProvider.notifier).initPowerMonitor();
  }

  void _openAchievements() {
    if (_isNavigating) return;
    _isNavigating = true;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const AchievementsScreen(),
      ),
    ).whenComplete(() {
      _isNavigating = false;
    });
  }

  void _openLogs() {
    if (_isNavigating) return;
    _isNavigating = true;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const LogsPage(),
      ),
    ).whenComplete(() {
      _isNavigating = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(homeNotifierProvider);
    final notifier = ref.read(homeNotifierProvider.notifier);

    final screenWidth = MediaQuery.of(context).size.width;
    final int cols = screenWidth > 800 ? 8 : (screenWidth > 600 ? 6 : 4);

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return KeyboardShortcutWrapper(
      focusNode: _focusNode,
      shortcuts: AppKeyboardShortcuts.homeShortcuts,
      actions: {
        NavigateDateIntent: CallbackAction<NavigateDateIntent>(
          onInvoke: (intent) {
            notifier.navigateDate(intent.offset);
            return null;
          },
        ),
        JumpToTodayIntent: CallbackAction<JumpToTodayIntent>(
          onInvoke: (intent) {
            final current = ref.read(homeNotifierProvider);
            if (current.viewMode != ScheduleViewMode.today) {
              notifier.setViewMode(ScheduleViewMode.today);
            } else if (current.selectedVersionIndex != -1 &&
                current.historyVersions.isNotEmpty) {
              notifier.selectVersion(current.historyVersions.length - 1);
              if (context.mounted) {
                ScaffoldMessenger.of(context).hideCurrentSnackBar();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content:
                        Text("Повернуто до актуального графіка на сьогодні"),
                    duration: Duration(seconds: 1),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            }
            return null;
          },
        ),
        JumpToYesterdayIntent: CallbackAction<JumpToYesterdayIntent>(
          onInvoke: (intent) {
            final current = ref.read(homeNotifierProvider);
            if (current.viewMode != ScheduleViewMode.yesterday) {
              notifier.setViewMode(ScheduleViewMode.yesterday);
            }
            return null;
          },
        ),
        JumpToTomorrowIntent: CallbackAction<JumpToTomorrowIntent>(
          onInvoke: (intent) {
            final current = ref.read(homeNotifierProvider);
            if (current.viewMode != ScheduleViewMode.tomorrow) {
              notifier.setViewMode(ScheduleViewMode.tomorrow);
            }
            return null;
          },
        ),
        CopyScheduleSummaryIntent: CallbackAction<CopyScheduleSummaryIntent>(
          onInvoke: (intent) async {
            final current = ref.read(homeNotifierProvider);
            final text = _getScheduleClipboardText(current);
            if (text.isNotEmpty) {
              await Clipboard.setData(ClipboardData(text: text));
              if (context.mounted) {
                ScaffoldMessenger.of(context).hideCurrentSnackBar();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content:
                        Text("Інформацію про відключення скопійовано в буфер"),
                    duration: Duration(seconds: 2),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            } else if (context.mounted) {
              ScaffoldMessenger.of(context).hideCurrentSnackBar();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text("Немає даних для копіювання"),
                  duration: Duration(seconds: 1),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
            return null;
          },
        ),
        ToggleDataSourceModeIntent: CallbackAction<ToggleDataSourceModeIntent>(
          onInvoke: (intent) {
            notifier.toggleDataSourceMode();
            return null;
          },
        ),
        SetDataSourceModeIntent: CallbackAction<SetDataSourceModeIntent>(
          onInvoke: (intent) {
            notifier.switchMode(intent.mode);
            return null;
          },
        ),
        CycleGroupIntent: CallbackAction<CycleGroupIntent>(
          onInvoke: (intent) {
            notifier.cycleGroup(intent.direction);
            return null;
          },
        ),
        SelectGroupNumberIntent: CallbackAction<SelectGroupNumberIntent>(
          onInvoke: (intent) {
            notifier.selectGroupByIndex(intent.groupNumber);
            return null;
          },
        ),
        RefreshDataIntent: CallbackAction<RefreshDataIntent>(
          onInvoke: (intent) {
            notifier.refresh();
            return null;
          },
        ),
        OpenDatePickerIntent: CallbackAction<OpenDatePickerIntent>(
          onInvoke: (intent) {
            _selectDateAndLoad(ref.read(homeNotifierProvider));
            return null;
          },
        ),
        OpenVersionPickerIntent: CallbackAction<OpenVersionPickerIntent>(
          onInvoke: (intent) {
            if (VersionPickerSheet.isOpen) {
              Navigator.of(context).maybePop();
              return null;
            }
            final current = ref.read(homeNotifierProvider);
            if (current.historyVersions.isNotEmpty) {
              _showVersionPicker(current);
            }
            return null;
          },
        ),
        CycleVersionIntent: CallbackAction<CycleVersionIntent>(
          onInvoke: (intent) {
            final current = ref.read(homeNotifierProvider);
            if (current.historyVersions.length > 1) {
              notifier.cycleVersion(intent.direction);
              final updated = ref.read(homeNotifierProvider);
              final ver = updated.selectedVersionIndex >= 0 &&
                      updated.selectedVersionIndex <
                          updated.historyVersions.length
                  ? updated.historyVersions[updated.selectedVersionIndex]
                  : null;
              if (ver != null && context.mounted) {
                ScaffoldMessenger.of(context).hideCurrentSnackBar();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Версія графіка: ${ver.timeString} (${ver.outageString})',
                    ),
                    duration: const Duration(seconds: 1),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            } else if (current.historyVersions.length == 1) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).hideCurrentSnackBar();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content:
                        Text('Доступна лише одна версія графіка за цей день'),
                    duration: Duration(seconds: 1),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            } else if (current.historyVersions.isEmpty) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).hideCurrentSnackBar();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Для обраного дня немає збережених версій'),
                    duration: Duration(seconds: 1),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            }
            return null;
          },
        ),
        ToggleThemeIntent: CallbackAction<ToggleThemeIntent>(
          onInvoke: (intent) async {
            try {
              final prefs = await PreferencesHelper.getSafeInstance();
              final current = prefs.getBool('is_dark_mode') ?? true;
              final next = !current;
              await prefs.setBool('is_dark_mode', next);
              AchievementService().trackThemeToggle();
              widget.onThemeChanged?.call();
              if (context.mounted) {
                ScaffoldMessenger.of(context).hideCurrentSnackBar();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      next ? 'Увімкнено темну тему' : 'Увімкнено світлу тему',
                    ),
                    duration: const Duration(seconds: 1),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            } catch (e) {
              AppLogger.e('Error toggling theme via shortcut',
                  tag: 'HomeScreen', error: e);
            }
            return null;
          },
        ),
        OpenAnalyticsIntent: CallbackAction<OpenAnalyticsIntent>(
          onInvoke: (intent) {
            _openAnalytics(ref.read(homeNotifierProvider).currentGroup);
            return null;
          },
        ),
        OpenSettingsIntent: CallbackAction<OpenSettingsIntent>(
          onInvoke: (intent) {
            _openSettings();
            return null;
          },
        ),
        OpenAchievementsIntent: CallbackAction<OpenAchievementsIntent>(
          onInvoke: (intent) {
            _openAchievements();
            return null;
          },
        ),
        OpenLogsIntent: CallbackAction<OpenLogsIntent>(
          onInvoke: (intent) {
            _openLogs();
            return null;
          },
        ),
        ToggleShortcutHelpIntent: CallbackAction<ToggleShortcutHelpIntent>(
          onInvoke: (intent) {
            ShortcutHelpDialog.show(context);
            return null;
          },
        ),
        CloseTopModalOrGoBackIntent:
            CallbackAction<CloseTopModalOrGoBackIntent>(
          onInvoke: (intent) {
            Navigator.of(context).maybePop();
            return null;
          },
        ),
      },
      child: HorizontalSwipeDetector(
        behavior: HitTestBehavior.translucent,
        minDistance: 60.0,
        onSwipeLeft: () => notifier.navigateDate(1),
        onSwipeRight: () => notifier.navigateDate(-1),
        child: Scaffold(
          appBar: AppBar(
            title: DropdownButton<String>(
              value: state.currentGroup,
              dropdownColor: isDark ? const Color(0xFF2C2C2C) : Colors.white,
              icon: Icon(Icons.arrow_drop_down,
                  color: isDark ? Colors.orange : Colors.deepPurple),
              underline: Container(),
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.black87),
              onChanged: (newGroup) async {
                await notifier.changeGroup(newGroup);
              },
              items: ParserService.allGroups.map((String value) {
                return DropdownMenuItem(
                    value: value,
                    child: Text(AppFormatters.formatGroupName(value)));
              }).toList(),
            ),
            centerTitle: true,
            actions: [
              IconButton(
                icon: Icon(Icons.refresh,
                    color: isDark ? Colors.white : Colors.black87),
                tooltip: 'Оновити (R / F5)',
                onPressed: () async {
                  await notifier.refresh();
                },
              ),
              IconButton(
                icon: Icon(Icons.analytics_outlined,
                    color: isDark ? Colors.orange : Colors.deepPurple),
                tooltip: 'Аналітика (G / F2)',
                onPressed: () => _openAnalytics(state.currentGroup),
              ),
              if (Theme.of(context).platform == TargetPlatform.windows ||
                  Theme.of(context).platform == TargetPlatform.linux ||
                  Theme.of(context).platform == TargetPlatform.macOS ||
                  MediaQuery.sizeOf(context).width >= 500)
                IconButton(
                  icon: Icon(Icons.keyboard_outlined,
                      color: isDark ? Colors.white70 : Colors.black54),
                  tooltip: 'Гарячі клавіші (F1)',
                  onPressed: () => ShortcutHelpDialog.show(context),
                ),
              IconButton(
                icon: Icon(Icons.settings,
                    color: isDark ? Colors.white : Colors.black87),
                tooltip: 'Налаштування (O / F10)',
                onPressed: _openSettings,
              ),
            ],
          ),
          body: Stack(
            children: [
              Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12.0),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            icon: DarknessThemeService().buildArrowIcon(
                              forward: false,
                              color: state.isAtEarliestDate
                                  ? (Theme.of(context)
                                              .textTheme
                                              .titleLarge
                                              ?.color ??
                                          Colors.white)
                                      .withValues(alpha: 0.3)
                                  : (Theme.of(context)
                                          .textTheme
                                          .titleLarge
                                          ?.color ??
                                      Colors.white),
                            ),
                            onPressed: state.isAtEarliestDate
                                ? null
                                : () => notifier.navigateDate(-1),
                          ),
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 4.0),
                            child: ChoiceChip(
                              label: const Text('Минуле'),
                              selected: state.isHistoryMode,
                              onSelected: (bool selected) async {
                                await _selectDateAndLoad(state);
                              },
                            ),
                          ),
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 4.0),
                            child: ChoiceChip(
                              label: const Text('Сьогодні'),
                              selected:
                                  state.viewMode == ScheduleViewMode.today,
                              onSelected: (bool selected) {
                                if (selected &&
                                    state.viewMode != ScheduleViewMode.today) {
                                  notifier.setViewMode(ScheduleViewMode.today);
                                }
                              },
                            ),
                          ),
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 4.0),
                            child: ChoiceChip(
                              label: const Text('Завтра'),
                              selected:
                                  state.viewMode == ScheduleViewMode.tomorrow,
                              onSelected: (bool selected) {
                                if (selected &&
                                    state.viewMode !=
                                        ScheduleViewMode.tomorrow) {
                                  notifier
                                      .setViewMode(ScheduleViewMode.tomorrow);
                                }
                              },
                            ),
                          ),
                          IconButton(
                            icon: DarknessThemeService().buildArrowIcon(
                              forward: true,
                              color: state.viewMode == ScheduleViewMode.tomorrow
                                  ? (Theme.of(context)
                                              .textTheme
                                              .titleLarge
                                              ?.color ??
                                          Colors.white)
                                      .withValues(alpha: 0.3)
                                  : (Theme.of(context)
                                          .textTheme
                                          .titleLarge
                                          ?.color ??
                                      Colors.white),
                            ),
                            onPressed:
                                state.viewMode == ScheduleViewMode.tomorrow
                                    ? null
                                    : () => notifier.navigateDate(1),
                          ),
                        ],
                      ),
                    ),
                  ),
                  _buildDataSourceToggle(state, notifier),
                  _buildDarknessStageBar(),
                  GestureDetector(
                    onTap: (state.historyVersions.isNotEmpty)
                        ? () => _showVersionPicker(state)
                        : null,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(state.statusMessage,
                            style: TextStyle(
                                color: state.statusColor,
                                fontSize: 12,
                                fontWeight: FontWeight.bold)),
                        if (state.historyVersions.isNotEmpty)
                          const Icon(Icons.arrow_drop_down,
                              color: Colors.grey, size: 16),
                      ],
                    ),
                  ),
                  if (!state.isLoading) ...[
                    if (state.viewMode == ScheduleViewMode.today) ...[
                      const SizedBox(height: 8),
                      CountdownCard(
                        fullSchedule: state.allSchedules[state.currentGroup],
                      ),
                    ],
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: Text(
                        _getOutageInfoText(state),
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color:
                                Theme.of(context).textTheme.bodyLarge?.color ??
                                    Colors.black87),
                      ),
                    ),
                  ],
                  Expanded(
                    child: state.isLoading
                        ? const Center(
                            child:
                                CircularProgressIndicator(color: Colors.orange))
                        : RefreshIndicator(
                            color: Colors.orange,
                            onRefresh: () async {
                              await notifier.refresh(silent: true);
                            },
                            child: ListView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12.0),
                                  child: _buildGrid(state, cols),
                                ),
                                if (state.hasDisplayData &&
                                    !state.isMissingRealDataSource)
                                  ScheduleIntervalsList(
                                    intervals: state.cachedIntervals,
                                    onIntervalLongPress: _showIntervalMenu,
                                  ),
                              ],
                            ),
                          ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
