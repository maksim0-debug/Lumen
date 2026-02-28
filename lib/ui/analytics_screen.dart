import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../services/preferences_helper.dart';
import 'package:fl_chart/fl_chart.dart';
import '../services/analytics_service.dart';
import '../models/analytics_models.dart';
import '../models/schedule_status.dart';
import '../models/power_event.dart';
import 'achievements_screen.dart';

/// Екран аналітики відключень електроенергії.
class AnalyticsScreen extends StatefulWidget {
  final String groupKey;

  const AnalyticsScreen({super.key, required this.groupKey});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen>
    with SingleTickerProviderStateMixin {
  final AnalyticsService _analytics = AnalyticsService();
  late TabController _tabController;

  DataSourceMode _currentMode = DataSourceMode.real;

  // Loaded data
  bool _isLoading = true;
  String? _error;

  // Dashboard
  OutageStats? _statsToday;
  OutageStats? _stats7d;
  OutageStats? _stats30d;
  Map<int, double>? _worstDays;

  // Accuracy
  double _accuracyToday = -1;
  double _accuracy7d = -1;
  TimelineComparisonData? _timeline;
  SwitchLag? _switchLag;
  int _selectedLagDays = 7;

  // Records
  OutageRecords? _records;

  // Charts
  List<List<double>>? _heatmapData;
  List<DailyOutage>? _dailyTrend;
  int _selectedTrendDays = 30;
  int _selectedHeatmapDays = 30;

  // Productivity
  ProductivityStats? _productivity7d;

  // Group Comparison
  GroupComparisonResult? _comparisonData;
  int _comparisonDays = 7; // default: week
  bool _comparisonLoading = false;
  bool _comparisonInitialized = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _loadSavedMode();
  }

