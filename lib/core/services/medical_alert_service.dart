import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/metric.dart';
import 'health_profile_service.dart';

enum MedicalAlertSeverity { info, warning, critical }

class MedicalThreshold {
  final double? min;
  final double? max;
  final MedicalAlertSeverity severity;

  const MedicalThreshold({
    this.min,
    this.max,
    this.severity = MedicalAlertSeverity.warning,
  });
}

class MedicalAlert {
  final String id;
  final MetricType type;
  final double value;
  final String message;
  final MedicalAlertSeverity severity;
  final DateTime timestamp;
  final String deviceId;

  const MedicalAlert({
    required this.id,
    required this.type,
    required this.value,
    required this.message,
    required this.severity,
    required this.timestamp,
    required this.deviceId,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.dbName,
        'value': value,
        'message': message,
        'severity': severity.name,
        'timestamp': timestamp.toUtc().millisecondsSinceEpoch,
        'deviceId': deviceId,
      };

  factory MedicalAlert.fromJson(Map<String, dynamic> json) => MedicalAlert(
        id: json['id'] as String,
        type: MetricTypeInfo.fromDbName(json['type'] as String),
        value: (json['value'] as num).toDouble(),
        message: json['message'] as String,
        severity: MedicalAlertSeverity.values.firstWhere(
          (e) => e.name == json['severity'],
          orElse: () => MedicalAlertSeverity.warning,
        ),
        timestamp: DateTime.fromMillisecondsSinceEpoch(
          json['timestamp'] as int,
          isUtc: true,
        ),
        deviceId: json['deviceId'] as String,
      );
}

class MedicalAlertState {
  final List<MedicalAlert> alerts;
  final MedicalAlert? latest;

  const MedicalAlertState({this.alerts = const [], this.latest});

  MedicalAlertState copyWith({
    List<MedicalAlert>? alerts,
    MedicalAlert? latest,
  }) =>
      MedicalAlertState(
        alerts: alerts ?? this.alerts,
        latest: latest ?? this.latest,
      );
}

class MedicalAlertService extends StateNotifier<MedicalAlertState> {
  MedicalAlertService() : super(const MedicalAlertState()) {
    _load();
  }

  static const _prefsKey = 'medical.alerts.v1';
  static const _maxStoredAlerts = 200;
  static const _cooldown = Duration(minutes: 3);

  final _lastAlertAt = <String, DateTime>{};
  final _controller = StreamController<MedicalAlert>.broadcast();

  Stream<MedicalAlert> get alertStream => _controller.stream;

  Map<MetricType, MedicalThreshold> thresholds({
    HealthProfileMetrics? profile,
  }) {
    final bpmMax = profile?.bpmMax ?? 185;
    return {
      MetricType.heartRate: MedicalThreshold(
        min: 45,
        max: bpmMax.toDouble(),
        severity: MedicalAlertSeverity.critical,
      ),
      MetricType.spo2: const MedicalThreshold(
        min: 92,
        severity: MedicalAlertSeverity.critical,
      ),
      MetricType.temperature: const MedicalThreshold(
        min: 35.0,
        max: 38.2,
        severity: MedicalAlertSeverity.warning,
      ),
      MetricType.battery: const MedicalThreshold(
        min: 15,
        severity: MedicalAlertSeverity.warning,
      ),
      MetricType.bloodPressureSystolic: const MedicalThreshold(
        min: 90,
        max: 145,
        severity: MedicalAlertSeverity.warning,
      ),
      MetricType.bloodPressureDiastolic: const MedicalThreshold(
        min: 55,
        max: 95,
        severity: MedicalAlertSeverity.warning,
      ),
      MetricType.respiration: const MedicalThreshold(
        min: 8,
        max: 26,
        severity: MedicalAlertSeverity.warning,
      ),
      MetricType.hrv: const MedicalThreshold(
        min: 8,
        severity: MedicalAlertSeverity.info,
      ),
    };
  }

