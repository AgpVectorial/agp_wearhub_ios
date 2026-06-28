import 'dart:math';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/locale.dart';
import '../../storage/vitals_db.dart';
import '../../storage/user_repository.dart';

/// Pagina de istoric cu grafice pentru toate semnalele vitale.
class HistoryPage extends ConsumerStatefulWidget {
  final String deviceId;
  final String? deviceName;

  const HistoryPage({super.key, required this.deviceId, this.deviceName});

  @override
  ConsumerState<HistoryPage> createState() => _HistoryPageState();
}

enum _TimeRange { h1, h6, h24, d7 }

class _HistoryPageState extends ConsumerState<HistoryPage> {
  _TimeRange _range = _TimeRange.h24;
  VitalType _selectedType = VitalType.hr;

  List<VitalRecord> _records = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Duration get _duration => switch (_range) {
    _TimeRange.h1 => const Duration(hours: 1),
    _TimeRange.h6 => const Duration(hours: 6),
    _TimeRange.h24 => const Duration(hours: 24),
    _TimeRange.d7 => const Duration(days: 7),
  };

  String _rangeLabel(_TimeRange r) => switch (r) {
    _TimeRange.h1 => '1h',
    _TimeRange.h6 => '6h',
    _TimeRange.h24 => '24h',
    _TimeRange.d7 => '7d',
  };

  Future<void> _loadData() async {
    setState(() => _loading = true);
    final db = ref.read(vitalsDbProvider);
    final userId = ref.read(userSessionProvider.notifier).userId;
    final now = DateTime.now();
    final from = now.subtract(_duration);
    final records = await db.query(
      deviceId: widget.deviceId,
      type: _selectedType,
      userId: userId,
      from: from,
      to: now,
    );
    if (mounted) {
      setState(() {
        _records = records;
        _loading = false;
      });
    }
  }

  static const _typeConfig = <VitalType, _VitalConfig>{
    VitalType.hr: _VitalConfig(
      icon: Icons.favorite_rounded,
      color: Colors.red,
      unitKey: 'bpm',
      titleKey: 'hr',
    ),
    VitalType.spo2: _VitalConfig(
      icon: Icons.bloodtype_rounded,
      color: Colors.blue,
      unitKey: '%',
      titleKey: 'spo2',
    ),
    VitalType.temp: _VitalConfig(
      icon: Icons.thermostat_rounded,
      color: Colors.orange,
      unitKey: '°C',
      titleKey: 'temperature',
    ),
    VitalType.steps: _VitalConfig(
      icon: Icons.directions_walk_rounded,
      color: Colors.green,
      unitKey: '',
      titleKey: 'steps',
    ),
    VitalType.battery: _VitalConfig(
      icon: Icons.battery_std_rounded,
      color: Colors.amber,
      unitKey: '%',
      titleKey: 'battery',
    ),
    VitalType.bp: _VitalConfig(
      icon: Icons.monitor_heart_rounded,
      color: Colors.indigo,
      unitKey: 'mmHg',
      titleKey: 'bloodPressure',
    ),
    VitalType.hrv: _VitalConfig(
      icon: Icons.insights_rounded,
      color: Colors.purple,
      unitKey: 'ms',
      titleKey: 'hrv',
    ),
    VitalType.stress: _VitalConfig(
      icon: Icons.psychology_rounded,
      color: Colors.deepOrange,
      unitKey: '',
      titleKey: 'stress',
    ),
  };