  Future<void> _loadSavedMode() async {
    try {
      final prefs = await PreferencesHelper.getSafeInstance();
      final savedModeIndex = prefs.getInt('analytics_mode');
      if (savedModeIndex != null &&
          savedModeIndex < DataSourceMode.values.length) {
        setState(() {
          _currentMode = DataSourceMode.values[savedModeIndex];
        });
      }
    } catch (e) {
      print('Error loading saved mode: $e');
    }
    _loadAllData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadAllData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      int lagStartOffset = _selectedLagDays == 2 ? 1 : 0;
      int lagEndOffset = _selectedLagDays == 2 ? 1 : _selectedLagDays - 1;

      // Load all data in parallel where possible
      final results = await Future.wait([
        _analytics.getOutageStatsForToday(
            mode: _currentMode, groupKey: widget.groupKey), // 0
        _analytics.getOutageStatsForPeriod(7,
            mode: _currentMode, groupKey: widget.groupKey), // 1
        _analytics.getOutageStatsForPeriod(30,
            mode: _currentMode, groupKey: widget.groupKey), // 2
        _analytics.getWorstDays(7,
            mode: _currentMode, groupKey: widget.groupKey), // 3
        _analytics.getAccuracyScore(DateTime.now(), widget.groupKey), // 4
        _analytics.getAccuracyScoreForPeriod(7, widget.groupKey), // 5
        _analytics.getTimelineComparison(DateTime.now(), widget.groupKey), // 6
        _analytics.getSwitchLag(
            lagStartOffset, lagEndOffset, widget.groupKey), // 7
        _analytics.getRecords(
            mode: _currentMode, groupKey: widget.groupKey), // 8
        _analytics.getHeatmapData(_selectedHeatmapDays,
            mode: _currentMode, groupKey: widget.groupKey), // 9
        _analytics.getDailyOutageHours(_selectedTrendDays,
            mode: _currentMode, groupKey: widget.groupKey), // 10
        _analytics.getProductivityImpact(7,
            mode: _currentMode, groupKey: widget.groupKey), // 11
      ]);

      if (mounted) {
        setState(() {
          _statsToday = results[0] as OutageStats;
          _stats7d = results[1] as OutageStats;
          _stats30d = results[2] as OutageStats;
          _worstDays = results[3] as Map<int, double>;
          _accuracyToday = results[4] as double;
          _accuracy7d = results[5] as double;
          _timeline = results[6] as TimelineComparisonData;
          _switchLag = results[7] as SwitchLag;
          _records = results[8] as OutageRecords;
          _heatmapData = results[9] as List<List<double>>;
          _dailyTrend = results[10] as List<DailyOutage>;
          _productivity7d = results[11] as ProductivityStats;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = 'Помилка завантаження: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accentColor = isDark ? Colors.orange : Colors.deepPurple;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          children: [
            const Text('Аналітика',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            CupertinoSlidingSegmentedControl<DataSourceMode>(
              groupValue: _currentMode,
              thumbColor: accentColor,
              backgroundColor: isDark ? Colors.white10 : Colors.grey.shade200,
              children: {
                DataSourceMode.real: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text('Фактичні дані',
                      style: TextStyle(
                          fontSize: 12,
                          color: _currentMode == DataSourceMode.real
                              ? Colors.white
                              : Colors.grey)),
                ),
                DataSourceMode.predicted: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text('За графіком',
                      style: TextStyle(
                          fontSize: 12,
                          color: _currentMode == DataSourceMode.predicted
                              ? Colors.white
                              : Colors.grey)),
                ),
              },
              onValueChanged: (value) {
                if (value != null) {
                  setState(() {
                    _currentMode = value;
                    _saveMode(value);
                    _loadAllData();
                  });
                }
              },
            ),
          ],
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: Icon(Icons.emoji_events_outlined,
                color: isDark ? Colors.amber : Colors.deepOrange),
            tooltip: 'Досягнення',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const AchievementsScreen(),
                ),
              );
            },
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          indicatorColor: accentColor,
          labelColor: accentColor,
          unselectedLabelColor: Colors.grey,
          tabs: const [
            Tab(icon: Icon(Icons.dashboard), text: 'Dashboard'),
            Tab(icon: Icon(Icons.fact_check), text: 'Точність'),
            Tab(icon: Icon(Icons.emoji_events), text: 'Рекорди'),
            Tab(icon: Icon(Icons.show_chart), text: 'Графіки'),
            Tab(icon: Icon(Icons.compare_arrows), text: 'Порівняння'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.orange))
          : _error != null
              ? Center(
                  child:
                      Text(_error!, style: const TextStyle(color: Colors.red)))
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _buildDashboardTab(isDark, accentColor),
                    _buildAccuracyTab(isDark, accentColor),
                    _buildRecordsTab(isDark, accentColor),
                    _buildChartsTab(isDark, accentColor),
                    _buildComparisonTab(isDark, accentColor),
                  ],
                ),
    );
  }

  Future<void> _saveMode(DataSourceMode mode) async {
    try {
      final prefs = await PreferencesHelper.getSafeInstance();
      await prefs.setInt('analytics_mode', mode.index);
    } catch (e) {
      print('Error saving mode: $e');
    }
  }

  Future<void> _updateTrendChart(int days) async {
    setState(() {
      _selectedTrendDays = days;
      // Optional: show local loading state for chart if needed
    });
    try {
      final data = await _analytics.getDailyOutageHours(days,
          mode: _currentMode, groupKey: widget.groupKey);
      if (mounted) {
        setState(() {
          _dailyTrend = data;
        });
      }
    } catch (e) {
      print('Error updating trend chart: $e');
    }
  }

  Future<void> _updateLagChart(int days) async {
    setState(() {
      _selectedLagDays = days;
    });
    try {
      int startDayOffset = days == 2 ? 1 : 0;
      int endDayOffset = days == 2 ? 1 : days - 1;
      final lagData = await _analytics.getSwitchLag(
          startDayOffset, endDayOffset, widget.groupKey);
      if (mounted) {
        setState(() {
          _switchLag = lagData;
        });
      }
    } catch (e) {
      print('Error updating lag chart: $e');
    }
  }

  // ============================================================
  // TAB 1: DASHBOARD
  // ============================================================

  Widget _buildDashboardTab(bool isDark, Color accent) {
    return RefreshIndicator(
      color: Colors.orange,
      onRefresh: _loadAllData,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Summary cards
          _buildSectionTitle('📊 Зведена статистика', isDark),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                  child:
                      _buildStatCard('Сьогодні', _statsToday, isDark, accent)),
              const SizedBox(width: 8),
              Expanded(
                  child: _buildStatCard('7 днів', _stats7d, isDark, accent)),
              const SizedBox(width: 8),
              Expanded(
                  child: _buildStatCard('30 днів', _stats30d, isDark, accent)),
            ],
          ),
          const SizedBox(height: 16),

          // Average duration
          if (_stats7d != null && _stats7d!.count > 0)
            _buildInfoTile(
              Icons.timer,
              'Середня тривалість',
              'Зазвичай відключають на ${_stats7d!.avgFormatted}',
              isDark,
            ),
          const SizedBox(height: 24),

          // Worst days chart
          _buildSectionTitle('📅 Худші дні тижня', isDark),
          const SizedBox(height: 8),
          if (_worstDays != null && _worstDays!.isNotEmpty)
            _buildWorstDaysChart(isDark, accent)
          else
            _buildNoDataWidget(),

          const SizedBox(height: 24),

          // Productivity
          _buildSectionTitle('💼 Продуктивність (7 днів)', isDark),
          const SizedBox(height: 12),
          if (_productivity7d != null) ...[
            _buildProductivitySection(isDark, accent),
          ] else
            _buildNoDataWidget(),

          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildStatCard(
      String title, OutageStats? stats, bool isDark, Color accent) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? Colors.white10 : Colors.grey.shade300,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade500,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          if (stats == null || stats.count == 0)
            Text('—',
                style: TextStyle(fontSize: 20, color: Colors.grey.shade600))
          else ...[
            Text(stats.totalFormatted,
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : Colors.black87)),
            const SizedBox(height: 4),
            Text('${stats.percentage.toStringAsFixed(1)}% часу',
                style: TextStyle(fontSize: 11, color: Colors.red.shade300)),
            const SizedBox(height: 2),
            Text('${stats.count} відкл.',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
          ],
        ],
      ),
    );
  }

  Widget _buildWorstDaysChart(bool isDark, Color accent) {
    final today = DateTime.now();
    final List<String> dynamicDayNames = [];
    final List<int> orderedWeekdays = [];

    for (int i = 6; i >= 0; i--) {
      final d = today.subtract(Duration(days: i));
      orderedWeekdays.add(d.weekday);
      dynamicDayNames
          .add(const ['', 'Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Нд'][d.weekday]);
    }

    final maxVal =
        _worstDays!.values.isNotEmpty ? _worstDays!.values.reduce(max) : 1.0;

    return SizedBox(
      height: 200,
      child: BarChart(
        BarChartData(
          alignment: BarChartAlignment.spaceAround,
          maxY: maxVal * 1.2,
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipItem: (group, gi, rod, ri) {
                final hours = rod.toY;
                final h = hours.floor();
                final m = ((hours - h) * 60).round();
                final timeStr = h > 0 ? '${h}г ${m}хв' : '${m}хв';

                return BarTooltipItem(
                  timeStr,
                  TextStyle(
                      color: isDark ? Colors.white : Colors.black87,
                      fontWeight: FontWeight.bold,
                      fontSize: 12),
                );
              },
            ),
          ),
          titlesData: FlTitlesData(
            show: true,
            topTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 32,
                getTitlesWidget: (value, meta) {
                  return Text('${value.toStringAsFixed(0)}г',
                      style:
                          TextStyle(fontSize: 10, color: Colors.grey.shade500));
                },
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (value, meta) {
                  final idx = value.toInt();
                  if (idx < 0 || idx >= 7) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(dynamicDayNames[idx],
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade400)),
                  );
                },
              ),
            ),
          ),
          borderData: FlBorderData(show: false),
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (value) {
              return FlLine(
                color: isDark ? Colors.white10 : Colors.grey.shade200,
                strokeWidth: 0.5,
              );
            },
          ),
          barGroups: List.generate(7, (i) {
            final wd = orderedWeekdays[i];
            final val = _worstDays![wd] ?? 0;
            // Колір: від зеленого до червоного
            final intensity = maxVal > 0 ? (val / maxVal) : 0.0;
            final color = Color.lerp(
                Colors.green.shade400, Colors.red.shade400, intensity)!;
            return BarChartGroupData(x: i, barRods: [
              BarChartRodData(
                toY: val,
                color: color,
                width: 24,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(6),
                  topRight: Radius.circular(6),
                ),
              ),
            ]);
          }),
        ),
      ),
    );
  }

  Widget _buildProductivitySection(bool isDark, Color accent) {
    final p = _productivity7d!;
    return Column(
      children: [
        _buildInfoTile(
          Icons.work,
          'Робочий час (9:00–18:00)',
          p.totalWorkMinutes > 0
              ? 'Втрачено ${p.lostWorkFormatted} з ${(p.totalWorkMinutes / 60).round()}г (${p.lostWorkPercentage.toStringAsFixed(0)}%)'
              : 'Немає даних',
          isDark,
        ),
        const SizedBox(height: 8),
        _buildInfoTile(
          Icons.nightlight_round,
          'Вечірній досуг (19:00–23:00)',
          p.totalEvenings > 0
              ? 'Зіпсовано вечорів: ${p.ruinedEvenings} з ${p.totalEvenings}'
              : 'Немає даних',
          isDark,
        ),
      ],
    );
  }

  // ============================================================
  // TAB 2: ACCURACY (Точність ДТЕК)
  // ============================================================

  Widget _buildAccuracyTab(bool isDark, Color accent) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildSectionTitle('🎯 Коефіцієнт точності', isDark),
        const SizedBox(height: 16),
        _buildAccuracyGauge(isDark, accent),
        const SizedBox(height: 24),

        // Timeline comparison
        _buildSectionTitle('📊 Реальність vs Графік', isDark),
        const SizedBox(height: 8),
        Text('Порівняння за сьогодні',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
        const SizedBox(height: 12),
        if (_timeline != null && _timeline!.slots.isNotEmpty)
          _buildTimelineComparison(isDark)
        else
          _buildNoDataWidget(),
        const SizedBox(height: 24),

        // Switch lag
        _buildSectionTitle('⏱ Лаг включення/виключення', isDark),
        const SizedBox(height: 12),
        CupertinoSlidingSegmentedControl<int>(
          groupValue: _selectedLagDays,
          thumbColor: accent,
          backgroundColor: isDark ? Colors.white10 : Colors.grey.shade200,
          children: {
            1: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text('Сьогодні',
                  style: TextStyle(
                      fontSize: 12,
                      color:
                          _selectedLagDays == 1 ? Colors.white : Colors.grey)),
            ),
            2: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text('Вчора',
                  style: TextStyle(
                      fontSize: 12,
                      color:
                          _selectedLagDays == 2 ? Colors.white : Colors.grey)),
            ),
            7: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text('Тиждень',
                  style: TextStyle(
                      fontSize: 12,
                      color:
                          _selectedLagDays == 7 ? Colors.white : Colors.grey)),
            ),
            30: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text('Місяць',
                  style: TextStyle(
                      fontSize: 12,
                      color:
                          _selectedLagDays == 30 ? Colors.white : Colors.grey)),
            ),
          },
          onValueChanged: (value) {
            if (value != null) _updateLagChart(value);
          },
        ),
        const SizedBox(height: 12),
        if (_switchLag != null && _switchLag!.sampleCount > 0)
          _buildSwitchLagInfo(isDark)
        else
          _buildNoDataWidget(text: 'Недостатньо даних для розрахунку лагу'),

        const SizedBox(height: 40),
      ],
    );
  }

  Widget _buildAccuracyGauge(bool isDark, Color accent) {
    final todayPct = _accuracyToday >= 0 ? (_accuracyToday * 100) : -1.0;
    final weekPct = _accuracy7d >= 0 ? (_accuracy7d * 100) : -1.0;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(20),
        border:
            Border.all(color: isDark ? Colors.white10 : Colors.grey.shade300),
      ),
      child: Column(
        children: [
          // Today's accuracy
          if (todayPct >= 0) ...[
            Text('Сьогодні',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
            const SizedBox(height: 8),
            _buildProgressBar(todayPct / 100, isDark),
            const SizedBox(height: 8),
            Text('${todayPct.toStringAsFixed(0)}%',
                style: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w800,
                    color: _getAccuracyColor(todayPct))),
            Text(_getAccuracyInsight(todayPct),
                style: TextStyle(fontSize: 13, color: Colors.grey.shade400)),
          ] else
            Text('Немає даних за сьогодні',
                style: TextStyle(color: Colors.grey.shade500)),
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 12),

          // Weekly accuracy
          if (weekPct >= 0) ...[
            Text('За тиждень',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
            const SizedBox(height: 8),
            _buildProgressBar(weekPct / 100, isDark),
            const SizedBox(height: 6),
            Text('${weekPct.toStringAsFixed(0)}%',
                style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: _getAccuracyColor(weekPct))),
          ] else
            Text('Немає даних за тиждень',
                style: TextStyle(color: Colors.grey.shade500)),
        ],
      ),
    );
  }

  Widget _buildProgressBar(double value, bool isDark) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: LinearProgressIndicator(
        value: value.clamp(0, 1),
        minHeight: 12,
        backgroundColor: isDark ? Colors.white12 : Colors.grey.shade300,
        valueColor: AlwaysStoppedAnimation<Color>(
          _getAccuracyColor(value * 100),
        ),
      ),
    );
  }

  Color _getAccuracyColor(double pct) {
    if (pct >= 85) return Colors.green.shade400;
    if (pct >= 65) return Colors.orange.shade400;
    return Colors.red.shade400;
  }

  String _getAccuracyInsight(double pct) {
    if (pct >= 90) return 'ДТЕК майже не бреше! 👏';
    if (pct >= 75) return 'Графік більш-менш відповідає 🤔';
    if (pct >= 50) return 'Графіку вірити не варто 😒';
    return 'Повний обман! 🤥';
  }

  Widget _buildTimelineComparison(bool isDark) {
    if (_timeline == null) return const SizedBox.shrink();

    // Mapping old field to new wrapper if needed, but better to update state type
    // In _loadAllData, we cast result[6] to TimelineComparisonData
    // So _timeline field should be TimelineComparisonData

    final data = _timeline!;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(20),
        border:
            Border.all(color: isDark ? Colors.white10 : Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Legend
          Row(
            children: [
              _legendDot(Colors.green.shade400, 'Світло є'),
              const SizedBox(width: 12),
              _legendDot(Colors.red.shade400, 'Немає'),
              const SizedBox(width: 12),
              _legendDot(Colors.grey.shade600, 'Невідомо'),
            ],
          ),
          const SizedBox(height: 16),

          // Schedule
          Text('Графік ДТЕК:',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          const SizedBox(height: 6),
          _buildPreciseScheduleBar(data.schedule, isDark),

          const SizedBox(height: 12),

          // Reality
          Text('Реальність:',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          const SizedBox(height: 6),
          _buildPreciseRealityBar(data.realityIntervals, isDark),

          const SizedBox(height: 8),

          // Time axis
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('00:00',
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
              Text('06:00',
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
              Text('12:00',
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
              Text('18:00',
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
              Text('24:00',
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPreciseScheduleBar(DailySchedule? schedule, bool isDark) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        height: 28,
        width: double.infinity,
        child: CustomPaint(
          painter: ScheduleTimelinePainter(
            schedule: schedule,
            isDark: isDark,
          ),
        ),
      ),
    );
  }

  Widget _buildPreciseRealityBar(
      List<PowerOutageInterval> intervals, bool isDark) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        height: 28,
        width: double.infinity,
        child: CustomPaint(
          painter: RealityTimelinePainter(
            intervals: intervals,
            isDark: isDark,
          ),
        ),
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
      ],
    );
  }

  Widget _buildSwitchLagInfo(bool isDark) {
    final lag = _switchLag!;
    final onLag = lag.avgOnLagMinutes;
    final offLag = lag.avgOffLagMinutes;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(16),
        border:
            Border.all(color: isDark ? Colors.white10 : Colors.grey.shade300),
      ),
      child: Column(
        children: [
          _lagRow(
            Icons.power,
            'Включення',
            onLag > 0
                ? 'На ${onLag.abs().toStringAsFixed(0)} хв пізніше'
                : 'На ${onLag.abs().toStringAsFixed(0)} хв раніше',
            onLag > 0 ? Colors.red.shade300 : Colors.green.shade300,
            isDark,
          ),
          const SizedBox(height: 8),
          _lagRow(
            Icons.power_off,
            'Виключення',
            offLag > 0
                ? 'На ${offLag.abs().toStringAsFixed(0)} хв пізніше'
                : 'На ${offLag.abs().toStringAsFixed(0)} хв раніше',
            offLag > 0 ? Colors.green.shade300 : Colors.red.shade300,
            isDark,
          ),
          const SizedBox(height: 8),
          Text('На основі ${lag.sampleCount} спостережень',
              style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
        ],
      ),
    );
  }

  Widget _lagRow(
      IconData icon, String title, String detail, Color color, bool isDark) {
    return Row(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : Colors.black87)),
            Text(detail, style: TextStyle(fontSize: 12, color: color)),
          ],
        ),
      ],
    );
  }

  // ============================================================
  // TAB 3: RECORDS (Рекорди / Статистика виживання)
  // ============================================================

  Widget _buildRecordsTab(bool isDark, Color accent) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildSectionTitle('🏆 Статистика виживання', isDark),
        const SizedBox(height: 12),

        // Period stats
        _buildPeriodStatsTable(isDark),
        const SizedBox(height: 24),

        // Records
        _buildSectionTitle('🏅 Рекорди', isDark),
        const SizedBox(height: 12),

        if (_records != null) ...[
          if (_records!.longestOutage != null)
            _buildRecordCard(
              '🌑',
              'Найдовше відключення',
              '${_records!.longestOutage!.durationFormatted} (${_records!.longestOutage!.dateFormatted})',
              Colors.red.shade400,
              isDark,
            ),
          const SizedBox(height: 8),
          if (_records!.shortestUptime != null)
            _buildRecordCard(
              '⚡',
              'Найкоротший проміжок світла',
              '${_records!.shortestUptime!.durationFormatted} (${_records!.shortestUptime!.dateFormatted})',
              Colors.orange.shade400,
              isDark,
            ),
          const SizedBox(height: 8),
          if (_records!.longestUptime != null)
            _buildRecordCard(
              '☀️',
              'Найдовше світло',
              '${_records!.longestUptime!.durationFormatted} (${_records!.longestUptime!.dateFormatted})',
              Colors.green.shade400,
              isDark,
            ),
          if (_records!.longestOutage == null &&
              _records!.shortestUptime == null &&
              _records!.longestUptime == null)
            _buildNoDataWidget(),
        ] else
          _buildNoDataWidget(),

        const SizedBox(height: 40),
      ],
    );
  }

  Widget _buildPeriodStatsTable(bool isDark) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(16),
        border:
            Border.all(color: isDark ? Colors.white10 : Colors.grey.shade300),
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.03)
                  : Colors.grey.shade200,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
              ),
            ),
            child: Row(
              children: [
                const Expanded(
                    flex: 2,
                    child: Text('Період',
                        style: TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 12))),
                Expanded(
                    child: Text('Без світла',
                        style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                            color: Colors.red.shade300))),
                const Expanded(
                    child: Text('% часу',
                        style: TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 12))),
                const Expanded(
                    child: Text('Сер. тривал.',
                        style: TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 12))),
              ],
            ),
          ),
          _buildStatsRow('Сьогодні', _statsToday, isDark),
          _buildStatsRow('7 днів', _stats7d, isDark),
          _buildStatsRow('30 днів', _stats30d, isDark),
        ],
      ),
    );
  }

  Widget _buildStatsRow(String period, OutageStats? stats, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
              color: isDark ? Colors.white10 : Colors.grey.shade200,
              width: 0.5),
        ),
      ),
      child: Row(
        children: [
          Expanded(
              flex: 2,
              child: Text(period, style: const TextStyle(fontSize: 13))),
          Expanded(
              child: Text(stats?.totalFormatted ?? '—',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w500))),
          Expanded(
              child: Text(
                  stats != null
                      ? '${stats.percentage.toStringAsFixed(1)}%'
                      : '—',
                  style: TextStyle(fontSize: 13, color: Colors.red.shade300))),
          Expanded(
              child: Text(stats?.avgFormatted ?? '—',
                  style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  Widget _buildRecordCard(
      String emoji, String title, String value, Color color, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Text(emoji, style: const TextStyle(fontSize: 28)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                const SizedBox(height: 2),
                Text(value,
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: color)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // TAB 4: CHARTS (Графічні візуалізації)
  // ============================================================

  Widget _buildChartsTab(bool isDark, Color accent) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Trend line chart
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _buildSectionTitle('📈 Тренди', isDark),
            CupertinoSlidingSegmentedControl<int>(
              groupValue: _selectedTrendDays,
              thumbColor: accent,
              backgroundColor: isDark ? Colors.white10 : Colors.grey.shade200,
              padding: const EdgeInsets.all(2),
              children: {
                7: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text('Тиждень',
                      style: TextStyle(
                          fontSize: 12,
                          color: _selectedTrendDays == 7
                              ? Colors.white
                              : Colors.grey)),
                ),
                30: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text('Місяць',
                      style: TextStyle(
                          fontSize: 12,
                          color: _selectedTrendDays == 30
                              ? Colors.white
                              : Colors.grey)),
                ),
                60: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text('60 днів',
                      style: TextStyle(
                          fontSize: 12,
                          color: _selectedTrendDays == 60
                              ? Colors.white
                              : Colors.grey)),
                ),
              },
              onValueChanged: (value) {
                if (value != null) _updateTrendChart(value);
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text('Годин без світла по дням',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
        const SizedBox(height: 12),
        if (_dailyTrend != null && _dailyTrend!.isNotEmpty)
          _buildTrendChart(isDark, accent)
        else
          _buildNoDataWidget(),
        const SizedBox(height: 24),

        // Heatmap
        _buildSectionTitle('🗓 Хітмеп активності', isDark),
        const SizedBox(height: 8),
        _buildHeatmapPeriodSelector(isDark),
        const SizedBox(height: 12),
        if (_heatmapData != null)
          _buildHeatmap(isDark)
        else
          _buildNoDataWidget(),

        const SizedBox(height: 40),
      ],
    );
  }

  Widget _buildTrendChart(bool isDark, Color accent) {
    if (_dailyTrend == null || _dailyTrend!.isEmpty) {
      return _buildNoDataWidget();
    }

    final maxY = _dailyTrend!.map((d) => d.outageHours).reduce(max);
    final spots = <FlSpot>[];
    for (int i = 0; i < _dailyTrend!.length; i++) {
      spots.add(FlSpot(i.toDouble(), _dailyTrend![i].outageHours));
    }

    return SizedBox(
      height: 220,
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: maxY > 0 ? maxY * 1.2 : 1,
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipItems: (spots) {
                return spots.map((spot) {
                  final d = _dailyTrend![spot.spotIndex];
                  final h = d.outageHours.floor();
                  final m = ((d.outageHours - h) * 60).round();
                  return LineTooltipItem(
                    '${d.date.day}.${d.date.month.toString().padLeft(2, '0')}\n${h}г ${m}х',
                    TextStyle(
                      color: isDark ? Colors.white : Colors.black87,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  );
                }).toList();
              },
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              curveSmoothness: 0.3,
              color: Colors.red.shade400,
              barWidth: 2.5,
              isStrokeCapRound: true,
              dotData: FlDotData(
                show: true,
                getDotPainter: (spot, percent, barData, index) {
                  return FlDotCirclePainter(
                    radius: 2.5,
                    color: Colors.red.shade400,
                    strokeWidth: 0,
                  );
                },
              ),
              belowBarData: BarAreaData(
                show: true,
                gradient: LinearGradient(
                  colors: [
                    Colors.red.shade400.withValues(alpha: 0.3),
                    Colors.red.shade400.withValues(alpha: 0.0),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
          ],
          titlesData: FlTitlesData(
            topTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 32,
                interval: 6,
                getTitlesWidget: (value, meta) {
                  if (value > 24) return const SizedBox.shrink();
                  return Text(value.toStringAsFixed(0),
                      style:
                          TextStyle(fontSize: 10, color: Colors.grey.shade500));
                },
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: max(1, (_dailyTrend!.length / 6).ceil()).toDouble(),
                getTitlesWidget: (value, meta) {
                  final idx = value.toInt();
                  if (idx < 0 || idx >= _dailyTrend!.length) {
                    return const SizedBox.shrink();
                  }
                  final d = _dailyTrend![idx].date;
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                        '${d.day}.${d.month.toString().padLeft(2, '0')}',
                        style: TextStyle(
                            fontSize: 9, color: Colors.grey.shade500)),
                  );
                },
              ),
            ),
          ),
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (value) => FlLine(
              color: isDark ? Colors.white10 : Colors.grey.shade200,
              strokeWidth: 0.5,
            ),
          ),
          borderData: FlBorderData(show: false),
        ),
      ),
    );
  }

  Widget _buildHeatmapPeriodSelector(bool isDark) {
    final accent = isDark ? Colors.orange : Colors.deepPurple;
    return CupertinoSlidingSegmentedControl<int>(
      groupValue: _selectedHeatmapDays,
      thumbColor: accent,
      backgroundColor: isDark ? Colors.white10 : Colors.grey.shade200,
      children: {
        14: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text('2 тижні',
              style: TextStyle(
                  fontSize: 12,
                  color: _selectedHeatmapDays == 14
                      ? Colors.white
                      : Colors.grey)),
        ),
        30: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text('Місяць',
              style: TextStyle(
                  fontSize: 12,
                  color: _selectedHeatmapDays == 30
                      ? Colors.white
                      : Colors.grey)),
        ),
        60: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text('60 днів',
              style: TextStyle(
                  fontSize: 12,
                  color: _selectedHeatmapDays == 60
                      ? Colors.white
                      : Colors.grey)),
        ),
      },
      onValueChanged: (value) {
        if (value != null && _selectedHeatmapDays != value) {
          setState(() => _selectedHeatmapDays = value);
          _reloadHeatmap();
        }
      },
    );
  }

  Future<void> _reloadHeatmap() async {
    final data = await _analytics.getHeatmapData(
      _selectedHeatmapDays,
      mode: _currentMode,
      groupKey: widget.groupKey,
    );
    if (mounted) setState(() => _heatmapData = data);
  }

  Widget _buildHeatmap(bool isDark) {
    final dayNames = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Нд'];
    const cellSize = 18.0;
    const labelWidth = 28.0;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E1E1E) : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Hour labels on top
            Row(
              children: [
                const SizedBox(width: labelWidth),
                ...List.generate(24, (h) {
                  return SizedBox(
                    width: cellSize,
                    child: Center(
                      child: Text(
                        h % 3 == 0 ? '$h' : '',
                        style:
                            TextStyle(fontSize: 8, color: Colors.grey.shade500),
                      ),
                    ),
                  );
                }),
              ],
            ),
            const SizedBox(height: 2),
            // Rows by weekday
            ...List.generate(7, (wd) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Row(
                  children: [
                    SizedBox(
                      width: labelWidth,
                      child: Text(dayNames[wd],
                          style: TextStyle(
                              fontSize: 10, color: Colors.grey.shade500)),
                    ),
                    ...List.generate(24, (h) {
                      final val = _heatmapData![wd][h]; // 0.0–1.0
                      Color cellColor;
                      if (val <= 0.01) {
                        cellColor = isDark
                            ? Colors.green.shade900.withValues(alpha: 0.3)
                            : Colors.green.shade100;
                      } else if (val <= 0.3) {
                        cellColor = Color.lerp(Colors.yellow.shade600,
                            Colors.orange.shade600, val)!;
                      } else {
                        cellColor = Color.lerp(Colors.orange.shade600,
                            Colors.red.shade700, (val - 0.3) / 0.7)!;
                      }
                      return Tooltip(
                        message:
                            '${dayNames[wd]} $h:00 — ${(val * 100).toStringAsFixed(0)}% без світла',
                        child: Container(
                          width: cellSize - 2,
                          height: cellSize - 2,
                          margin: const EdgeInsets.all(1),
                          decoration: BoxDecoration(
                            color: cellColor,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              );
            }),
            const SizedBox(height: 8),
            // Gradient legend
            Row(
              children: [
                const SizedBox(width: labelWidth),
                Text('Менше',
                    style: TextStyle(fontSize: 9, color: Colors.grey.shade500)),
                const SizedBox(width: 4),
                Container(
                  width: 80,
                  height: 8,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [
                      isDark ? Colors.green.shade900 : Colors.green.shade100,
                      Colors.yellow.shade600,
                      Colors.orange.shade600,
                      Colors.red.shade700,
                    ]),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(width: 4),
                Text('Більше',
                    style: TextStyle(fontSize: 9, color: Colors.grey.shade500)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // TAB 5: COMPARISON (Порівняння груп)
  // ============================================================

  Future<void> _loadComparison(int periodId) async {
    setState(() {
      _comparisonDays = periodId;
      _comparisonLoading = true;
    });
    try {
      int start = 0;
      int end = 0;
      if (periodId == 1) {
        start = 0;
        end = 0;
      } else if (periodId == 2) {
        start = 1;
        end = 1;
      } else {
        start = 0;
        end = periodId - 1;
      }

      final result = await _analytics.getGroupComparison(
          startDayOffset: start, endDayOffset: end);
      if (mounted) {
        setState(() {
          _comparisonData = result;
          _comparisonLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _comparisonLoading = false;
        });
      }
    }
  }

  Widget _buildComparisonTab(bool isDark, Color accent) {
    // Автозавантаження при першому відвідуванні вкладки
    if (!_comparisonInitialized) {
      _comparisonInitialized = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadComparison(_comparisonDays);
      });
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Блок А: Фільтр періоду
        _buildSectionTitle('📊 Порівняння груп', isDark),
        const SizedBox(height: 8),
        Text('Аналіз планових відключень по всім групам ДТЕК',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
        const SizedBox(height: 16),

        // Period filter chips
        _buildComparisonPeriodFilter(isDark, accent),
        const SizedBox(height: 20),

        if (_comparisonLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child:
                Center(child: CircularProgressIndicator(color: Colors.orange)),
          )
        else if (_comparisonData == null)
          _buildComparisonEmpty(isDark)
        else ...[
          // Блок Б: Вердикт
          _buildComparisonVerdict(isDark, accent),
          const SizedBox(height: 20),

          // Блок В: Рейтинг
          _buildSectionTitle('📋 Рейтинг груп', isDark),
          const SizedBox(height: 12),
          _buildComparisonRankedList(isDark, accent),
        ],

        const SizedBox(height: 40),
      ],
    );
  }

  Widget _buildComparisonEmpty(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
      child: Column(
        children: [
          Icon(Icons.compare_arrows, size: 56, color: Colors.grey.shade500),
          const SizedBox(height: 16),
          Text('Оберіть період для порівняння',
              style: TextStyle(
                  fontSize: 15,
                  color: Colors.grey.shade500,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
          Text(
              'Натисніть будь-яку кнопку вище, щоб завантажити дані порівняння',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        ],
      ),
    );
  }

  Widget _buildComparisonPeriodFilter(bool isDark, Color accent) {
    final options = [
      {'label': 'Сьогодні', 'days': 1, 'icon': Icons.today},
      {'label': 'Вчора', 'days': 2, 'icon': Icons.history},
      {'label': '7 днів', 'days': 7, 'icon': Icons.date_range},
      {'label': '30 днів', 'days': 30, 'icon': Icons.calendar_month},
      {'label': '60 днів', 'days': 60, 'icon': Icons.calendar_today},
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: options.map((opt) {
        final days = opt['days'] as int;
        final isSelected = _comparisonDays == days && _comparisonData != null;
        return ChoiceChip(
          avatar: Icon(opt['icon'] as IconData,
              size: 16,
              color: isSelected
                  ? Colors.white
                  : (isDark ? Colors.grey.shade400 : Colors.grey.shade600)),
          label: Text(opt['label'] as String),
          selected: isSelected,
          selectedColor: accent,
          backgroundColor:
              isDark ? const Color(0xFF2A2A2A) : Colors.grey.shade200,
          labelStyle: TextStyle(
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            color: isSelected
                ? Colors.white
                : (isDark ? Colors.grey.shade300 : Colors.grey.shade700),
          ),
          onSelected: (_) => _loadComparison(days),
        );
      }).toList(),
    );
  }

  Widget _buildComparisonVerdict(bool isDark, Color accent) {
    final data = _comparisonData!;
    if (data.ranked.isEmpty) return _buildNoDataWidget();

    final best = data.ranked.first;
    final worst = data.ranked.last;

    // Знаходимо групу користувача
    final userGroup = data.ranked.firstWhere(
      (g) => g.groupKey == widget.groupKey,
      orElse: () => data.ranked.first,
    );

    // Різниця з лідером
    final diffWithBest = userGroup.totalOffMinutes - best.totalOffMinutes;
    final diffPercent = best.totalOffMinutes > 0
        ? (diffWithBest / best.totalOffMinutes * 100).round()
        : 0;

    // Позиція користувача
    final userPosition =
        data.ranked.indexWhere((g) => g.groupKey == widget.groupKey) + 1;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? [const Color(0xFF1A1A2E), const Color(0xFF16213E)]
              : [Colors.indigo.shade50, Colors.purple.shade50],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.1)
              : Colors.indigo.shade100,
        ),
      ),
      child: Column(
        children: [
          // Лідер та аутсайдер
          Row(
            children: [
              // Лідер
              Expanded(
                child: _buildVerdictCard(
                  emoji: '🏆',
                  title: 'Лідер',
                  groupName: best.displayName,
                  value: best.totalFormatted,
                  color: Colors.green.shade400,
                  isDark: isDark,
                ),
              ),
              const SizedBox(width: 12),
              // Аутсайдер
              Expanded(
                child: _buildVerdictCard(
                  emoji: '💀',
                  title: 'Аутсайдер',
                  groupName: worst.displayName,
                  value: worst.totalFormatted,
                  color: Colors.red.shade400,
                  isDark: isDark,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Ваша група
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.05)
                  : Colors.white.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: accent.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '#$userPosition',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: accent,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${userGroup.displayName} (Ви)',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        diffWithBest == 0
                            ? 'Ви — лідер! 🎉'
                            : 'На $diffPercent% більше відключень, ніж у лідера',
                        style: TextStyle(
                          fontSize: 12,
                          color: diffWithBest == 0
                              ? Colors.green.shade400
                              : Colors.orange.shade300,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  userGroup.totalFormatted,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white70 : Colors.black54,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVerdictCard({
    required String emoji,
    required String title,
    required String groupName,
    required String value,
    required Color color,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.white.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Text(emoji, style: const TextStyle(fontSize: 28)),
          const SizedBox(height: 6),
          Text(title,
              style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade500,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(groupName,
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.bold, color: color)),
          const SizedBox(height: 2),
          Text(value,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
        ],
      ),
    );
  }

  Widget _buildComparisonRankedList(bool isDark, Color accent) {
    final data = _comparisonData!;
    if (data.ranked.isEmpty) return _buildNoDataWidget();

    final worstMinutes = data.ranked.last.totalOffMinutes;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(20),
        border:
            Border.all(color: isDark ? Colors.white10 : Colors.grey.shade300),
      ),
      child: Column(
        children: List.generate(data.ranked.length, (index) {
          final group = data.ranked[index];
          final position = index + 1;
          final isUserGroup = group.groupKey == widget.groupKey;
          final progress =
              worstMinutes > 0 ? group.totalOffMinutes / worstMinutes : 0.0;

          // Кольори для топ-3
          Color positionColor;
          IconData? positionIcon;
          if (position == 1) {
            positionColor = const Color(0xFFFFD700); // золото
            positionIcon = Icons.emoji_events;
          } else if (position == 2) {
            positionColor = const Color(0xFFC0C0C0); // срібло
            positionIcon = Icons.emoji_events;
          } else if (position == 3) {
            positionColor = const Color(0xFFCD7F32); // бронза
            positionIcon = Icons.emoji_events;
          } else {
            positionColor = Colors.grey.shade500;
            positionIcon = null;
          }

          // Колір прогресс-бару
          final barColor =
              Color.lerp(Colors.green.shade400, Colors.red.shade400, progress)!;

          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: isUserGroup
                  ? (isDark
                      ? accent.withValues(alpha: 0.1)
                      : accent.withValues(alpha: 0.05))
                  : null,
              border: Border(
                bottom: BorderSide(
                  color: isDark ? Colors.white10 : Colors.grey.shade200,
                  width: index < data.ranked.length - 1 ? 0.5 : 0,
                ),
              ),
              borderRadius: index == 0
                  ? const BorderRadius.only(
                      topLeft: Radius.circular(20),
                      topRight: Radius.circular(20))
                  : index == data.ranked.length - 1
                      ? const BorderRadius.only(
                          bottomLeft: Radius.circular(20),
                          bottomRight: Radius.circular(20))
                      : null,
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    // Позиція
                    SizedBox(
                      width: 36,
                      child: positionIcon != null
                          ? Icon(positionIcon, color: positionColor, size: 22)
                          : Center(
                              child: Text(
                                '$position',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: positionColor,
                                ),
                              ),
                            ),
                    ),
                    const SizedBox(width: 10),
                    // Назва групи
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                group.displayName,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: isUserGroup
                                      ? FontWeight.w800
                                      : FontWeight.w500,
                                  color: isUserGroup
                                      ? accent
                                      : (isDark
                                          ? Colors.white
                                          : Colors.black87),
                                ),
                              ),
                              if (isUserGroup) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: accent.withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text('Ви',
                                      style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                          color: accent)),
                                ),
                              ],
                            ],
                          ),
                          if (group.daysWithData == 0)
                            Text('Немає даних',
                                style: TextStyle(
                                    fontSize: 11, color: Colors.grey.shade500)),
                        ],
                      ),
                    ),
                    // Значення
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          group.daysWithData > 0 ? group.totalFormatted : '—',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: isDark ? Colors.white70 : Colors.black87,
                          ),
                        ),
                        Text(
                          group.daysWithData > 0
                              ? '${group.offPercentage.toStringAsFixed(1)}%'
                              : '',
                          style: TextStyle(
                              fontSize: 11, color: Colors.red.shade300),
                        ),
                      ],
                    ),
                  ],
                ),
                // Прогресс-бар
                if (group.daysWithData > 0) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress.clamp(0.0, 1.0),
                      minHeight: 6,
                      backgroundColor:
                          isDark ? Colors.white10 : Colors.grey.shade300,
                      valueColor: AlwaysStoppedAnimation<Color>(barColor),
                    ),
                  ),
                ],
              ],
            ),
          );
        }),
      ),
    );
  }

  // ============================================================
  // SHARED WIDGETS
  // ============================================================

  Widget _buildSectionTitle(String title, bool isDark) {
    return Text(title,
        style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: isDark ? Colors.white : Colors.black87));
  }

  Widget _buildInfoTile(
      IconData icon, String title, String subtitle, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(14),
        border:
            Border.all(color: isDark ? Colors.white10 : Colors.grey.shade300),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.orange, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey.shade400)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoDataWidget({String text = 'Недостатньо даних'}) {
    return Container(
      padding: const EdgeInsets.all(24),
      alignment: Alignment.center,
      child: Column(
        children: [
          Icon(Icons.inbox, size: 40, color: Colors.grey.shade600),
          const SizedBox(height: 8),
          Text(text, style: TextStyle(color: Colors.grey.shade500)),
        ],
      ),
    );
  }
}

