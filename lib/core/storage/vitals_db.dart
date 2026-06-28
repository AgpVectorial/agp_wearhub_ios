import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/metric.dart';

/// Tipuri de semnal vital stocate în DB (compatibilitate cu codul vechi)
enum VitalType { hr, spo2, temp, steps, battery, bp, hrv, stress }

/// O înregistrare din istoric (compatibilitate cu codul vechi)
class VitalRecord {
  final int? id;
  final String deviceId;
  final VitalType type;
  final double value;
  final DateTime ts;
  final String userId;

  const VitalRecord({
    this.id,
    required this.deviceId,
    required this.type,
    required this.value,
    required this.ts,
    this.userId = 'default',
  });

  Map<String, dynamic> toMap() => {
    'deviceId': deviceId,
    'type': type.name,
    'value': value,
    'ts': ts.millisecondsSinceEpoch,
    'userId': userId,
    'source': 'ble',
  };

  factory VitalRecord.fromMap(Map<String, dynamic> m) => VitalRecord(
    id: m['id'] as int?,
    deviceId: m['deviceId'] as String,
    type: VitalType.values.firstWhere((e) => e.name == m['type']),
    value: (m['value'] as num).toDouble(),
    ts: DateTime.fromMillisecondsSinceEpoch(m['ts'] as int),
    userId: (m['userId'] as String?) ?? 'default',
  );
}

/// Baza de date SQLite pentru istoricul semnalelor vitale.
///
/// v2: adaugă coloanele userId și source pentru multi-user și unified metrics.
class VitalsDatabase {
  static const _dbName = 'vitals_history.db';
  static const _table = 'vital_samples';
  static const _version = 2; // Migrat de la v1

  Database? _db;
  static VitalsDatabase? _instance;

  VitalsDatabase._();
  factory VitalsDatabase() => _instance ??= VitalsDatabase._();