  @override
  Widget build(BuildContext context) {
    final t = T(ref.watch(localeProvider));
    final theme = Theme.of(context);
    final config = _typeConfig[_selectedType] ?? _typeConfig[VitalType.hr]!;

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: Text(
          t.tr('history'),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: Column(
        children: [
          // Selector tip vital
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: VitalType.values.map((vt) {
                  final c = _typeConfig[vt];
                  if (c == null) return const SizedBox.shrink();
                  final selected = vt == _selectedType;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      selected: selected,
                      avatar: Icon(
                        c.icon,
                        size: 16,
                        color: selected ? Colors.white : c.color,
                      ),
                      label: Text(t.tr(c.titleKey)),
                      selectedColor: c.color,
                      checkmarkColor: Colors.white,
                      labelStyle: TextStyle(
                        color: selected
                            ? Colors.white
                            : theme.colorScheme.onSurface,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                      onSelected: (_) {
                        setState(() => _selectedType = vt);
                        _loadData();
                      },
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          const SizedBox(height: 8),

          // Selector interval temporal
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: _TimeRange.values.map((r) {
                final selected = r == _range;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: ChoiceChip(
                      label: Text(_rangeLabel(r)),
                      selected: selected,
                      selectedColor: config.color.withOpacity(0.2),
                      onSelected: (_) {
                        setState(() => _range = r);
                        _loadData();
                      },
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 8),

          // Statistici sumar
          if (!_loading && _records.isNotEmpty)
            _StatsRow(records: _records, config: config, t: t),

          const SizedBox(height: 8),

          // Grafic
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _records.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.timeline_rounded,
                            size: 64,
                            color: theme.colorScheme.onSurface.withOpacity(0.3),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            t.tr('noHistoryData'),
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: theme.colorScheme.onSurface.withOpacity(
                                0.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : _VitalChart(
                      records: _records,
                      config: config,
                      duration: _duration,
                    ),
            ),
          ),

          // Lista ultimelor sample-uri
          if (!_loading && _records.isNotEmpty)
            SizedBox(
              height: 200,
              child: _RecordsList(
                records: _records,
                config: config,
                selectedType: _selectedType,
              ),
            ),
        ],
      ),
    );
  }
}

class _VitalConfig {
  final IconData icon;
  final Color color;
  final String unitKey;
  final String titleKey;

  const _VitalConfig({
    required this.icon,
    required this.color,
    required this.unitKey,
    required this.titleKey,
  });
}

/// Grafic linie fl_chart
class _VitalChart extends StatelessWidget {
  final List<VitalRecord> records;
  final _VitalConfig config;
  final Duration duration;

  const _VitalChart({
    required this.records,
    required this.config,
    required this.duration,
  });

  @override
  Widget build(BuildContext context) {
    if (records.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final spots = records
        .map((r) => FlSpot(r.ts.millisecondsSinceEpoch.toDouble(), r.value))
        .toList();

    final minX = spots.first.x;
    final maxX = spots.last.x;
    final values = records.map((r) => r.value);
    final minY = values.reduce(min) - 2;
    final maxY = values.reduce(max) + 2;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outline.withOpacity(0.15)),
      ),
      padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
      child: LineChart(
        LineChartData(
          minX: minX,
          maxX: maxX,
          minY: minY.floorToDouble(),
          maxY: maxY.ceilToDouble(),
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: _yInterval(minY, maxY),
            getDrawingHorizontalLine: (v) => FlLine(
              color: theme.colorScheme.outline.withOpacity(0.1),
              strokeWidth: 1,
            ),
          ),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 42,
                interval: _yInterval(minY, maxY),
                getTitlesWidget: (v, meta) => Text(
                  v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.5),
                    fontSize: 10,
                  ),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 28,
                interval: (maxX - minX) / 4,
                getTitlesWidget: (v, meta) {
                  final dt = DateTime.fromMillisecondsSinceEpoch(v.toInt());
                  final fmt = duration.inHours <= 6 ? 'HH:mm' : 'dd/MM HH:mm';
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      DateFormat(fmt).format(dt),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 9,
                        color: theme.colorScheme.onSurface.withOpacity(0.5),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          borderData: FlBorderData(show: false),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              curveSmoothness: 0.2,
              color: config.color,
              barWidth: 2,
              isStrokeCapRound: true,
              dotData: FlDotData(
                show: spots.length < 60,
                getDotPainter: (spot, percent, bar, index) =>
                    FlDotCirclePainter(
                      radius: 2,
                      color: config.color,
                      strokeWidth: 0,
                    ),
              ),
              belowBarData: BarAreaData(
                show: true,
                color: config.color.withOpacity(0.08),
              ),
            ),
          ],
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipItems: (touchedSpots) => touchedSpots.map((spot) {
                final dt = DateTime.fromMillisecondsSinceEpoch(spot.x.toInt());
                return LineTooltipItem(
                  '${spot.y.toStringAsFixed(1)}\n${DateFormat('HH:mm:ss').format(dt)}',
                  TextStyle(
                    color: config.color,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                );
              }).toList(),
            ),
          ),
        ),
        duration: const Duration(milliseconds: 300),
      ),
    );
  }

  double _yInterval(double minY, double maxY) {
    final range = maxY - minY;
    if (range <= 10) return 2;
    if (range <= 50) return 10;
    if (range <= 100) return 20;
    return (range / 5).roundToDouble();
  }
}