class ScheduleTimelinePainter extends CustomPainter {
  final DailySchedule? schedule;
  final bool isDark;

  ScheduleTimelinePainter({required this.schedule, required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    if (schedule == null) return;

    final paint = Paint()..style = PaintingStyle.fill;
    final w = size.width;
    final h = size.height;

    // Draw background
    paint.color = isDark ? Colors.white10 : Colors.grey.shade300;
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), paint);

    final totalMinutes = 24 * 60;
    final minuteWidth = w / totalMinutes;

    for (int hour = 0; hour < 24; hour++) {
      final status = schedule!.hours[hour];
      Color color;
      switch (status) {
        case LightStatus.on:
          color = Colors.green.shade400;
          break;
        case LightStatus.off:
          color = Colors.red.shade400;
          break;
        case LightStatus.maybe:
          color = Colors.grey.shade600;
          break;
        case LightStatus.semiOn:
          // Off first 30 -> On
          // We handle split below
          color = Colors.transparent;
          break;
        case LightStatus.semiOff:
          // On first 30 -> Off
          color = Colors.transparent;
          break;
        default:
          color = Colors.transparent;
      }

      if (status == LightStatus.semiOn) {
        // 0-30 OFF, 30-60 ON
        paint.color = Colors.red.shade400;
        canvas.drawRect(
            Rect.fromLTWH(hour * 60 * minuteWidth, 0, 30 * minuteWidth, h),
            paint);
        paint.color = Colors.green.shade400;
        canvas.drawRect(
            Rect.fromLTWH(
                (hour * 60 + 30) * minuteWidth, 0, 30 * minuteWidth, h),
            paint);
      } else if (status == LightStatus.semiOff) {
        // 0-30 ON, 30-60 OFF
        paint.color = Colors.green.shade400;
        canvas.drawRect(
            Rect.fromLTWH(hour * 60 * minuteWidth, 0, 30 * minuteWidth, h),
            paint);
        paint.color = Colors.red.shade400;
        canvas.drawRect(
            Rect.fromLTWH(
                (hour * 60 + 30) * minuteWidth, 0, 30 * minuteWidth, h),
            paint);
      } else if (color != Colors.transparent) {
        paint.color = color;
        canvas.drawRect(
            Rect.fromLTWH(hour * 60 * minuteWidth, 0, 60 * minuteWidth, h),
            paint);
      }
    }

