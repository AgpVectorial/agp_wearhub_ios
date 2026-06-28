import 'dart:async';
import 'package:flutter/services.dart';

import 'models.dart';

abstract class WearSdk {
  Future<List<WearDevice>> scan();
  Future<bool> connect(String deviceId, {bool autoReconnect = true});
  Future<WearMetrics> readMetrics(String deviceId);
  Future<({bool connected, String? deviceId})> getConnectionStatus();

  Future<void> startHeartRateNotifications(String deviceId);
  Future<void> stopHeartRateNotifications(String deviceId);
  Stream<int> heartRateStream(String deviceId);

  Stream<ConnectionUpdate> connectionUpdates(String deviceId);
}

class ConnectionUpdate {
  final String deviceId;
  final bool connected;
  ConnectionUpdate(this.deviceId, this.connected);
}

class MethodChannelWearSdk implements WearSdk {
  static const MethodChannel _ch = MethodChannel('agp_sdk');
  static const EventChannel _hrEvent = EventChannel('agp_sdk/hr_stream');
  static const EventChannel _connEvent = EventChannel('agp_sdk/conn_stream');

  String? _activeHrDeviceId;
  Stream<int>? _sharedHrStream;
  StreamSubscription<dynamic>? _sharedSub;
  final Map<String, StreamController<int>> _perDeviceCtrls = {};

  Stream<dynamic>? _connStream;
  final Map<String, StreamController<ConnectionUpdate>> _connCtrls = {};

  @override
  Future<List<WearDevice>> scan() async {
    final res = await _ch.invokeMethod('scan');
    final List list = (res is List) ? res : [];
    return list
        .map((e) => WearDevice.fromMap(Map<String, dynamic>.from(e)))
        .where(_isBraceletDevice)
        .toList();
  }

  /// Filtrare: păstrează doar dispozitivele care par brățări/wearable.
  /// Exclude telefoane, TV-uri, difuzoare, laptopuri, etc.
  static bool _isBraceletDevice(WearDevice d) {
    final name = d.name.toLowerCase().trim();
    // MAC-only devices (no name) — could be bracelet
    if (name.isEmpty || name == d.id.toLowerCase()) return true;
    // Explicit wearable keywords
    const wearableHints = [
      'band', 'bracelet', 'watch', 'smart', 'fit', 'ring',
      'qc', 'qring', 'wear', 'health', 'sport', 'hr',
      'mi band', 'amazfit', 'huawei band', 'galaxy fit',
    ];
    for (final hint in wearableHints) {
      if (name.contains(hint)) return true;
    }
    // Exclude known non-wearable patterns
    const excludeHints = [
      'phone', 'iphone', 'samsung', 'galaxy s', 'galaxy a', 'galaxy note',
      'pixel', 'oneplus', 'huawei p', 'huawei mate', 'oppo', 'vivo', 'xiaomi',
      'redmi', 'poco', 'realme', 'motorola', 'nokia', 'lg', 'sony',
      'tv', 'speaker', 'soundbar', 'headphone', 'earphone', 'earbud',
      'airpod', 'buds', 'jbl', 'bose', 'laptop', 'desktop', 'printer',
      'keyboard', 'mouse', 'controller', 'gamepad',
      'tile', 'airtag', 'beacon', 'car', 'obd',
    ];
    for (final ex in excludeHints) {
      if (name.contains(ex)) return false;
    }
    // Allow through — unknown devices might be bracelets
    return true;
  }

  @override
  Future<({bool connected, String? deviceId})> getConnectionStatus() async {
    try {
      final res = await _ch.invokeMethod('getConnectionStatus');
      if (res is Map) {
        final map = Map<String, dynamic>.from(res);
        return (
          connected: map['connected'] == true,
          deviceId: map['deviceId'] as String?,
        );
      }
    } catch (_) {}
    return (connected: false, deviceId: null);
  }

  @override
  Future<bool> connect(String deviceId, {bool autoReconnect = true}) async {
    final ok = await _ch.invokeMethod('connect', {'id': deviceId});
    return ok == true;
  }

  Future<void> disconnect() async {
    await _ch.invokeMethod('disconnect');
  }

  @override
  Future<WearMetrics> readMetrics(String deviceId) async {
    final res = await _ch.invokeMethod('readMetrics', {'id': deviceId});
    final map = Map<String, dynamic>.from(res as Map);
    map.putIfAbsent('spo2', () => null);
    map.putIfAbsent('calories', () => null);
    return WearMetrics.fromMap(map);
  }

  @override
  Future<void> startHeartRateNotifications(String deviceId) async {
    _activeHrDeviceId = deviceId;
    await _ensureHrStream();
    await _ch.invokeMethod('startHeartRateNotifications', {'id': deviceId});
  }

  @override
  Future<void> stopHeartRateNotifications(String deviceId) async {
    if (_activeHrDeviceId == deviceId) _activeHrDeviceId = null;
    await _ch.invokeMethod('stopHeartRateNotifications', {'id': deviceId});
  }

  @override
  Stream<int> heartRateStream(String deviceId) {
    _perDeviceCtrls.putIfAbsent(
      deviceId,
      () => StreamController<int>.broadcast(),
    );
    _ensureHrStream();
    return _perDeviceCtrls[deviceId]!.stream;
  }

  @override
  Stream<ConnectionUpdate> connectionUpdates(String deviceId) {
    _connCtrls.putIfAbsent(
      deviceId,
      () => StreamController<ConnectionUpdate>.broadcast(),
    );
    _ensureConnStream();
    return _connCtrls[deviceId]!.stream;
  }

  Future<void> _ensureHrStream() async {
    if (_sharedHrStream != null) return;
    _sharedHrStream = _hrEvent.receiveBroadcastStream().map<int>((dynamic e) {
      if (e is int) return e;
      if (e is num) return e.toInt();
      return 0;
    });
    _sharedSub = _sharedHrStream!.listen((bpm) {
      final id = _activeHrDeviceId;
      if (id == null) return;
      _perDeviceCtrls[id]?.add(bpm);
    });
  }

  void _ensureConnStream() {
    if (_connStream != null) return;
    _connStream = _connEvent.receiveBroadcastStream();
    _connStream!.listen((dynamic event) {
      if (event is Map) {
        final id = event['deviceId'] as String?;
        final connected = event['connected'] as bool? ?? false;
        if (id != null) {
          _connCtrls[id]?.add(ConnectionUpdate(id, connected));
        }
      }
    });
  }

  void dispose() {
    _sharedSub?.cancel();
    for (final c in _perDeviceCtrls.values) {
      c.close();
    }
    _perDeviceCtrls.clear();
    _activeHrDeviceId = null;
  }
}
