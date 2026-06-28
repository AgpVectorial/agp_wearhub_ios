import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/metric.dart';

/// Politici de sampling pentru fiecare tip de metrică.
@immutable
class SamplingConfig {
  final MetricType type;
  final int intervalSeconds;
  final bool enabled;

  const SamplingConfig({
    required this.type,
    required this.intervalSeconds,
    this.enabled = true,
  });

  SamplingConfig copyWith({int? intervalSeconds, bool? enabled}) =>
      SamplingConfig(
        type: type,
        intervalSeconds: intervalSeconds ?? this.intervalSeconds,
        enabled: enabled ?? this.enabled,
      );
}

/// Mod de consum baterie.
enum BatteryMode { performance, balanced, powerSaver }

/// Starea completă a politicilor de sampling.
@immutable
class SamplingPolicyState {
  final Map<MetricType, SamplingConfig> configs;
  final BatteryMode batteryMode;
  final bool adaptiveSampling; // reduce frecvența când bateria e scăzută

  const SamplingPolicyState({
    required this.configs,
    this.batteryMode = BatteryMode.balanced,
    this.adaptiveSampling = true,
  });

  SamplingPolicyState copyWith({
    Map<MetricType, SamplingConfig>? configs,
    BatteryMode? batteryMode,
    bool? adaptiveSampling,
  }) => SamplingPolicyState(
    configs: configs ?? this.configs,
    batteryMode: batteryMode ?? this.batteryMode,
    adaptiveSampling: adaptiveSampling ?? this.adaptiveSampling,
  );

  /// Intervalul efectiv (ține cont de battery mode).
  int effectiveInterval(MetricType type) {
    final base = configs[type]?.intervalSeconds ?? 5;
    return switch (batteryMode) {
      BatteryMode.performance => base,
      BatteryMode.balanced => base,
      BatteryMode.powerSaver => (base * 2).clamp(5, 120),
    };
  }
}

/// Serviciu de politici de sampling cu persistență.
class SamplingPolicyService extends StateNotifier<SamplingPolicyState> {
  SamplingPolicyService()
    : super(SamplingPolicyState(configs: _defaultConfigs())) {
    _load();
  }

  static Map<MetricType, SamplingConfig> _defaultConfigs() => {
    MetricType.heartRate: const SamplingConfig(
      type: MetricType.heartRate,
      intervalSeconds: 1,
    ),
    MetricType.spo2: const SamplingConfig(
      type: MetricType.spo2,
      intervalSeconds: 5,
    ),
    MetricType.temperature: const SamplingConfig(
      type: MetricType.temperature,
      intervalSeconds: 30,
    ),
    MetricType.steps: const SamplingConfig(
      type: MetricType.steps,
      intervalSeconds: 10,
    ),
    MetricType.battery: const SamplingConfig(
      type: MetricType.battery,
      intervalSeconds: 60,
    ),
    MetricType.respiration: const SamplingConfig(
      type: MetricType.respiration,
      intervalSeconds: 5,
    ),
    MetricType.hrv: const SamplingConfig(
      type: MetricType.hrv,
      intervalSeconds: 5,
    ),
    MetricType.bloodPressureSystolic: const SamplingConfig(
      type: MetricType.bloodPressureSystolic,
      intervalSeconds: 30,
    ),
    MetricType.bloodPressureDiastolic: const SamplingConfig(
      type: MetricType.bloodPressureDiastolic,
      intervalSeconds: 30,
    ),
    MetricType.calories: const SamplingConfig(
      type: MetricType.calories,
      intervalSeconds: 60,
    ),
  };

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final bm = p.getString('sampling.battery_mode');
    final adaptive = p.getBool('sampling.adaptive') ?? true;

    final configs = Map<MetricType, SamplingConfig>.from(state.configs);

    for (final type in MetricType.values) {
      final interval = p.getInt('sampling.${type.dbName}.interval');
      final enabled = p.getBool('sampling.${type.dbName}.enabled');
      if (interval != null || enabled != null) {
        configs[type] = configs[type]!.copyWith(
          intervalSeconds: interval,
          enabled: enabled,
        );
      }
    }

    state = SamplingPolicyState(
      configs: configs,
      batteryMode: bm != null
          ? BatteryMode.values.firstWhere(
              (e) => e.name == bm,
              orElse: () => BatteryMode.balanced,
            )
          : BatteryMode.balanced,
      adaptiveSampling: adaptive,
    );
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('sampling.battery_mode', state.batteryMode.name);
    await p.setBool('sampling.adaptive', state.adaptiveSampling);

    for (final entry in state.configs.entries) {
      await p.setInt(
        'sampling.${entry.key.dbName}.interval',
        entry.value.intervalSeconds,
      );
      await p.setBool(
        'sampling.${entry.key.dbName}.enabled',
        entry.value.enabled,
      );
    }
  }

  /// Actualizează intervalul unei metrici.
  void setInterval(MetricType type, int seconds) {
    final configs = Map<MetricType, SamplingConfig>.from(state.configs);
    configs[type] = configs[type]!.copyWith(
      intervalSeconds: seconds.clamp(1, 120),
    );
    state = state.copyWith(configs: configs);
    _save();
  }

  /// Activează/dezactivează o metrică.
  void setEnabled(MetricType type, bool enabled) {
    final configs = Map<MetricType, SamplingConfig>.from(state.configs);
    configs[type] = configs[type]!.copyWith(enabled: enabled);
    state = state.copyWith(configs: configs);
    _save();
  }

  /// Schimbă modul de consum baterie.
  void setBatteryMode(BatteryMode mode) {
    state = state.copyWith(batteryMode: mode);
    _save();
  }

  /// Toggle sampling adaptiv.
  void setAdaptiveSampling(bool enabled) {
    state = state.copyWith(adaptiveSampling: enabled);
    _save();
  }

  /// Resetare la valorile implicite.
  void resetToDefaults() {
    state = SamplingPolicyState(configs: _defaultConfigs());
    _save();
  }
}

final samplingPolicyProvider =
    StateNotifierProvider<SamplingPolicyService, SamplingPolicyState>(
      (ref) => SamplingPolicyService(),
    );
