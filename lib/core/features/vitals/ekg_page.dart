import 'dart:async';
import 'dart:math' as math;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/locale.dart';
import '../../services/ekg_export_service.dart';
import '../../storage/user_repository.dart';

/// Pagina EKG — randare live cu grilă, controale și hook pentru stream real.
/// - Poți pasa un Stream<double> cu eșantioane în mV prin [ekgStream].
/// - Dacă [ekgStream] este null, pornește un generator demo (sinus cu zgomot).
class EkgPage extends ConsumerStatefulWidget {
  const EkgPage({
    super.key,
    this.ekgStream,
    this.title, // dacă e null, folosim t.ekg
    this.sampleRateHz = 250,
  });

  final Stream<double>? ekgStream;
  final String? title;
  final int sampleRateHz;

  @override
  ConsumerState<EkgPage> createState() => _EkgPageState();
}

class _EkgPageState extends ConsumerState<EkgPage> with WidgetsBindingObserver {
  late final int _bufferSeconds;
  late final int _bufferCapacity;
  late final List<double> _buffer;
  int _writeIndex = 0;
  int _valid = 0;

  bool _isRunning = false;
  StreamSubscription<double>? _sub;
  Timer? _demoTimer;

  int _speedMmPerSec = 25;
  int _gainMmPerMv = 10;

  double? _bpm;
  final List<DateTime> _rPeaks = [];
  final List<double> _sessionSamples = [];
  DateTime? _sessionStartedAt;
  DateTime _lastUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  double _demoPhase = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _bufferSeconds = 10;
    _bufferCapacity = widget.sampleRateHz * _bufferSeconds;
    _buffer = List<double>.filled(_bufferCapacity, 0.0, growable: false);

    if (widget.ekgStream != null) {
      _start();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stop();
    super.dispose();
  }

  void _start() {
    if (_isRunning) return;
    _isRunning = true;
    _sessionStartedAt ??= DateTime.now();

    if (widget.ekgStream != null) {
      _sub = widget.ekgStream!.listen(_onSample, onDone: _onDone);
    } else {
      final dt = Duration(microseconds: (1e6 / widget.sampleRateHz).round());
      _demoTimer = Timer.periodic(dt, (_) {
        _demoPhase += 2 * math.pi * 1.2 / widget.sampleRateHz;
        double v = 0.7 * math.sin(_demoPhase);
        if (_writeIndex % (widget.sampleRateHz * 0.85).round() == 0) {
          v += 2.0;
        }
        v += (math.Random().nextDouble() - 0.5) * 0.08;
        _onSample(v);
      });
    }
    setState(() {});
  }

  void _pause() {
    if (!_isRunning) return;
    _isRunning = false;
    _sub?.pause();
    _demoTimer?.cancel();
    setState(() {});
  }

  void _resume() {
    if (_isRunning) return;
    _isRunning = true;
    _sub?.resume();
    if (widget.ekgStream == null && (_demoTimer == null || !_demoTimer!.isActive)) {
      _start();
    } else {
      setState(() {});
    }
  }

  void _stop() {
    _isRunning = false;
    _sub?.cancel();
    _sub = null;
    _demoTimer?.cancel();
    _demoTimer = null;
    if (mounted) setState(() {});
  }

  void _onDone() {
    _isRunning = false;
    setState(() {});
  }

  void _onSample(double mv) {
    _buffer[_writeIndex] = mv;
    _writeIndex = (_writeIndex + 1) % _bufferCapacity;
    if (_valid < _bufferCapacity) _valid++;
    if (_sessionSamples.length < widget.sampleRateHz * 60 * 30) {
      _sessionSamples.add(mv);
    }
    _detectRPeak(mv);
    final now = DateTime.now();
    if (mounted && now.difference(_lastUiUpdate).inMilliseconds >= 80) {
      _lastUiUpdate = now;
      setState(() {});
    }
  }

