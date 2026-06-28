import 'dart:math' as math;

import '../models/user_profile.dart';

enum BmiCategory { underweight, normal, overweight, obese }

enum ActivityLevel { sedentary, moderate, active }

enum HeartRateZone { resting, fatBurn, cardio, peak }

class BmiResult {
  final double value;
  final BmiCategory category;
  final String recommendation;

  const BmiResult({
    required this.value,
    required this.category,
    required this.recommendation,
  });

  String get label => switch (category) {
        BmiCategory.underweight => 'Subponderal',
        BmiCategory.normal => 'Normal',
        BmiCategory.overweight => 'Supraponderal',
        BmiCategory.obese => 'Obezitate',
      };
}

class HeartRateZoneRange {
  final HeartRateZone zone;
  final int min;
  final int max;

  const HeartRateZoneRange({
    required this.zone,
    required this.min,
    required this.max,
  });

  String get label => switch (zone) {
        HeartRateZone.resting => 'Resting',
        HeartRateZone.fatBurn => 'Fat burn',
        HeartRateZone.cardio => 'Cardio',
        HeartRateZone.peak => 'Peak',
      };
}

class HealthProfileMetrics {
  final int bpmMax;
  final BmiResult? bmi;
  final List<HeartRateZoneRange> zones;

  const HealthProfileMetrics({
    required this.bpmMax,
    required this.bmi,
    required this.zones,
  });

  HeartRateZoneRange? zoneFor(int bpm) {
    for (final zone in zones) {
      if (bpm >= zone.min && bpm <= zone.max) return zone;
    }
    return bpm > zones.last.max ? zones.last : zones.first;
  }
}

class HealthProfileService {
  const HealthProfileService();

  HealthProfileMetrics fromUser(
    UserProfile? user, {
    ActivityLevel activityLevel = ActivityLevel.sedentary,
  }) {
    final age = (user?.age ?? 35).clamp(10, 100).toInt();
    final bpmMax = math.max(80, 220 - age);
    return HealthProfileMetrics(
      bpmMax: bpmMax,
      bmi: calculateBmi(
        weightKg: user?.weightKg,
        heightCm: user?.heightCm,
      ),
      zones: heartRateZones(bpmMax, activityLevel),
    );
  }

  BmiResult? calculateBmi({double? weightKg, double? heightCm}) {
    if (weightKg == null || heightCm == null || weightKg <= 0 || heightCm <= 0) {
      return null;
    }
    final meters = heightCm / 100.0;
    final value = weightKg / (meters * meters);
    final category = value < 18.5
        ? BmiCategory.underweight
        : value < 25
            ? BmiCategory.normal
            : value < 30
                ? BmiCategory.overweight
                : BmiCategory.obese;
    return BmiResult(
      value: (value * 10).roundToDouble() / 10.0,
      category: category,
      recommendation: _recommendation(category),
    );
  }

  List<HeartRateZoneRange> heartRateZones(
    int bpmMax,
    ActivityLevel activityLevel,
  ) {
    final modifier = switch (activityLevel) {
      ActivityLevel.sedentary => -3,
      ActivityLevel.moderate => 0,
      ActivityLevel.active => 3,
    };
    int pct(double value) => (bpmMax * value).round() + modifier;
    return [
      HeartRateZoneRange(zone: HeartRateZone.resting, min: 35, max: pct(0.50)),
      HeartRateZoneRange(
        zone: HeartRateZone.fatBurn,
        min: pct(0.50) + 1,
        max: pct(0.70),
      ),
      HeartRateZoneRange(
        zone: HeartRateZone.cardio,
        min: pct(0.70) + 1,
        max: pct(0.85),
      ),
      HeartRateZoneRange(
        zone: HeartRateZone.peak,
        min: pct(0.85) + 1,
        max: bpmMax,
      ),
    ];
  }

  String _recommendation(BmiCategory category) => switch (category) {
        BmiCategory.underweight =>
          'Creste aportul caloric gradual si monitorizeaza evolutia saptamanal.',
        BmiCategory.normal =>
          'Mentine rutina actuala si verifica periodic greutatea si vitalele.',
        BmiCategory.overweight =>
          'Prioritizeaza miscare moderata si un deficit caloric usor.',
        BmiCategory.obese =>
          'Discuta cu un medic pentru un plan personalizat si monitorizare regulata.',
      };
}