/// Rând cu min, max, medie
class _StatsRow extends StatelessWidget {
  final List<VitalRecord> records;
  final _VitalConfig config;
  final T t;

  const _StatsRow({
    required this.records,
    required this.config,
    required this.t,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final values = records.map((r) => r.value).toList();
    final minVal = values.reduce(min);
    final maxVal = values.reduce(max);
    final avg = values.reduce((a, b) => a + b) / values.length;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          _StatChip(label: 'Min', value: minVal, config: config, theme: theme),
          const SizedBox(width: 8),
          _StatChip(
            label: t.tr('average'),
            value: avg,
            config: config,
            theme: theme,
          ),
          const SizedBox(width: 8),
          _StatChip(label: 'Max', value: maxVal, config: config, theme: theme),
          const SizedBox(width: 8),
          _StatChip(
            label: t.tr('samples'),
            value: values.length.toDouble(),
            config: config,
            theme: theme,
            isCount: true,
          ),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final double value;
  final _VitalConfig config;
  final ThemeData theme;
  final bool isCount;

  const _StatChip({
    required this.label,
    required this.value,
    required this.config,
    required this.theme,
    this.isCount = false,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: config.color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: config.color.withOpacity(0.15)),
        ),
        child: Column(
          children: [
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.6),
                fontSize: 10,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              isCount ? value.toInt().toString() : value.toStringAsFixed(1),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: config.color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Lista cronologică a ultimelor sample-uri
class _RecordsList extends StatelessWidget {
  final List<VitalRecord> records;
  final _VitalConfig config;
  final VitalType selectedType;

  const _RecordsList({
    required this.records,
    required this.config,
    required this.selectedType,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Ultimele 50, ordine inversă (cele mai recente primele)
    final items = records.reversed.take(50).toList();

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outline.withOpacity(0.15)),
      ),
      child: ListView.separated(
        padding: const EdgeInsets.all(8),
        itemCount: items.length,
        separatorBuilder: (_, __) => Divider(
          height: 1,
          color: theme.colorScheme.outline.withOpacity(0.08),
        ),
        itemBuilder: (context, i) {
          final rec = items[i];
          final timeStr = DateFormat('dd MMM HH:mm:ss').format(rec.ts);
          final valStr = selectedType == VitalType.temp
              ? rec.value.toStringAsFixed(1)
              : rec.value.toInt().toString();
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
            child: Row(
              children: [
                Icon(config.icon, size: 14, color: config.color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    timeStr,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withOpacity(0.6),
                    ),
                  ),
                ),
                Text(
                  '$valStr ${config.unitKey}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: config.color,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Formatare simplificată a datei, fără dependența intl completă.
/// Dacă `intl` nu e disponibil, folosim un formatter manual.
class DateFormat {
  final String pattern;
  DateFormat(this.pattern);

  String format(DateTime dt) {
    final months = [
      '',
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return pattern
        .replaceAll('dd', dt.day.toString().padLeft(2, '0'))
        .replaceAll('MM', dt.month.toString().padLeft(2, '0'))
        .replaceAll('MMM', months[dt.month])
        .replaceAll('HH', dt.hour.toString().padLeft(2, '0'))
        .replaceAll('mm', dt.minute.toString().padLeft(2, '0'))
        .replaceAll('ss', dt.second.toString().padLeft(2, '0'));
  }
}