    // Grid lines every hour
    paint.color = isDark ? Colors.black26 : Colors.white54;
    paint.strokeWidth = 1;
    for (int i = 1; i < 24; i++) {
      canvas.drawLine(Offset(i * 60 * minuteWidth, 0),
          Offset(i * 60 * minuteWidth, h), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class RealityTimelinePainter extends CustomPainter {
  final List<PowerOutageInterval> intervals;
  final bool isDark;

  RealityTimelinePainter({required this.intervals, required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    final w = size.width;
    final h = size.height;
    final now = DateTime.now();
    final totalMinutes = 24 * 60;
    final minuteWidth = w / totalMinutes;

    // Draw background (Green implies online by default, or Grey if unknown?
    // User wants "gradually filling".
    // Let's assume everything is GREEN until NOW, unless there is an interval.
    // Future is GREY.

    final dayStart = DateTime(now.year, now.month, now.day);
    final dayEnd = dayStart.add(const Duration(days: 1));

    // Draw base grey (future/unknown)
    paint.color = isDark ? Colors.white10 : Colors.grey.shade300;
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), paint);

    // Draw "Online" base up to NOW
    int nowMinutes = now.hour * 60 + now.minute;
    if (nowMinutes > totalMinutes) nowMinutes = totalMinutes; // Just in case

    paint.color = Colors.green.shade400;
    canvas.drawRect(Rect.fromLTWH(0, 0, nowMinutes * minuteWidth, h), paint);

    // Draw "Offline" intervals (Red)
    paint.color = Colors.red.shade400;

    for (final interval in intervals) {
      // Calculate start/end minutes from start of day
      // Interval might be from prev day or to next day, need to clamp

      DateTime start = interval.start;
      DateTime? end = interval.end;

      if (start.isBefore(dayStart)) start = dayStart;
      if (end == null || end.isAfter(dayEnd)) {
        // If null, it means it's still ongoing.
        // But for rendering we clamp to NOW (or dayEnd if logic differs)
        // Typically current interval goes up to NOW.
        end = now;
      }

      final startOffset = start.difference(dayStart).inMinutes;
      final endOffset = end.difference(dayStart).inMinutes;

      final duration = endOffset - startOffset;
      if (duration > 0) {
        canvas.drawRect(
            Rect.fromLTWH(
                startOffset * minuteWidth, 0, duration * minuteWidth, h),
            paint);
      }
    }

    // Grid lines every hour
    paint.color = isDark ? Colors.black26 : Colors.white54;
    paint.strokeWidth = 1;
    for (int i = 1; i < 24; i++) {
      canvas.drawLine(Offset(i * 60 * minuteWidth, 0),
          Offset(i * 60 * minuteWidth, h), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
