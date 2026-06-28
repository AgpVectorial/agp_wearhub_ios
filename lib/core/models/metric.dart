import 'package:flutter/foundation.dart';

/// Sursa datelor de metrici.
enum MetricSource { ble, sdk, mock }

/// Tipuri extinse de metrici – superset al VitalType vechi.
enum MetricType {
  heartRate,
  spo2,
  temperature,
  steps,
  battery,
  respiration,
  hrv,
  bloodPressureSystolic,
  bloodPressureDiastolic,
  calories,
  stress,
}

extension MetricTypeInfo on MetricType {
  /// Unitatea de măsură standard.
  String get unit => switch (this) {
    MetricType.heartRate => 'bpm',
    MetricType.spo2 => '%',
    MetricType.temperature => '°C',
    MetricType.steps => 'steps',
    MetricType.battery => '%',
    MetricType.respiration => 'rpm',
    MetricType.hrv => 'ms',
    MetricType.bloodPressureSystolic => 'mmHg',
    MetricType.bloodPressureDiastolic => 'mmHg',
    MetricType.calories => 'kcal',
    MetricType.stress => '',
  };

  /// Intervalul valid pentru valori.
  ({double min, double max}) get validRange => switch (this) {
    MetricType.heartRate => (min: 20, max: 250),
    MetricType.spo2 => (min: 50, max: 100),
    MetricType.temperature => (min: 30.0, max: 45.0),
    MetricType.steps => (min: 0, max: 200000),
    MetricType.battery => (min: 0, max: 100),
    MetricType.respiration => (min: 4, max: 60),
    MetricType.hrv => (min: 0, max: 500),
    MetricType.bloodPressureSystolic => (min: 60, max: 260),
    MetricType.bloodPressureDiastolic => (min: 30, max: 160),
    MetricType.calories => (min: 0, max: 99999),
    MetricType.stress => (min: 0, max: 100),
  };

  /// Nume scurt pentru DB (compatibil cu VitalType vechi).
  String get dbName => switch (this) {
    MetricType.heartRate => 'hr',
    MetricType.spo2 => 'spo2',
    MetricType.temperature => 'temp',
    MetricType.steps => 'steps',
    MetricType.battery => 'battery',
    MetricType.respiration => 'resp',
    MetricType.hrv => 'hrv',
    MetricType.bloodPressureSystolic => 'bp_sys',
    MetricType.bloodPressureDiastolic => 'bp_dia',
    MetricType.calories => 'calories',
    MetricType.stress => 'stress',
  };

  static MetricType fromDbName(String name) => switch (name) {
    'hr' => MetricType.heartRate,
    'spo2' => MetricType.spo2,
    'temp' => MetricType.temperature,
    'steps' => MetricType.steps,
    'battery' => MetricType.battery,
    'resp' => MetricType.respiration,
    'hrv' => MetricType.hrv,
    'bp_sys' => MetricType.bloodPressureSystolic,
    'bp_dia' => MetricType.bloodPressureDiastolic,
    'calories' => MetricType.calories,
    'stress' => MetricType.stress,
    _ => MetricType.heartRate,
  };
}

/// Model unificat pentru orice metrică de sănătate.
///
/// Toate valorile sunt normalizate la [double] și stocate cu timestamp UTC.
@immutable
class Metric {
  final int? id;
  final String userId;
  final String deviceId;
  final MetricType type;
  final double value;
  final DateTime timestamp; // always UTC
  final MetricSource source;
  final Map<String, dynamic>? rawData;

  const Metric({
    this.id,
    required this.userId,
    required this.deviceId,
    required this.type,
    required this.value,
    required this.timestamp,
    this.source = MetricSource.ble,
    this.rawData,
  });

  /// Unitatea standard pentru acest tip de metrică.
  String get unit => type.unit;

  /// Validare: valoarea e în intervalul acceptabil.
  bool get isValid {
    final range = type.validRange;
    return value >= range.min && value <= range.max;
  }

  /// Creează o copie cu câmpuri modificate.
  Metric copyWith({
    int? id,
    String? userId,
    String? deviceId,
    MetricType? type,
    double? value,
    DateTime? timestamp,
    MetricSource? source,
    Map<String, dynamic>? rawData,
  }) => Metric(
    id: id ?? this.id,
    userId: userId ?? this.userId,
    deviceId: deviceId ?? this.deviceId,
    type: type ?? this.type,
    value: value ?? this.value,
    timestamp: timestamp ?? this.timestamp,
    source: source ?? this.source,
    rawData: rawData ?? this.rawData,
  );

  /// Serializare pentru SQLite.
  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'userId': userId,
    'deviceId': deviceId,
    'type': type.dbName,
    'value': value,
    'ts': timestamp.toUtc().millisecondsSinceEpoch,
    'source': source.name,
  };

  /// Deserializare din SQLite.
  factory Metric.fromMap(Map<String, dynamic> m) => Metric(
    id: m['id'] as int?,
    userId: (m['userId'] as String?) ?? 'default',
    deviceId: m['deviceId'] as String,
    type: MetricTypeInfo.fromDbName(m['type'] as String),
    value: (m['value'] as num).toDouble(),
    timestamp: DateTime.fromMillisecondsSinceEpoch(m['ts'] as int, isUtc: true),
    source: MetricSource.values.firstWhere(
      (e) => e.name == (m['source'] as String?),
      orElse: () => MetricSource.ble,
    ),
  );

  @override
  String toString() =>
      'Metric(type=${type.dbName}, value=$value${type.unit}, '
      'ts=${timestamp.toIso8601String()}, device=$deviceId, user=$userId)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Metric &&
          userId == other.userId &&
          deviceId == other.deviceId &&
          type == other.type &&
          value == other.value &&
          timestamp == other.timestamp;

  @override
  int get hashCode => Object.hash(userId, deviceId, type, value, timestamp);
}
