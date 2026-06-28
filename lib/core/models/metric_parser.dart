import 'metric.dart';

/// Parsare și normalizare a datelor brute din SDK / BLE în [Metric].
class MetricParser {
  const MetricParser._();

  /// Parsează un Heart Rate Measurement BLE (0x2A37) conform Bluetooth SIG.
  static Metric? parseHeartRate({
    required List<int> raw,
    required String deviceId,
    required String userId,
    MetricSource source = MetricSource.ble,
  }) {
    if (raw.isEmpty) return null;
    final flags = raw[0];
    final hr8bit = (flags & 0x01) == 0;
    int? hr;
    if (hr8bit && raw.length > 1) {
      hr = raw[1];
    } else if (!hr8bit && raw.length > 2) {
      hr = raw[1] | (raw[2] << 8);
    }
    if (hr == null || hr <= 0) return null;
    return Metric(
      userId: userId,
      deviceId: deviceId,
      type: MetricType.heartRate,
      value: hr.toDouble(),
      timestamp: DateTime.now().toUtc(),
      source: source,
      rawData: {'raw': raw},
    );
  }

  /// Parsează Energy Expended din HR Measurement (bit 3 flags).
  static Metric? parseCaloriesFromHr({
    required List<int> raw,
    required String deviceId,
    required String userId,
    MetricSource source = MetricSource.ble,
  }) {
    if (raw.isEmpty) return null;
    final flags = raw[0];
    final energyPresent = (flags & 0x08) != 0;
    if (!energyPresent) return null;
    final hr8 = (flags & 0x01) == 0;
    final offset = 1 + (hr8 ? 1 : 2);
    if (raw.length < offset + 2) return null;
    final energyKJ = raw[offset] | (raw[offset + 1] << 8);
    final kcal = (energyKJ * 0.239006).roundToDouble();
    return Metric(
      userId: userId,
      deviceId: deviceId,
      type: MetricType.calories,
      value: kcal,
      timestamp: DateTime.now().toUtc(),
      source: source,
      rawData: {'raw': raw, 'energyKJ': energyKJ},
    );
  }

  /// Parsează SpO2 – primul octet, validat între 50-100%.
  static Metric? parseSpo2({
    required List<int> raw,
    required String deviceId,
    required String userId,
    MetricSource source = MetricSource.ble,
  }) {
    if (raw.isEmpty) return null;
    final x = raw.first;
    if (x < 50 || x > 100) return null;
    return Metric(
      userId: userId,
      deviceId: deviceId,
      type: MetricType.spo2,
      value: x.toDouble(),
      timestamp: DateTime.now().toUtc(),
      source: source,
      rawData: {'raw': raw},
    );
  }

  /// Parsează pași – uint16 sau uint32 LE.
  static Metric? parseSteps({
    required List<int> raw,
    required String deviceId,
    required String userId,
    MetricSource source = MetricSource.ble,
  }) {
    if (raw.isEmpty) return null;
    int steps;
    if (raw.length >= 4) {
      steps = raw[0] | (raw[1] << 8) | (raw[2] << 16) | (raw[3] << 24);
    } else if (raw.length >= 2) {
      steps = raw[0] | (raw[1] << 8);
    } else {
      steps = raw[0];
    }
    if (steps < 0) return null;
    return Metric(
      userId: userId,
      deviceId: deviceId,
      type: MetricType.steps,
      value: steps.toDouble(),
      timestamp: DateTime.now().toUtc(),
      source: source,
      rawData: {'raw': raw},
    );
  }

  /// Parsează baterie – un octet, clamped 0-100.
  static Metric? parseBattery({
    required List<int> raw,
    required String deviceId,
    required String userId,
    MetricSource source = MetricSource.ble,
  }) {
    if (raw.isEmpty) return null;
    final b = raw.first.clamp(0, 100);
    return Metric(
      userId: userId,
      deviceId: deviceId,
      type: MetricType.battery,
      value: b.toDouble(),
      timestamp: DateTime.now().toUtc(),
      source: source,
      rawData: {'raw': raw},
    );
  }

  /// Parsează temperatură în °C.
  /// Acceptă valori Fahrenheit (>45) și le convertește automat.
  static Metric? parseTemperature({
    required double rawValue,
    required String deviceId,
    required String userId,
    MetricSource source = MetricSource.ble,
  }) {
    double celsius = rawValue;
    // Auto-detect Fahrenheit (nicio temperatură corporală reală > 45°C)
    if (rawValue > 45.0 && rawValue < 115.0) {
      celsius = (rawValue - 32.0) * 5.0 / 9.0;
    }
    if (celsius < 30.0 || celsius > 45.0) return null;
    return Metric(
      userId: userId,
      deviceId: deviceId,
      type: MetricType.temperature,
      value: double.parse(celsius.toStringAsFixed(1)),
      timestamp: DateTime.now().toUtc(),
      source: source,
      rawData: {'rawValue': rawValue, 'convertedCelsius': celsius},
    );
  }

  /// Parsează date generice de la SDK-ul producătorului (Map<String, dynamic>).
  static List<Metric> parseFromSdkMap({
    required Map<String, dynamic> sdkData,
    required String deviceId,
    required String userId,
  }) {
    final now = DateTime.now().toUtc();
    final metrics = <Metric>[];

    void add(MetricType type, dynamic val) {
      if (val == null) return;
      final v = (val is num) ? val.toDouble() : double.tryParse('$val');
      if (v == null) return;
      final m = Metric(
        userId: userId,
        deviceId: deviceId,
        type: type,
        value: v,
        timestamp: now,
        source: MetricSource.sdk,
        rawData: sdkData,
      );
      if (m.isValid) metrics.add(m);
    }

    add(
      MetricType.heartRate,
      sdkData['heartRate'] ?? sdkData['hr'] ?? sdkData['heart_rate'],
    );
    add(
      MetricType.spo2,
      sdkData['spo2'] ?? sdkData['oxygen'] ?? sdkData['bloodOxygen'],
    );
    add(MetricType.steps, sdkData['steps'] ?? sdkData['step_count']);
    add(MetricType.battery, sdkData['battery'] ?? sdkData['batteryLevel']);
    add(MetricType.calories, sdkData['calories'] ?? sdkData['kcal']);
    add(
      MetricType.respiration,
      sdkData['respiration'] ?? sdkData['breathRate'],
    );
    add(MetricType.hrv, sdkData['hrv'] ?? sdkData['heartRateVariability']);

    // Temperatură cu normalizare
    final tempVal =
        sdkData['temperature'] ?? sdkData['temp'] ?? sdkData['bodyTemp'];
    if (tempVal != null) {
      final tv = (tempVal is num)
          ? tempVal.toDouble()
          : double.tryParse('$tempVal');
      if (tv != null) {
        final m = parseTemperature(
          rawValue: tv,
          deviceId: deviceId,
          userId: userId,
          source: MetricSource.sdk,
        );
        if (m != null) metrics.add(m);
      }
    }

    // Blood Pressure
    final sys = sdkData['systolic'] ?? sdkData['bp_systolic'];
    final dia = sdkData['diastolic'] ?? sdkData['bp_diastolic'];
    if (sys != null) add(MetricType.bloodPressureSystolic, sys);
    if (dia != null) add(MetricType.bloodPressureDiastolic, dia);

    return metrics;
  }

  /// Normalizare finală: clamping + rotunjire dacă e cazul.
  static Metric normalize(Metric m) {
    final range = m.type.validRange;
    final clamped = m.value.clamp(range.min, range.max);
    return m.copyWith(value: clamped);
  }
}
