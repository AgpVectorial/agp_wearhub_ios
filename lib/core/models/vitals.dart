import 'package:flutter/foundation.dart';

@immutable
class VitalSample<T> {
  final String deviceId;
  final T value;
  final DateTime ts;
  const VitalSample({required this.deviceId, required this.value, required this.ts});
}

@immutable
class BloodPressure {
  final int systolic;
  final int diastolic;
  const BloodPressure(this.systolic, this.diastolic);
  @override
  String toString() => '$systolic/$diastolic';
}