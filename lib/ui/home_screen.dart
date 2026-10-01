import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/data_source_mode.dart';
import '../models/schedule_status.dart';
import '../models/schedule_view_mode.dart';
import '../services/achievement_service.dart';
import '../services/darkness_theme_service.dart';
import '../services/desktop_tray_coordinator.dart';
import '../services/parser_service.dart';
import '../services/schedule_calculation_service.dart';
import 'achievements_screen.dart';
import 'analytics_screen.dart';
import 'dialogs/hour_detail_dialog.dart';
import 'dialogs/version_picker_sheet.dart';
import 'settings_page.dart';
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
        state.historyDate ?? DateTime(now.year, now.month, now.day - 2);
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
      await ref.read(homeNotifierProvider.notifier).selectDate(picked);
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

  Widget _buildDarknessStageBar() => const DarknessStageBanner();

  Widget _buildDataSourceToggle(HomeState state, HomeNotifier notifier) =>
      DataSourceToggle(
        powerMonitorEnabled: state.powerMonitorEnabled,
        currentMode: state.dataSourceMode,
        onModeChanged: notifier.switchMode,
        powerStatus: state.powerStatus,
      );

  Widget _buildGrid(HomeState state, int columns) {
    final bool isRealMode = state.powerMonitorEnabled &&
        state.dataSourceMode == DataSourceMode.real;
    final powerMonitor = ref.read(homeNotifierProvider.notifier).powerMonitor;

    if (isRealMode &&
        (powerMonitor.customUrl == null ||
            powerMonitor.customUrl!.trim().isEmpty)) {
      return const SizedBox(
        height: 500,
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(40),
            child: Text(
              "URL бази даних не налаштовано. Перейдіть в Налаштування.",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16),
            ),
          ),
        ),
      );
    }

    final schedule = state.currentDisplaySchedule;
    if (!isRealMode && (schedule == null || schedule.isEmpty)) {
      return RefreshIndicator(
        onRefresh: () async {
          await ref.read(homeNotifierProvider.notifier).refresh(silent: true);
        },
        child: const SingleChildScrollView(
          physics: AlwaysScrollableScrollPhysics(),
          child: SizedBox(
            height: 500,
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(40),
                child: Text("Дані відсутні"),
              ),
            ),
          ),
        ),
      );
    }

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

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(homeNotifierProvider);
    final notifier = ref.read(homeNotifierProvider.notifier);

    final screenWidth = MediaQuery.of(context).size.width;
    final int cols = screenWidth > 800 ? 8 : (screenWidth > 600 ? 6 : 4);

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return FocusableActionDetector(
      focusNode: _focusNode,
      autofocus: true,
      shortcuts: {
        LogicalKeySet(LogicalKeyboardKey.keyA):
            const _SwitchModeIntent(DataSourceMode.predicted),
        LogicalKeySet(LogicalKeyboardKey.arrowLeft):
            const _SwitchModeIntent(DataSourceMode.predicted),
        LogicalKeySet(LogicalKeyboardKey.numpad4):
            const _SwitchModeIntent(DataSourceMode.predicted),
        LogicalKeySet(LogicalKeyboardKey.keyD):
            const _SwitchModeIntent(DataSourceMode.real),
        LogicalKeySet(LogicalKeyboardKey.arrowRight):
            const _SwitchModeIntent(DataSourceMode.real),
        LogicalKeySet(LogicalKeyboardKey.numpad6):
            const _SwitchModeIntent(DataSourceMode.real),
      },
      actions: {
        _SwitchModeIntent: CallbackAction<_SwitchModeIntent>(
          onInvoke: (intent) {
            notifier.switchMode(intent.mode);
            return null;
          },
        ),
      },
      child: GestureDetector(
        onHorizontalDragEnd: (details) {
          if (details.primaryVelocity! > 0) {
            notifier.switchMode(DataSourceMode.predicted);
          } else if (details.primaryVelocity! < 0) {
            notifier.switchMode(DataSourceMode.real);
          }
        },
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
                    child: Text("Група ${value.replaceFirst('GPV', '')}"));
              }).toList(),
            ),
            centerTitle: true,
            actions: [
              IconButton(
                icon: Icon(Icons.refresh,
                    color: isDark ? Colors.white : Colors.black87),
                onPressed: () async {
                  await notifier.refresh();
                },
              ),
              IconButton(
                icon: Icon(Icons.analytics_outlined,
                    color: isDark ? Colors.orange : Colors.deepPurple),
                tooltip: 'Аналітика',
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) =>
                          AnalyticsScreen(groupKey: state.currentGroup),
                    ),
                  );
                },
              ),
              IconButton(
                icon: Icon(Icons.settings,
                    color: isDark ? Colors.white : Colors.black87),
                onPressed: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (context) => SettingsPage(
                            onThemeChanged: widget.onThemeChanged,
                            onScaleChanged: widget.onScaleChanged)),
                  );
                  if (!mounted) return;
                  notifier.loadPreferencesAndData();
                  notifier.initPowerMonitor();
                },
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
                              selected:
                                  state.viewMode == ScheduleViewMode.history,
                              onSelected: (bool selected) async {
                                await _selectDateAndLoad(state);
                              },
                            ),
                          ),
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 4.0),
                            child: ChoiceChip(
                              label: const Text('Вчора'),
                              selected:
                                  state.viewMode == ScheduleViewMode.yesterday,
                              onSelected: (bool selected) {
                                if (selected) {
                                  notifier
                                      .setViewMode(ScheduleViewMode.yesterday);
                                }
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

class _SwitchModeIntent extends Intent {
  final DataSourceMode mode;
  const _SwitchModeIntent(this.mode);
}
