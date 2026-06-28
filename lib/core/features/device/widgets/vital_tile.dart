import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../models/vitals.dart';
import '../../../../theme.dart';

typedef StartFn = Future<void> Function(String deviceId);
typedef StopFn = Future<void> Function(String deviceId);

class VitalTile<T> extends ConsumerStatefulWidget {
  final String deviceId;
  final String title;
  final String unit;
  final StartFn start;
  final StopFn stop;
  final Stream<VitalSample<T>> stream;
  final String Function(T v) format;

  /// Pornește automat (ex: pe baza preferințelor salvate)
  final bool autoStart;

  /// Callback când se schimbă starea ON/OFF (pentru persistență în părinte)
  final ValueChanged<bool>? onChanged;

  const VitalTile({
    super.key,
    required this.deviceId,
    required this.title,
    required this.unit,
    required this.start,
    required this.stop,
    required this.stream,
    required this.format,
    this.autoStart = false,
    this.onChanged,
  });

  @override
  ConsumerState<VitalTile<T>> createState() => _VitalTileState<T>();
}

class _VitalTileState<T> extends ConsumerState<VitalTile<T>> {
  VitalSample<T>? _latest;
  bool _on = false;
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    if (widget.autoStart) {
      // nu așteptăm first frame; pornim direct
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _setOn(true);
      });
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _setOn(bool next) async {
    if (next == _on) return;
    if (next) {
      await widget.start(widget.deviceId);
      _sub = widget.stream.listen((e) {
        if (!mounted) return;
        setState(() => _latest = e);
      });
      setState(() => _on = true);
    } else {
      await widget.stop(widget.deviceId);
      await _sub?.cancel();
      setState(() => _on = false);
    }
    widget.onChanged?.call(_on);
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: kSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  widget.title,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: kOnSurface),
                ),
                Switch(
                  value: _on,
                  onChanged: (v) => _setOn(v),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _latest == null ? '—' : widget.format(_latest!.value),
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: kGold),
            ),
            if (widget.unit.isNotEmpty)
              Text(widget.unit, style: TextStyle(color: kOnSurface.withOpacity(0.7))),
          ],
        ),
      ),
    );
  }
}
