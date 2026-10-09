import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../models/analytics_models.dart';
import '../../services/app_logger.dart';
import '../../utils/app_formatters.dart';

typedef ScheduleDeviationLoader = Future<ScheduleDeviationStats> Function(
    ScheduleDeviationPeriod period, String groupKey);

class ScheduleDeviationSection extends StatefulWidget {
  final String groupKey;
  final int revision;
  final ScheduleDeviationLoader load;
  final ScheduleDeviationPeriod initialPeriod;
  final ValueChanged<ScheduleDeviationPeriod>? onPeriodChanged;

  const ScheduleDeviationSection(
      {super.key,
      required this.groupKey,
      required this.load,
      this.revision = 0,
      this.initialPeriod = ScheduleDeviationPeriod.yesterday,
      this.onPeriodChanged});

  @override
  State<ScheduleDeviationSection> createState() =>
      _ScheduleDeviationSectionState();
}

class _ScheduleDeviationSectionState extends State<ScheduleDeviationSection> {
  late ScheduleDeviationPeriod _period;
  ScheduleDeviationStats? _data;
  bool _loading = true;
  bool _failed = false;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _period = widget.initialPeriod;
    _reload();
  }

  @override
  void didUpdateWidget(covariant ScheduleDeviationSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groupKey != widget.groupKey ||
        oldWidget.revision != widget.revision) {
      _reload();
    }
  }

  Future<void> _reload() async {
    final request = ++_requestId;
    setState(() {
      _loading = true;
      _failed = false;
      _data = null;
    });
    try {
      final data = await widget.load(_period, widget.groupKey);
      if (!mounted || request != _requestId) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (error, stack) {
      AppLogger.e('Unable to load schedule deviation',
          tag: 'ScheduleDeviation', error: error, stackTrace: stack);
      if (!mounted || request != _requestId) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accent = dark ? Colors.orange : Colors.deepPurple;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Row(children: [
        Icon(Icons.compare_arrows, size: 21),
        SizedBox(width: 8),
        Expanded(
            child: Text('Відхилення від графіка',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)))
      ]),
      const SizedBox(height: 12),
      CupertinoSlidingSegmentedControl<ScheduleDeviationPeriod>(
        groupValue: _period,
        thumbColor: accent,
        backgroundColor: dark ? Colors.white10 : Colors.grey.shade200,
        children: {
          for (final period in ScheduleDeviationPeriod.values)
            period: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: Text(_periodLabel(period),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 12,
                        color: _period == period
                            ? (dark ? Colors.black : Colors.white)
                            : (dark
                                ? Colors.grey.shade300
                                : Colors.grey.shade700))))
        },
        onValueChanged: (period) {
          if (period == null || period == _period) return;
          setState(() => _period = period);
          widget.onPeriodChanged?.call(period);
          _reload();
        },
      ),
      const SizedBox(height: 12),
      Material(
        color: dark ? const Color(0xFF1E1E1E) : Colors.grey.shade100,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(17),
            side: BorderSide(
                color: dark ? Colors.white10 : Colors.grey.shade300)),
        clipBehavior: Clip.antiAlias,
        child: Padding(
            padding: const EdgeInsets.all(20),
            child: _loading
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                        child: CircularProgressIndicator(
                            semanticsLabel:
                                'Завантаження відхилень від графіка')))
                : _failed
                    ? Column(children: [
                        const Text('Не вдалося завантажити порівняння.'),
                        TextButton(
                            onPressed: _reload, child: const Text('Повторити'))
                      ])
                    : _buildData(context, _data!, dark)),
      ),
    ]);
  }

  Widget _buildData(
      BuildContext context, ScheduleDeviationStats data, bool dark) {
    final balance = data.balance;
    final muted = dark ? Colors.grey.shade400 : Colors.grey.shade700;
    final positive = dark ? Colors.green.shade200 : Colors.green.shade800;
    final negative = dark ? Colors.red.shade200 : Colors.red.shade800;
    final delta = balance.averageDeltaMinutes;
    final color = delta == null || delta == 0
        ? muted
        : delta > 0
            ? positive
            : negative;
    final multi = balance.period.dayCount > 1;
    final percent = balance.relativePercentage;
    final daysText =
        '${balance.validDays} із ${balance.period.dayCount} завершених днів';
    final coverage = balance.period == ScheduleDeviationPeriod.today
        ? 'Від 00:00 до ${AppFormatters.fmtTime(balance.end)}'
        : multi
            ? daysText
            : 'За завершену добу';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (balance.hasData) ...[
        Text(
            balance.deltaSeconds == 0
                ? 'Сумарний час зі світлом збігся'
                : balance.deltaSeconds > 0
                    ? 'Світла більше, ніж за графіком'
                    : 'Світла менше, ніж за графіком',
            style: TextStyle(color: muted, fontSize: 13)),
        const SizedBox(height: 8),
        Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('${_signedMinutes(delta!)}${multi ? ' / день' : ''}',
                  key: const ValueKey('light-balance-value'),
                  style: TextStyle(
                      color: color, fontSize: 30, fontWeight: FontWeight.w700)),
              if (percent != null)
                Text(_signedPercent(percent),
                    key: const ValueKey('light-balance-percent'),
                    style: TextStyle(
                        color: color,
                        fontSize: 15,
                        fontWeight: FontWeight.w600))
            ]),
        const SizedBox(height: 8),
        Text(_sentence(balance)),
        const SizedBox(height: 8),
        Text('$coverage · Остання версія графіка',
            style: TextStyle(color: muted, fontSize: 12)),
        if (balance.excludedDays > 0)
          Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Виключено днів: ${balance.excludedDays}',
                  style: TextStyle(color: muted, fontSize: 12))),
      ] else ...[
        const Text('Недостатньо даних для порівняння',
            style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text('Потрібні визначений графік і записи датчика за той самий час.',
            style: TextStyle(color: muted)),
      ],
      const Padding(
          padding: EdgeInsets.symmetric(vertical: 12), child: Divider()),
      Text('Час перемикань', style: TextStyle(color: muted, fontSize: 12)),
      const SizedBox(height: 12),
      LayoutBuilder(builder: (context, constraints) {
        final rows = [
          _lagRow('Увімкнення', Icons.power, data.lag.avgOnLagMinutes,
              data.lag.onSampleCount, false, positive, negative, muted),
          _lagRow('Вимкнення', Icons.power_off, data.lag.avgOffLagMinutes,
              data.lag.offSampleCount, true, positive, negative, muted),
        ];
        return constraints.maxWidth < 460
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [rows[0], const SizedBox(height: 12), rows[1]])
            : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: rows[0]),
                const SizedBox(width: 16),
                Expanded(child: rows[1])
              ]);
      }),
      const SizedBox(height: 14),
      Text(
          data.lag.sampleCount == 0
              ? 'Недостатньо спостережень для розрахунку лагу'
              : 'На основі ${data.lag.sampleCount} спостережень',
          style: TextStyle(color: muted, fontSize: 12)),
      Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            title: Text('Деталі розрахунку',
                style: TextStyle(color: muted, fontSize: 12)),
            children: [
              if (balance.hasData) ...[
                _detail(
                    'Світла за графіком', _duration(balance.plannedOnSeconds)),
                _detail('Світла фактично', _duration(balance.actualOnSeconds)),
                _detail('Різниця за період',
                    _signedMinutes(balance.deltaSeconds / 60)),
                if (percent == null)
                  const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                          'Відсоток не визначено: за графіком не було часу зі світлом.',
                          style: TextStyle(fontSize: 12))),
              ],
              for (final reason in LightBalanceExclusion.values)
                if ((balance.exclusions[reason] ?? 0) > 0)
                  _detail(
                      _exclusionLabel(reason), '${balance.exclusions[reason]}'),
              const SizedBox(height: 8),
              Text(
                  'Записи датчика ↔ ${AppFormatters.formatGroupName(widget.groupKey)}. '
                  'Відсоток розраховано від запланованого часу зі світлом. '
                  'Порівняння з останнім збереженим графіком; історичні стани '
                  'датчика діють до наступної події в межах доступних спостережень.',
                  style: TextStyle(color: muted, fontSize: 12)),
            ],
          )),
    ]);
  }

  Widget _lagRow(String label, IconData icon, double minutes, int count,
      bool off, Color positive, Color negative, Color muted) {
    final good = off ? minutes > 0 : minutes < 0;
    final color = count == 0 || minutes == 0
        ? muted
        : good
            ? positive
            : negative;
    final text = count == 0
        ? 'Немає спостережень'
        : minutes == 0
            ? 'У середньому за графіком'
            : 'На ${_magnitude(minutes)} хв ${minutes > 0 ? 'пізніше' : 'раніше'}';
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 20, color: color)),
      const SizedBox(width: 8),
      Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        Text(text, style: TextStyle(color: color, fontSize: 13)),
      ])),
    ]);
  }

  Widget _detail(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Text(label, style: const TextStyle(fontSize: 12))),
        const SizedBox(width: 12),
        Text(value, style: const TextStyle(fontSize: 12)),
      ]));

  static String _periodLabel(ScheduleDeviationPeriod period) =>
      switch (period) {
        ScheduleDeviationPeriod.today => 'Сьогодні',
        ScheduleDeviationPeriod.yesterday => 'Вчора',
        ScheduleDeviationPeriod.week => 'Тиждень',
        ScheduleDeviationPeriod.month => 'Місяць',
      };

  static String _exclusionLabel(LightBalanceExclusion reason) =>
      switch (reason) {
        LightBalanceExclusion.missingSchedule => 'Днів без графіка',
        LightBalanceExclusion.uncertainSchedule =>
          'Днів із невизначеним графіком',
        LightBalanceExclusion.incompleteActual =>
          'Днів із неповними записами датчика',
      };

  static String _magnitude(double minutes) => minutes.abs() < 1 && minutes != 0
      ? 'менш ніж 1'
      : minutes.abs().round().toString();

  static String _signedMinutes(double minutes) => minutes == 0
      ? '0 хв'
      : '${minutes > 0 ? '+' : '−'}${_magnitude(minutes)} хв';

  static String _signedPercent(double value) => value != 0 && value.abs() < 0.1
      ? '${value > 0 ? '+' : '−'}<0,1%'
      : '${value > 0 ? '+' : value < 0 ? '−' : ''}${value.abs().toStringAsFixed(1).replaceAll('.', ',')}%';

  static String _duration(int seconds) => seconds > 0 && seconds < 60
      ? 'Менше 1 хв'
      : AppFormatters.formatDuration((seconds / 60).round());

  static String _sentence(LightBalanceStats balance) {
    final minutes = balance.averageDeltaMinutes!;
    if (minutes == 0) return 'Сумарний час зі світлом збігся з графіком.';
    if (minutes.abs() < 1) {
      return balance.period.dayCount > 1
          ? 'Середня різниця становить менше хвилини на день.'
          : 'Різниця становить менше хвилини.';
    }
    final prefix = balance.period == ScheduleDeviationPeriod.today
        ? 'Сьогодні'
        : balance.period == ScheduleDeviationPeriod.yesterday
            ? 'Учора'
            : 'У середньому';
    return '$prefix світла було на ${_magnitude(minutes)} хв '
        '${minutes > 0 ? 'довше' : 'менше'}'
        '${balance.period.dayCount > 1 ? ' на день' : ''}, ніж за графіком.';
  }
}
