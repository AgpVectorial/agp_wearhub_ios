import 'dart:collection';
import 'dart:math' as math;

import '../models/metric.dart';

class ProcessedMetric {
  final Metric metric;
  final bool accepted;
  final bool reconfirming;
  final String? reason;

  const ProcessedMetric.accepted(this.metric)
    : accepted = true,
      reconfirming = false,
      reason = null;

  const ProcessedMetric.reconfirming(this.metric, this.reason)
    : accepted = false,
      reconfirming = true;

  const ProcessedMetric.rejected(this.metric, this.reason)
    : accepted = false,
      reconfirming = false;
}

class MetricProcessingRule {
  final double min;
  final double max;
  final double maxDelta;
  final double smoothingAlpha;
  final Duration minInterval;
  final int averageWindow;
  final bool monotonic;

  const MetricProcessingRule({
    required this.min,
    required this.max,
    required this.maxDelta,
    this.smoothingAlpha = 0.35,
    this.minInterval = const Duration(milliseconds: 900),
    this.averageWindow = 5,
    this.monotonic = false,
  });
}

class _MetricState {
  final Queue<double> window = Queue<double>();
  DateTime? lastAcceptedAt;
  double? lastAccepted;
  Metric? pendingSpike;
}

/// Centralizeaza filtrarea datelor venite din BLE/SDK:
/// range validation, throttle, moving average, EMA smoothing si spike confirmation.
class VitalSignalProcessor {
  final Map<MetricType, MetricProcessingRule> rules;
  final Map<MetricType, _MetricState> _state = {};

  VitalSignalProcessor({Map<MetricType, MetricProcessingRule>? rules})
    : rules = rules ?? defaultRules;

  // NOTE: smoothingAlpha=1.0 + averageWindow=1 disables EMA/moving-average so the
  // raw SDK value is displayed directly (matches the official bracelet app).
  // maxDelta is set generously because measurements are discrete (once per 15-60 s),
  // so a large legitimate change between cycles must not be rejected as a "spike".
  static const defaultRules = <MetricType, MetricProcessingRule>{
    MetricType.heartRate: MetricProcessingRule(
      min: 30,
      max: 240,
      maxDelta: 120,
      smoothingAlpha: 1.0,
      minInterval: Duration(milliseconds: 200),
      averageWindow: 1,
    ),
    MetricType.spo2: MetricProcessingRule(
      min: 70,
      max: 100,
      maxDelta: 30,
      smoothingAlpha: 1.0,
      minInterval: Duration(milliseconds: 200),
      averageWindow: 1,
    ),
    MetricType.temperature: MetricProcessingRule(
      min: 32,
      max: 43,
      maxDelta: 5.0,
      smoothingAlpha: 1.0,
      minInterval: Duration(milliseconds: 200),
      averageWindow: 1,
    ),
    MetricType.hrv: MetricProcessingRule(
      min: 5,
      max: 250,
      maxDelta: 200,
      smoothingAlpha: 1.0,
      minInterval: Duration(milliseconds: 200),
      averageWindow: 1,
    ),
    MetricType.respiration: MetricProcessingRule(
      min: 6,
      max: 45,
      maxDelta: 30,
      smoothingAlpha: 1.0,
      minInterval: Duration(milliseconds: 200),
      averageWindow: 1,
    ),
    MetricType.bloodPressureSystolic: MetricProcessingRule(
      min: 70,
      max: 240,
      maxDelta: 120,
      smoothingAlpha: 1.0,
      minInterval: Duration(milliseconds: 200),
      averageWindow: 1,
    ),
    MetricType.bloodPressureDiastolic: MetricProcessingRule(
      min: 40,
      max: 140,
      maxDelta: 80,
      smoothingAlpha: 1.0,
      minInterval: Duration(milliseconds: 200),
      averageWindow: 1,
    ),
    MetricType.battery: MetricProcessingRule(
      min: 0,
      max: 100,
      maxDelta: 35,
      smoothingAlpha: 1,
      minInterval: Duration(seconds: 20),
      averageWindow: 1,
    ),
    MetricType.steps: MetricProcessingRule(
      min: 0,
      max: 200000,
      maxDelta: 20000,
      smoothingAlpha: 1,
      minInterval: Duration(seconds: 5),
      averageWindow: 1,
      monotonic: true,
    ),
    MetricType.stress: MetricProcessingRule(
      min: 0,
      max: 100,
      maxDelta: 80,
      smoothingAlpha: 1.0,
      minInterval: Duration(milliseconds: 200),
      averageWindow: 1,
    ),
    MetricType.calories: MetricProcessingRule(
      min: 0,
      max: 99999,
      maxDelta: 5000,
      smoothingAlpha: 1,
      minInterval: Duration(seconds: 10),
      averageWindow: 1,
      monotonic: true,
    ),
  };

