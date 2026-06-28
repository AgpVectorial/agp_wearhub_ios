class WearDevice {
  final String id;
  final String name;
  final int? rssi;

  const WearDevice({required this.id, required this.name, this.rssi});

  factory WearDevice.fromMap(Map<String, dynamic> m) => WearDevice(
    id: m['id'] as String,
    name: (m['name'] as String?) ?? 'Unknown',
    rssi: m['rssi'] is int ? m['rssi'] as int : null,
  );

  Map<String, dynamic> toMap() => {'id': id, 'name': name, 'rssi': rssi};
}

class WearMetrics {
  final int heartRate; // bpm
  final int steps; // count
  final int battery; // %
  final int? spo2; // % (0..100)
  final int? calories; // kcal (aprox / depinde de device)

  WearMetrics({
    required this.heartRate,
    required this.steps,
    required this.battery,
    this.spo2,
    this.calories,
  });

  factory WearMetrics.fromMap(Map<String, dynamic> m) => WearMetrics(
    heartRate: (m['heartRate'] as num?)?.toInt() ?? 0,
    steps: (m['steps'] as num?)?.toInt() ?? 0,
    battery: (m['battery'] as num?)?.toInt() ?? 0,
    spo2: (m['spo2'] as num?)?.toInt(),
    calories: (m['calories'] as num?)?.toInt(),
  );

  Map<String, dynamic> toMap() => {
    'heartRate': heartRate,
    'steps': steps,
    'battery': battery,
    if (spo2 != null) 'spo2': spo2,
    if (calories != null) 'calories': calories,
  };
}