  Future<Database> get database async {
    if (_db != null) return _db!;
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, _dbName);
    _db = await openDatabase(
      path,
      version: _version,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_table (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            userId TEXT NOT NULL DEFAULT 'default',
            deviceId TEXT NOT NULL,
            type TEXT NOT NULL,
            value REAL NOT NULL,
            ts INTEGER NOT NULL,
            source TEXT NOT NULL DEFAULT 'ble'
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_user_device_type_ts ON $_table (userId, deviceId, type, ts)',
        );
        await db.execute(
          'CREATE INDEX idx_device_type_ts ON $_table (deviceId, type, ts)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          // Migrare v1 → v2: adaugă coloanele userId și source
          await db.execute(
            "ALTER TABLE $_table ADD COLUMN userId TEXT NOT NULL DEFAULT 'default'",
          );
          await db.execute(
            "ALTER TABLE $_table ADD COLUMN source TEXT NOT NULL DEFAULT 'ble'",
          );
          await db.execute(
            'CREATE INDEX idx_user_device_type_ts ON $_table (userId, deviceId, type, ts)',
          );
          debugPrint('[VitalsDB] Migrated v1 → v2 (added userId, source)');
        }
      },
    );
    return _db!;
  }

  /// Inserează un sample.
  Future<void> insert(VitalRecord rec) async {
    final db = await database;
    await db.insert(_table, rec.toMap());
  }

  /// Inserează un batch de sample-uri (mai eficient).
  Future<void> insertBatch(List<VitalRecord> records) async {
    if (records.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final rec in records) {
      batch.insert(_table, rec.toMap());
    }
    await batch.commit(noResult: true);
  }

  /// Returnează sample-urile pentru un device + tip, în intervalul temporal.
  Future<List<VitalRecord>> query({
    required String deviceId,
    required VitalType type,
    String? userId,
    DateTime? from,
    DateTime? to,
    int? limit,
  }) async {
    final db = await database;
    final where = StringBuffer('deviceId = ? AND type = ?');
    final args = <dynamic>[deviceId, type.name];

    if (userId != null) {
      where.write(' AND userId = ?');
      args.add(userId);
    }

    if (from != null) {
      where.write(' AND ts >= ?');
      args.add(from.millisecondsSinceEpoch);
    }
    if (to != null) {
      where.write(' AND ts <= ?');
      args.add(to.millisecondsSinceEpoch);
    }

    final rows = await db.query(
      _table,
      where: where.toString(),
      whereArgs: args,
      orderBy: 'ts ASC',
      limit: limit,
    );
    return rows.map(VitalRecord.fromMap).toList();
  }

  /// Ultimele N sample-uri (cele mai recente).
  Future<List<VitalRecord>> latest({
    required String deviceId,
    required VitalType type,
    String? userId,
    int count = 100,
  }) async {
    final db = await database;
    final where = StringBuffer('deviceId = ? AND type = ?');
    final args = <dynamic>[deviceId, type.name];

    if (userId != null) {
      where.write(' AND userId = ?');
      args.add(userId);
    }

    final rows = await db.query(
      _table,
      where: where.toString(),
      whereArgs: args,
      orderBy: 'ts DESC',
      limit: count,
    );
    return rows.map(VitalRecord.fromMap).toList().reversed.toList();
  }

  /// Șterge sample-uri mai vechi de [days] zile.
  Future<int> pruneOlderThan(int days) async {
    final db = await database;
    final cutoff = DateTime.now()
        .subtract(Duration(days: days))
        .millisecondsSinceEpoch;
    return db.delete(_table, where: 'ts < ?', whereArgs: [cutoff]);
  }

  /// Numărul total de sample-uri pentru un device + tip.
  Future<int> count({required String deviceId, required VitalType type}) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as cnt FROM $_table WHERE deviceId = ? AND type = ?',
      [deviceId, type.name],
    );
    return (result.first['cnt'] as int?) ?? 0;
  }

  // ─────────────────────────────────────────────
  //  Metode pentru modelul unificat Metric
  // ─────────────────────────────────────────────

  /// Inserează un [Metric] unificat.
  Future<void> insertMetric(Metric metric) async {
    final db = await database;
    await db.insert(_table, metric.toMap());
  }

  /// Inserează un batch de [Metric]-uri.
  Future<void> insertMetricBatch(List<Metric> metrics) async {
    if (metrics.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final m in metrics) {
      batch.insert(_table, m.toMap());
    }
    await batch.commit(noResult: true);
  }

  /// Query metrici unificate, filtrate pe utilizator.
  Future<List<Metric>> queryMetrics({
    required String userId,
    required String deviceId,
    required MetricType metricType,
    DateTime? from,
    DateTime? to,
    int? limit,
  }) async {
    final db = await database;
    final where = StringBuffer('userId = ? AND deviceId = ? AND type = ?');
    final args = <dynamic>[userId, deviceId, metricType.dbName];

    if (from != null) {
      where.write(' AND ts >= ?');
      args.add(from.toUtc().millisecondsSinceEpoch);
    }
    if (to != null) {
      where.write(' AND ts <= ?');
      args.add(to.toUtc().millisecondsSinceEpoch);
    }

    final rows = await db.query(
      _table,
      where: where.toString(),
      whereArgs: args,
      orderBy: 'ts ASC',
      limit: limit,
    );
    return rows.map(Metric.fromMap).toList();
  }

  /// Ultimele N metrici unificate.
  Future<List<Metric>> latestMetrics({
    required String userId,
    required String deviceId,
    required MetricType metricType,
    int count = 100,
  }) async {
    final db = await database;
    final rows = await db.query(
      _table,
      where: 'userId = ? AND deviceId = ? AND type = ?',
      whereArgs: [userId, deviceId, metricType.dbName],
      orderBy: 'ts DESC',
      limit: count,
    );
    return rows.map(Metric.fromMap).toList().reversed.toList();
  }

  /// Șterge datele unui utilizator specific.
  Future<int> deleteUserData(String userId) async {
    final db = await database;
    return db.delete(_table, where: 'userId = ?', whereArgs: [userId]);
  }

  /// Numărul de metrici per utilizator.
  Future<int> countForUser(String userId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as cnt FROM $_table WHERE userId = ?',
      [userId],
    );
    return (result.first['cnt'] as int?) ?? 0;
  }
}

/// Provider global pentru baza de date.
final vitalsDbProvider = Provider<VitalsDatabase>((_) => VitalsDatabase());