  void _detectRPeak(double mv) {
    if (mv < 0.9) return;
    final now = DateTime.now();
    if (_rPeaks.isEmpty || now.difference(_rPeaks.last).inMilliseconds > 220) {
      _rPeaks.add(now);
      if (_rPeaks.length > 10) _rPeaks.removeAt(0);
      if (_rPeaks.length >= 2) {
        final intervals = <int>[];
        for (int i = 1; i < _rPeaks.length; i++) {
          intervals.add(_rPeaks[i].difference(_rPeaks[i - 1]).inMilliseconds);
        }
        final avgMs = intervals.reduce((a, b) => a + b) / intervals.length;
        _bpm = 60000.0 / avgMs;
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pause();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurfaceDim = theme.colorScheme.onSurface.withOpacity(0.7);
    final chartSpots = _buildChartSpots();
    final chartRange = _chartRange(chartSpots);

    final lang = ref.watch(localeProvider);
    final t = T(lang);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.title ?? t.ekg,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: _SafeScrollableBody(
        horizontal: 16,
        top: 12,
        bottomExtra: 12,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ===== Status boxes (compact) =====
            GridView.count(
              crossAxisCount: 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 3.4, // mai scund
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _StatusBox(
                  icon: _isRunning ? Icons.podcasts_rounded : Icons.podcasts_outlined,
                  label: _isRunning ? t.recording : t.stopped,
                  color: _isRunning ? Colors.green : onSurfaceDim,
                ),
                _StatusBox(
                  icon: Icons.favorite_rounded,
                  label: _bpm != null ? '${_bpm!.round()} ${t.bpm.toUpperCase()}' : '-- ${t.bpm.toUpperCase()}',
                  color: theme.colorScheme.primary,
                ),
                _StatusBox(
                  icon: Icons.speed_rounded,
                  label: '$_speedMmPerSec ${t.mmPerSec}',
                  color: onSurfaceDim,
                ),
                _StatusBox(
                  icon: Icons.bar_chart_rounded,
                  label: '$_gainMmPerMv ${t.mmPerMv}',
                  color: onSurfaceDim,
                ),
              ],
            ),

            const SizedBox(height: 12),

            // ===== Grafic EKG =====
            Container(
              height: 260,
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: theme.colorScheme.outline.withOpacity(0.2)),
                boxShadow: [
                  BoxShadow(
                    color: theme.colorScheme.shadow.withOpacity(0.04),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
                  child: LineChart(
                    LineChartData(
                      minX: 0,
                      maxX: chartSpots.isEmpty ? 1 : chartSpots.last.x,
                      minY: chartRange.$1,
                      maxY: chartRange.$2,
                      clipData: const FlClipData.all(),
                      backgroundColor: theme.brightness == Brightness.dark
                          ? const Color(0xFF101215)
                          : const Color(0xFFFFFCFC),
                      borderData: FlBorderData(show: false),
                      titlesData: const FlTitlesData(show: false),
                      lineTouchData: const LineTouchData(enabled: false),
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: true,
                        drawHorizontalLine: true,
                        horizontalInterval: 0.5,
                        verticalInterval: _speedMmPerSec == 50 ? 0.2 : 0.4,
                        getDrawingHorizontalLine: (value) => FlLine(
                          color: theme.brightness == Brightness.dark
                              ? Colors.white10
                              : Colors.red.withOpacity(value == 0 ? 0.28 : 0.12),
                          strokeWidth: value == 0 ? 1.2 : 0.8,
                        ),
                        getDrawingVerticalLine: (value) => FlLine(
                          color: theme.brightness == Brightness.dark
                              ? Colors.white10
                              : Colors.red.withOpacity(
                                  (value * 10).round() % 5 == 0 ? 0.24 : 0.10,
                                ),
                          strokeWidth: (value * 10).round() % 5 == 0 ? 1.0 : 0.8,
                        ),
                      ),
                      lineBarsData: [
                        LineChartBarData(
                          isCurved: false,
                          barWidth: 2,
                          isStrokeCapRound: true,
                          color: theme.colorScheme.primary,
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(show: false),
                          spots: chartSpots.isEmpty
                              ? const [FlSpot(0, 0), FlSpot(1, 0)]
                              : chartSpots,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 12),

            // ===== Controale =====
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _isRunning ? null : _start,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(t.start),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _isRunning ? _pause : _resume,
                    icon: Icon(_isRunning ? Icons.pause_rounded : Icons.play_circle_outline),
                    label: Text(_isRunning ? t.pause : t.resume),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _stop,
                    icon: const Icon(Icons.stop_rounded),
                    label: Text(t.stop),
                    style: FilledButton.styleFrom(backgroundColor: theme.colorScheme.error),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _sessionSamples.isEmpty ? null : _exportPdf,
                    icon: const Icon(Icons.picture_as_pdf_rounded),
                    label: const Text('Export PDF'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _sessionSamples.isEmpty ? null : _exportRaw,
                    icon: const Icon(Icons.download_rounded),
                    label: const Text('Raw CSV'),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // ===== Setări rapide =====
            Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: theme.colorScheme.outline.withOpacity(0.2)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    _SettingRow(
                      icon: Icons.speed_rounded,
                      title: t.paperSpeed,
                      trailing: SegmentedButton<int>(
                        segments: const [
                          ButtonSegment(value: 25, label: Text('25')),
                          ButtonSegment(value: 50, label: Text('50')),
                        ],
                        selected: {_speedMmPerSec},
                        onSelectionChanged: (s) => setState(() => _speedMmPerSec = s.first),
                      ),
                      subtitle: t.mmPerSec,
                    ),
                    const SizedBox(height: 8),
                    _SettingRow(
                      icon: Icons.bar_chart_rounded,
                      title: t.amplitude,
                      trailing: SegmentedButton<int>(
                        segments: const [
                          ButtonSegment(value: 5, label: Text('×0.5')),
                          ButtonSegment(value: 10, label: Text('×1')),
                          ButtonSegment(value: 20, label: Text('×2')),
                        ],
                        selected: {_gainMmPerMv},
                        onSelectionChanged: (s) => setState(() => _gainMmPerMv = s.first),
                      ),
                      subtitle: t.mmPerMv,
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 8),
            Text(
              t.ekgDisclaimer,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.65),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  EkgSessionReport _buildReport() {
    final started = _sessionStartedAt ?? DateTime.now();
    return EkgSessionReport(
      userName: ref.read(userSessionProvider)?.displayName ?? 'User',
      startedAt: started,
      duration: DateTime.now().difference(started),
      sampleRateHz: widget.sampleRateHz,
      samples: List<double>.unmodifiable(_sessionSamples),
      bpm: _bpm,
      observations: _basicObservation(),
    );
  }

  Future<void> _exportPdf() async {
    final file = await const EkgExportService().exportPdf(_buildReport());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Raport PDF salvat: ${file.path}')),
    );
  }

  Future<void> _exportRaw() async {
    final file = await const EkgExportService().exportRawCsv(_buildReport());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Date brute salvate: ${file.path}')),
    );
  }

  String _basicObservation() {
    if (_bpm == null) return 'Semnal insuficient pentru calcul BPM.';
    if (_bpm! < 50) return 'Ritm lent; verificare recomandata daca apar simptome.';
    if (_bpm! > 120) return 'Ritm rapid; monitorizare recomandata.';
    return 'Ritm in limite uzuale pentru screening basic.';
  }

  List<FlSpot> _buildChartSpots() {
    if (_valid == 0) return const [];

    final visibleSeconds = _speedMmPerSec == 50 ? 4.0 : 8.0;
    final visibleSamples = (visibleSeconds * widget.sampleRateHz)
        .clamp(100, _buffer.length)
        .toInt();
    final mvScale = _gainMmPerMv / 10.0;

    int startIndex = _writeIndex - visibleSamples;
    while (startIndex < 0) {
      startIndex += _buffer.length;
    }

    final spots = <FlSpot>[];
    for (int i = 0; i < visibleSamples; i++) {
      final idx = (startIndex + i) % _buffer.length;
      final seconds = i / widget.sampleRateHz;
      spots.add(FlSpot(seconds, _buffer[idx] * mvScale));
    }
    return spots;
  }

  (double, double) _chartRange(List<FlSpot> spots) {
    if (spots.isEmpty) return (-2.5, 2.5);
    var minY = spots.first.y;
    var maxY = spots.first.y;
    for (final spot in spots.skip(1)) {
      if (spot.y < minY) minY = spot.y;
      if (spot.y > maxY) maxY = spot.y;
    }
    final padding = math.max(0.6, (maxY - minY) * 0.2);
    return (minY - padding, maxY + padding);
  }
}

/// Box de status (responsive, compact)
class _StatusBox extends StatelessWidget {
  const _StatusBox({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outline.withOpacity(0.2)),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.shadow.withOpacity(0.04),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

/// Pictor EKG: grilă + trasătură
class _EcgPainter extends CustomPainter {
  _EcgPainter({
    required this.samples,
    required this.valid,
    required this.writeIndex,
    required this.sampleRate,
    required this.speedMmPerSec,
    required this.gainMmPerMv,
    required this.traceColor,
    required this.gridDark,
  });

  final List<double> samples;
  final int valid;
  final int writeIndex;
  final int sampleRate;
  final int speedMmPerSec;
  final int gainMmPerMv;
  final Color traceColor;
  final bool gridDark;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()
      ..color = (gridDark ? const Color(0xFF0F0F0F) : const Color(0xFFFDF9F9));
    canvas.drawRect(Offset.zero & size, bg);

    final small = Paint()
      ..color = (gridDark ? Colors.white10 : Colors.black12)
      ..strokeWidth = 1;
    final big = Paint()
      ..color = (gridDark ? Colors.white24 : Colors.black26)
      ..strokeWidth = 1.2;

    const smallCountPerBig = 5;
    const smallSize = 12.0;
    final cols = (size.width / smallSize).ceil();
    final rows = (size.height / smallSize).ceil();

    for (var c = 0; c <= cols; c++) {
      final x = c * smallSize;
      final isBig = c % smallCountPerBig == 0;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), isBig ? big : small);
    }
    for (var r = 0; r <= rows; r++) {
      final y = r * smallSize;
      final isBig = r % smallCountPerBig == 0;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), isBig ? big : small);
    }

    if (valid == 0) return;

    final visibleSeconds = speedMmPerSec == 50 ? 4.0 : 8.0;
    final visibleSamples = (visibleSeconds * sampleRate).clamp(100, samples.length).toInt();

    final path = Path();
    final midY = size.height / 2;
    final pxPerMv = gainMmPerMv * (smallSize / 5.0);
    final xStep = size.width / (visibleSamples - 1);

    int startIndex = (writeIndex - visibleSamples);
    while (startIndex < 0) {
      startIndex += samples.length;
    }

    for (int i = 0; i < visibleSamples; i++) {
      final idx = (startIndex + i) % samples.length;
      final mv = samples[idx];
      final y = midY - (mv * pxPerMv);
      final x = i * xStep;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    final trace = Paint()
      ..color = traceColor
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawPath(path, trace);
  }

  @override
  bool shouldRepaint(covariant _EcgPainter old) {
    return old.writeIndex != writeIndex ||
        old.speedMmPerSec != speedMmPerSec ||
        old.gainMmPerMv != gainMmPerMv ||
        old.traceColor != traceColor ||
        old.gridDark != gridDark;
  }
}

/// Rând setare cu icon + titlu + trailing
class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.icon,
    required this.title,
    required this.trailing,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final Widget trailing;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 20, color: theme.colorScheme.onPrimaryContainer),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              if (subtitle != null)
                Text(
                  subtitle!,
                  style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withOpacity(0.65),
                      ),
                ),
            ],
          ),
        ),
        trailing,
      ],
    );
  }
}

/// Body safe (compatibil MIUI/gestures/tastatură)
class _SafeScrollableBody extends StatelessWidget {
  const _SafeScrollableBody({
    required this.child,
    this.horizontal = 16,
    this.top = 16,
    this.bottomExtra = 16,
  });

  final Widget child;
  final double horizontal;
  final double top;
  final double bottomExtra;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final keyboard = mq.viewInsets.bottom;
    final bool safeZero = mq.padding.bottom == 0.0;
    final gestureFallback = safeZero ? mq.systemGestureInsets.bottom : 0.0;
    final bottomPad = gestureFallback + keyboard + bottomExtra;

    return SafeArea(
      top: true,
      bottom: true,
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        padding: EdgeInsets.fromLTRB(horizontal, top, horizontal, bottomPad),
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: child,
        ),
      ),
    );
  }
}