  Future<MedicalAlert?> evaluate(
    Metric metric, {
    HealthProfileMetrics? profile,
  }) async {
    final threshold = thresholds(profile: profile)[metric.type];
    if (threshold == null) return null;

    final low = threshold.min != null && metric.value < threshold.min!;
    final high = threshold.max != null && metric.value > threshold.max!;
    if (!low && !high) return null;

    final key = '${metric.deviceId}:${metric.type.dbName}:${low ? 'low' : 'high'}';
    final now = DateTime.now().toUtc();
    final last = _lastAlertAt[key];
    if (last != null && now.difference(last) < _cooldown) return null;
    _lastAlertAt[key] = now;

    final alert = MedicalAlert(
      id: '${now.millisecondsSinceEpoch}-$key',
      type: metric.type,
      value: metric.value,
      message: _message(metric, low: low, profile: profile),
      severity: threshold.severity,
      timestamp: now,
      deviceId: metric.deviceId,
    );
    await _emit(alert);
    return alert;
  }

  Future<void> connectionLost(String deviceId) async {
    final now = DateTime.now().toUtc();
    final key = '$deviceId:ble_connection';
    final last = _lastAlertAt[key];
    if (last != null && now.difference(last) < _cooldown) return;
    _lastAlertAt[key] = now;
    await _emit(
      MedicalAlert(
        id: '${now.millisecondsSinceEpoch}-$key',
        type: MetricType.battery,
        value: 0,
        message: 'Conexiunea BLE a fost pierduta.',
        severity: MedicalAlertSeverity.critical,
        timestamp: now,
        deviceId: deviceId,
      ),
    );
  }

  Future<void> _emit(MedicalAlert alert) async {
    final alerts = [alert, ...state.alerts];
    if (alerts.length > _maxStoredAlerts) {
      alerts.removeRange(_maxStoredAlerts, alerts.length);
    }
    state = MedicalAlertState(alerts: alerts, latest: alert);
    _controller.add(alert);
    await _save();
    await _signalUser(alert);
  }

  Future<void> _signalUser(MedicalAlert alert) async {
    try {
      if (alert.severity == MedicalAlertSeverity.critical) {
        await HapticFeedback.heavyImpact();
      } else {
        await HapticFeedback.mediumImpact();
      }
      SystemSound.play(SystemSoundType.alert);
    } catch (_) {
      SystemSound.play(SystemSoundType.alert);
    }
  }

  String _message(
    Metric metric, {
    required bool low,
    HealthProfileMetrics? profile,
  }) {
    final value = metric.value.round();
    return switch (metric.type) {
      MetricType.heartRate => low
          ? 'BPM scazut: $value bpm.'
          : 'BPM ridicat: $value bpm. Limita profilului este ${profile?.bpmMax ?? 'n/a'} bpm.',
      MetricType.spo2 => 'SpO2 scazut: $value%.',
      MetricType.temperature => low
          ? 'Temperatura scazuta: ${metric.value.toStringAsFixed(1)} C.'
          : 'Temperatura ridicata: ${metric.value.toStringAsFixed(1)} C.',
      MetricType.battery => 'Baterie scazuta: $value%.',
      MetricType.bloodPressureSystolic =>
        low ? 'Tensiune sistolica scazuta: $value mmHg.' : 'Tensiune sistolica ridicata: $value mmHg.',
      MetricType.bloodPressureDiastolic =>
        low ? 'Tensiune diastolica scazuta: $value mmHg.' : 'Tensiune diastolica ridicata: $value mmHg.',
      MetricType.respiration => low
          ? 'Respiratie scazuta: $value rpm.'
          : 'Respiratie ridicata: $value rpm.',
      MetricType.hrv => 'HRV scazut: $value ms.',
      _ => 'Valoare in afara pragului: ${metric.type.dbName}=$value.',
    };
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      final alerts = decoded
          .whereType<Map>()
          .map((e) => MedicalAlert.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      state = MedicalAlertState(alerts: alerts);
    } catch (_) {}
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(state.alerts.map((e) => e.toJson()).toList());
    await prefs.setString(_prefsKey, encoded);
  }

  @override
  void dispose() {
    _controller.close();
    super.dispose();
  }
}

final medicalAlertProvider =
    StateNotifierProvider<MedicalAlertService, MedicalAlertState>(
  (ref) => MedicalAlertService(),
);
