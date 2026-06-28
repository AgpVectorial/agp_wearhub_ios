import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/metric.dart';

/// Cache-ul ultimei valori pentru fiecare tip de metrică.
///
/// Salvează/încarcă din SharedPreferences la deschiderea aplicației.
class LastMetricCache extends StateNotifier<Map<MetricType, Metric>> {
  LastMetricCache() : super({}) {
    _load();
  }

  static const _prefix = 'last_metric_';

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final loaded = <MetricType, Metric>{};

    for (final type in MetricType.values) {
      final json = p.getString('$_prefix${type.dbName}');
      if (json != null) {
        try {
          final map = jsonDecode(json) as Map<String, dynamic>;
          loaded[type] = Metric.fromMap(map);
        } catch (_) {
          // Date corupte – ignorăm
        }
      }
    }

    state = loaded;
    debugPrint('[LastMetricCache] Loaded ${loaded.length} cached metrics');
  }

  /// Actualizează ultima valoare pentru un tip de metrică.
  Future<void> update(Metric metric) async {
    state = {...state, metric.type: metric};
    final p = await SharedPreferences.getInstance();
    await p.setString(
      '$_prefix${metric.type.dbName}',
      jsonEncode(metric.toMap()),
    );
  }

  /// Actualizează mai multe metrici simultan.
  Future<void> updateMany(List<Metric> metrics) async {
    final updated = Map<MetricType, Metric>.from(state);
    final p = await SharedPreferences.getInstance();
    for (final m in metrics) {
      updated[m.type] = m;
      await p.setString('$_prefix${m.type.dbName}', jsonEncode(m.toMap()));
    }
    state = updated;
  }

  /// Obține ultima valoare cache-uită pentru un tip.
  Metric? getLastValue(MetricType type) => state[type];

  /// Șterge tot cache-ul.
  Future<void> clearAll() async {
    final p = await SharedPreferences.getInstance();
    for (final type in MetricType.values) {
      await p.remove('$_prefix${type.dbName}');
    }
    state = {};
  }
}

final lastMetricCacheProvider =
    StateNotifierProvider<LastMetricCache, Map<MetricType, Metric>>(
      (ref) => LastMetricCache(),
    );