  ProcessedMetric process(Metric metric) {
    final rule = rules[metric.type];
    if (rule == null) return ProcessedMetric.accepted(metric);

    if (metric.value.isNaN || metric.value.isInfinite) {
      return ProcessedMetric.rejected(metric, 'invalid-number');
    }
    if (metric.value < rule.min || metric.value > rule.max) {
      return ProcessedMetric.rejected(metric, 'out-of-range');
    }

    final state = _state.putIfAbsent(metric.type, _MetricState.new);
    final lastValue = state.lastAccepted;
    final lastAt = state.lastAcceptedAt;
    if (lastAt != null) {
      final elapsed = metric.timestamp.isAfter(lastAt)
          ? metric.timestamp.difference(lastAt)
          : lastAt.difference(metric.timestamp);
      if (elapsed < rule.minInterval) {
        return ProcessedMetric.rejected(metric, 'throttled');
      }
    }

    if (rule.monotonic && lastValue != null && metric.value < lastValue) {
      return ProcessedMetric.rejected(metric, 'non-monotonic');
    }

    if (lastValue != null && (metric.value - lastValue).abs() > rule.maxDelta) {
      final pending = state.pendingSpike;
      if (pending == null ||
          (pending.value - metric.value).abs() > rule.maxDelta / 2) {
        state.pendingSpike = metric;
        return ProcessedMetric.reconfirming(metric, 'spike-reconfirm');
      }
      state.pendingSpike = null;
    } else {
      state.pendingSpike = null;
    }

    final smoothed = _smooth(state, rule, metric.value);
    final accepted = metric.copyWith(value: smoothed);
    state.lastAccepted = smoothed;
    state.lastAcceptedAt = metric.timestamp;
    return ProcessedMetric.accepted(accepted);
  }

  double _smooth(_MetricState state, MetricProcessingRule rule, double value) {
    state.window.add(value);
    while (state.window.length > rule.averageWindow) {
      state.window.removeFirst();
    }
    final avg = state.window.reduce((a, b) => a + b) / state.window.length;
    final last = state.lastAccepted;
    if (last == null || rule.smoothingAlpha >= 1) return avg;
    final ema = last + rule.smoothingAlpha * (avg - last);
    return _roundByType(ema);
  }

  double _roundByType(double value) {
    if (value.abs() >= 10) return value.roundToDouble();
    return (value * 10).roundToDouble() / 10.0;
  }

  void reset([MetricType? type]) {
    if (type == null) {
      _state.clear();
    } else {
      _state.remove(type);
    }
  }

  static double rollingAverage(Iterable<double> values, {int trim = 1}) {
    final sorted = values.where((v) => v.isFinite).toList()..sort();
    if (sorted.isEmpty) return 0;
    final drop = math.min(trim, sorted.length ~/ 4);
    final trimmed = sorted.sublist(drop, sorted.length - drop);
    return trimmed.reduce((a, b) => a + b) / trimmed.length;
  }
}
