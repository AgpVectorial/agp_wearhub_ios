import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/vitals.dart';
import '../models/metric.dart';
import '../errors/app_error.dart';
import '../services/vital_signal_processor.dart';
import 'sdk_provider.dart';

/// Implementare reală a SdkService care comunică cu QC Wireless SDK
/// prin MethodChannel/EventChannel.
///
/// Folosește aceleași canale ca MethodChannelWearSdk ('agp_sdk') dar
/// expune interfața SdkService (cu stream-uri VitalSample) utilizată
/// de device_details_page și restul UI-ului.
class QcSdkService implements SdkService {
  // Singleton – mereu aceeași instanță, stream controllers partajate
  static final QcSdkService _instance = QcSdkService._();
  factory QcSdkService() => _instance;
  QcSdkService._() {
    _setupNativeStreams();
  }

  static const MethodChannel _ch = MethodChannel('agp_sdk');
  static const EventChannel _hrEvent = EventChannel('agp_sdk/hr_stream');
  static const EventChannel _spo2Event = EventChannel('agp_sdk/spo2_stream');
  static const EventChannel _bpEvent = EventChannel('agp_sdk/bp_stream');
  static const EventChannel _tempEvent = EventChannel('agp_sdk/temp_stream');
  static const EventChannel _hrvEvent = EventChannel('agp_sdk/hrv_stream');
  static const EventChannel _stressEvent = EventChannel(
    'agp_sdk/stress_stream',
  );
  static const EventChannel _diagEvent = EventChannel('agp_sdk/diag_stream');

  final Map<String, Map<String, StreamController<dynamic>>> _controllers = {};
  final VitalSignalProcessor _processor = VitalSignalProcessor();
  final List<StreamSubscription<dynamic>> _nativeSubs = [];
  String? _activeDeviceId;

  StreamController<VitalSample<T>> _ctrl<T>(String id, String key) {
    _controllers[id] ??= {};
    if (!_controllers[id]!.containsKey(key) ||
        (_controllers[id]![key] as StreamController).isClosed) {
      _controllers[id]![key] = StreamController<VitalSample<T>>.broadcast();
    }
    return _controllers[id]![key] as StreamController<VitalSample<T>>;
  }

  void _setupNativeStreams() {
    _listenInt(_hrEvent, 'hr', MetricType.heartRate);
    _listenInt(_spo2Event, 'spo2', MetricType.spo2);
    _listenInt(_hrvEvent, 'hrv', MetricType.hrv);
    _listenInt(_stressEvent, 'stress', MetricType.stress);
    _listenInt(
      _tempEvent,
      'temp',
      MetricType.temperature,
      transform: (value) => value > 80 ? value / 10.0 : value.toDouble(),
    );
    // Bridge native diagnostic messages into Flutter LogViewer
    _nativeSubs.add(
      _diagEvent.receiveBroadcastStream().listen((event) {
        if (event is String) debugPrint('[NATIVE] $event');
      }),
    );
    _nativeSubs.add(
      _bpEvent.receiveBroadcastStream().listen(
        (event) {
          final id = _activeDeviceId;
          if (id == null || event is! Map) return;
          final map = Map<String, dynamic>.from(event);
          final sbp = (map['systolic'] as num?)?.toDouble();
          final dbp = (map['diastolic'] as num?)?.toDouble();
          if (sbp == null || dbp == null) return;
          final s = _processMetric(id, MetricType.bloodPressureSystolic, sbp);
          final d = _processMetric(id, MetricType.bloodPressureDiastolic, dbp);
          if (s == null || d == null) return;
          _ctrl<BloodPressure>(id, 'bp').add(
            VitalSample(
              deviceId: id,
              value: BloodPressure(s.value.round(), d.value.round()),
              ts: s.timestamp,
            ),
          );
        },
        onError: (Object e, StackTrace s) {
          ErrorHandler.instance.sdkError('BP stream error', error: e, stack: s);
        },
      ),
    );
  }

  void _listenInt(
    EventChannel channel,
    String key,
    MetricType type, {
    double Function(num value)? transform,
  }) {
    _nativeSubs.add(
      channel.receiveBroadcastStream().listen(
        (event) {
          final id = _activeDeviceId;
          if (id == null) return;
          final raw = event is num ? event : num.tryParse(event.toString());
          if (raw == null) return;
          final value = transform?.call(raw) ?? raw.toDouble();
          debugPrint(
            '[SDK RAW] ${type.dbName}: nativeRaw=$raw converted=$value',
          );
          final metric = _processMetric(id, type, value);
          if (metric == null) return;
          debugPrint('[SDK EMIT] ${type.dbName}: displayed=${metric.value}');
          _emitMetric(key, metric);
        },
        onError: (Object e, StackTrace s) {
          ErrorHandler.instance.sdkError(
            '${type.dbName} stream error',
            error: e,
            stack: s,
          );
        },
      ),
    );
  }

  Metric? _processMetric(String deviceId, MetricType type, double value) {
    final processed = _processor.process(
      Metric(
        userId: 'stream',
        deviceId: deviceId,
        type: type,
        value: value,
        timestamp: DateTime.now().toUtc(),
        source: MetricSource.sdk,
      ),
    );
    if (!processed.accepted) {
      debugPrint(
        '[SDK FILTERED] ${type.dbName}: value=$value REJECTED reason=${processed.reason}'
        '${processed.reconfirming ? " (awaiting confirmation)" : ""}',
      );
      if (!processed.reconfirming) {
        ErrorHandler.instance.invalidData(
          '${type.dbName} rejected: ${processed.reason} value=$value',
          deviceId: deviceId,
        );
      }
      return null;
    }
    debugPrint(
      '[SDK PROCESS] ${type.dbName}: raw=$value → accepted=${processed.metric.value}',
    );
    return processed.metric;
  }

  void _emitMetric(String key, Metric metric) {
    switch (metric.type) {
      case MetricType.heartRate:
      case MetricType.spo2:
      case MetricType.hrv:
      case MetricType.stress:
      case MetricType.battery:
      case MetricType.steps:
        _ctrl<int>(metric.deviceId, key).add(
          VitalSample(
            deviceId: metric.deviceId,
            value: metric.value.round(),
            ts: metric.timestamp,
          ),
        );
        break;
      case MetricType.temperature:
        _ctrl<double>(metric.deviceId, key).add(
          VitalSample(
            deviceId: metric.deviceId,
            value: metric.value,
            ts: metric.timestamp,
          ),
        );
        break;
      default:
        break;
    }
  }

  // ── Heart Rate ──

  @override
  Future<void> startHeartRateNotifications(String deviceId) async {
    _activeDeviceId = deviceId;
    await _ch.invokeMethod('startHeartRateNotifications', {'id': deviceId});
  }

  @override
  Future<void> stopHeartRateNotifications(String deviceId) async {
    await _ch.invokeMethod('stopHeartRateNotifications', {'id': deviceId});
  }

  @override
  Stream<VitalSample<int>> heartRateStream(String deviceId) =>
      _ctrl<int>(deviceId, 'hr').stream;

  // ── SpO2 ──

  @override
  Future<void> startSpO2Notifications(String deviceId) async {
    _activeDeviceId = deviceId;
    await _ch.invokeMethod('startSpO2', {'id': deviceId});
  }

  @override
  Future<void> stopSpO2Notifications(String deviceId) async {
    await _ch.invokeMethod('stopSpO2', {'id': deviceId});
  }

  @override
  Stream<VitalSample<int>> spO2Stream(String deviceId) =>
      _ctrl<int>(deviceId, 'spo2').stream;

  // ── Temperature ──

  @override
  Future<void> startTemperatureNotifications(String deviceId) async {
    _activeDeviceId = deviceId;
    await _ch.invokeMethod('startTemperature', {'id': deviceId});
  }

  @override
  Future<void> stopTemperatureNotifications(String deviceId) async {
    await _ch.invokeMethod('stopTemperature', {'id': deviceId});
  }

  @override
  Stream<VitalSample<double>> temperatureStream(String deviceId) =>
      _ctrl<double>(deviceId, 'temp').stream;

  // ── Steps (periodic poll via CMD_GET_STEP_TODAY) ──

  Timer? _stepsTimer;

  @override
  Future<void> startStepsNotifications(String deviceId) async {
    _activeDeviceId = deviceId;
    _processor.reset(MetricType.steps);
    _stepsTimer?.cancel();
    await _pollStepsOnce(deviceId);
    _stepsTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      await _pollStepsOnce(deviceId);
    });
  }

  Future<void> _pollStepsOnce(String deviceId) async {
    try {
      final res = await _ch.invokeMethod('readMetrics', {'id': deviceId});
      final map = Map<String, dynamic>.from(res as Map);
      final steps = (map['steps'] as num?)?.toInt() ?? 0;
      debugPrint('[SDK STEPS] readMetrics returned steps=$steps raw=$map');
      final metric = _processMetric(
        deviceId,
        MetricType.steps,
        steps.toDouble(),
      );
      if (metric != null) _emitMetric('steps', metric);
    } catch (e, s) {
      ErrorHandler.instance.sdkError(
        'steps poll failed',
        error: e,
        stack: s,
      );
    }
  }

  @override
  Future<void> stopStepsNotifications(String deviceId) async {
    _stepsTimer?.cancel();
    _stepsTimer = null;
  }

  @override
  Stream<VitalSample<int>> stepsStream(String deviceId) =>
      _ctrl<int>(deviceId, 'steps').stream;

  // ── Battery (periodic poll) ──

  Timer? _battTimer;

  @override
  Future<void> startBatteryNotifications(String deviceId) async {
    _activeDeviceId = deviceId;
    _battTimer?.cancel();
    // Poll battery every 60s — first poll after 5s to let connection stabilize
    _battTimer = Timer(const Duration(seconds: 5), () async {
      await _pollBatteryOnce(deviceId);
      _battTimer = Timer.periodic(const Duration(seconds: 60), (_) async {
        await _pollBatteryOnce(deviceId);
      });
    });
  }

  Future<void> _pollBatteryOnce(String deviceId) async {
    try {
      final batt = await _ch.invokeMethod('getBattery');
      if (batt is int && batt >= 0) {
        final metric = _processMetric(
          deviceId,
          MetricType.battery,
          batt.toDouble(),
        );
        if (metric != null) _emitMetric('batt', metric);
      }
    } catch (_) {}
  }

  @override
  Future<void> stopBatteryNotifications(String deviceId) async {
    _battTimer?.cancel();
    _battTimer = null;
  }

  @override
  Stream<VitalSample<int>> batteryStream(String deviceId) =>
      _ctrl<int>(deviceId, 'batt').stream;

  // ── HRV ──

  @override
  Future<void> startHrvNotifications(String deviceId) async {
    _activeDeviceId = deviceId;
    await _ch.invokeMethod('startHrv', {'id': deviceId});
  }

  @override
  Future<void> stopHrvNotifications(String deviceId) async {
    await _ch.invokeMethod('stopHrv', {'id': deviceId});
  }

  @override
  Stream<VitalSample<int>> hrvStream(String deviceId) =>
      _ctrl<int>(deviceId, 'hrv').stream;

  // ── Blood Pressure ──

  @override
  Future<void> startBloodPressureNotifications(String deviceId) async {
    _activeDeviceId = deviceId;
    await _ch.invokeMethod('startBloodPressure', {'id': deviceId});
  }

  @override
  Future<void> stopBloodPressureNotifications(String deviceId) async {
    await _ch.invokeMethod('stopBloodPressure', {'id': deviceId});
  }

  @override
  Stream<VitalSample<BloodPressure>> bloodPressureStream(String deviceId) =>
      _ctrl<BloodPressure>(deviceId, 'bp').stream;

  // ── Action features ──

  /// Sets the bracelet's automatic HR monitoring interval.
  Future<bool> setHeartRateInterval({
    required bool enable,
    required int interval,
  }) async {
    try {
      final res = await _ch.invokeMethod('setHeartRateInterval', {
        'enable': enable,
        'interval': interval,
      });
      return res == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> disconnect() async {
    try {
      // Stop all active polling & rotation
      _battTimer?.cancel();
      _battTimer = null;
      _stepsTimer?.cancel();
      _stepsTimer = null;
      _pollTimer?.cancel();
      _pollTimer = null;
      if (_rotationDeviceId != null) {
        await stopVitalRotation(_rotationDeviceId!);
      }
      // Reset polled value tracking
      _lastPolledHr = 0;
      _lastPolledSpo2 = 0;
      _lastPolledSbp = 0;
      _lastPolledDbp = 0;
      _lastPolledTemp = 0;
      _lastPolledHrv = 0;
      _lastPolledStress = 0;
      _activeDeviceId = null;
      _processor.reset();
      await _ch.invokeMethod('disconnect');
    } catch (_) {}
  }

  @override
  Future<bool> findDevice() async {
    try {
      final res = await _ch.invokeMethod('findDevice');
      return res == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> enterCamera() async {
    try {
      final res = await _ch.invokeMethod('enterCamera');
      return res == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> exitCamera() async {
    try {
      final res = await _ch.invokeMethod('exitCamera');
      return res == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> setCallReminder(bool enable) async {
    try {
      final res = await _ch.invokeMethod('setCallReminder', {'enable': enable});
      return res == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> isNotificationAccessEnabled() async {
    try {
      final res = await _ch.invokeMethod('isNotificationAccessEnabled');
      return res == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> openNotificationAccessSettings() async {
    try {
      await _ch.invokeMethod('openNotificationAccessSettings');
    } catch (_) {}
  }

  @override
  Future<bool> setSedentaryReminder({
    required bool enable,
    int interval = 60,
    int startHour = 9,
    int startMinute = 0,
    int endHour = 18,
    int endMinute = 0,
  }) async {
    try {
      final res = await _ch.invokeMethod('setSedentaryReminder', {
        'enable': enable,
        'interval': interval,
        'startHour': startHour,
        'startMinute': startMinute,
        'endHour': endHour,
        'endMinute': endMinute,
      });
      return res == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> setDnd({
    required bool enable,
    int startHour = 22,
    int startMinute = 0,
    int endHour = 7,
    int endMinute = 0,
  }) async {
    try {
      final res = await _ch.invokeMethod('setDnd', {
        'enable': enable,
        'startHour': startHour,
        'startMinute': startMinute,
        'endHour': endHour,
        'endMinute': endMinute,
      });
      return res == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> setAlarm({
    required int index,
    required bool enable,
    required int hour,
    required int minute,
    int weekMask = 0x7F,
  }) async {
    try {
      final res = await _ch.invokeMethod('setAlarm', {
        'index': index,
        'enable': enable,
        'hour': hour,
        'minute': minute,
        'weekMask': weekMask,
      });
      return res == true;
    } catch (_) {
      return false;
    }
  }

  // ── Stress ──

  @override
  Stream<VitalSample<int>> stressStream(String deviceId) =>
      _ctrl<int>(deviceId, 'stress').stream;

  // ── Vital Rotation Scheduler ──
  // The bracelet only supports ONE manual mode at a time.
  // This scheduler cycles through enabled vitals sequentially.

  Timer? _rotationTimer;
  Timer? _pollTimer;
  bool _rotating = false;
  int _rotationIndex = 0;
  String? _rotationDeviceId;
  String? _currentManualVital;
  List<String> _rotationVitals = [];
  Map<String, int> _rotationIntervals = {};
  String? _rotationSignature;
  // Track last polled values to avoid duplicate events
  int _lastPolledHr = 0;
  int _lastPolledSpo2 = 0;
  int _lastPolledSbp = 0;
  int _lastPolledDbp = 0;
  int _lastPolledTemp = 0;
  int _lastPolledHrv = 0;
  int _lastPolledStress = 0;
  final StreamController<String> _activeVitalCtrl =
      StreamController<String>.broadcast();

  @override
  Stream<String> get activeVitalStream => _activeVitalCtrl.stream;

  @override
  bool get isRotating => _rotating;

  @override
  String? get rotationDeviceId => _rotationDeviceId;

  @override
  Future<void> startVitalRotation(
    String deviceId,
    List<String> vitals,
    Map<String, int> intervals,
  ) async {
    final sanitizedIntervals = <String, int>{
      for (final entry in intervals.entries)
        entry.key: _sanitizeRotationInterval(entry.key, entry.value),
    };
    final signature = _buildRotationSignature(
      deviceId,
      vitals,
      sanitizedIntervals,
    );
    if (_rotating && _rotationSignature == signature) {
      debugPrint('[VitalRotation] Ignoring duplicate start for deviceId=$deviceId');
      return;
    }

    await stopVitalRotation(deviceId);
    if (vitals.isEmpty) return;

    _rotationDeviceId = deviceId;
    _activeDeviceId = deviceId;
    _rotationVitals = vitals
        .where((v) => const {'hr', 'spo2', 'temp', 'bp', 'hrv'}.contains(v))
        .toList();
    _rotationIntervals = Map.from(sanitizedIntervals);
    _rotationSignature = signature;
    _rotating = true;
    _rotationIndex = 0;
    _processor.reset();
    debugPrint(
      '[VitalRotation] Starting QRing manual rotation for deviceId=$deviceId vitals=$vitals intervals=$sanitizedIntervals',
    );

    // Reset polled values so fresh data is picked up
    _lastPolledHr = 0;
    _lastPolledSpo2 = 0;
    _lastPolledSbp = 0;
    _lastPolledDbp = 0;
    _lastPolledTemp = 0;
    _lastPolledHrv = 0;
    _lastPolledStress = 0;

    // QRing returns real values through manual measurement callbacks.
    // Cached polling is only a fallback when the native callback arrives late.
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _pollLastVitalValues(deviceId);
    });

    // Also poll steps periodically
    if (vitals.contains('steps')) {
      _stepsTimer?.cancel();
      await _pollStepsOnce(deviceId);
      final stepSeconds = (_rotationIntervals['steps'] ?? 10).clamp(5, 60);
      _stepsTimer = Timer.periodic(Duration(seconds: stepSeconds), (_) async {
        await _pollStepsOnce(deviceId);
      });
    }

    if (_rotationVitals.isNotEmpty) {
      await _runNextVitalCycle();
    } else {
      _activeVitalCtrl.add(vitals.contains('steps') ? 'steps' : '');
    }
  }

  Future<void> _runNextVitalCycle() async {
    if (!_rotating || _rotationDeviceId == null || _rotationVitals.isEmpty) {
      return;
    }
    final deviceId = _rotationDeviceId!;
    final previous = _currentManualVital;
    if (previous != null) {
      await _stopManualVital(deviceId, previous);
    }

    final vital = _rotationVitals[_rotationIndex % _rotationVitals.length];
    _rotationIndex++;
    _currentManualVital = vital;
    _activeVitalCtrl.add(vital);

    try {
      await _startManualVital(deviceId, vital);
    } catch (e) {
      print('[VitalRotation] start $vital failed: $e');
    }

    final seconds = (_rotationIntervals[vital] ?? 15).clamp(8, 90).toInt();
    _rotationTimer?.cancel();
    _rotationTimer = Timer(Duration(seconds: seconds), () {
      _runNextVitalCycle();
    });
  }

  int _sanitizeRotationInterval(String vital, int seconds) {
    switch (vital) {
      case 'hr':
        return seconds.clamp(20, 90);
      case 'spo2':
        return seconds.clamp(30, 90);
      case 'temp':
        return seconds.clamp(35, 90);
      case 'steps':
        return seconds.clamp(10, 60);
      case 'bp':
        return seconds.clamp(30, 90);
      case 'hrv':
        return seconds.clamp(30, 90);
      default:
        return seconds.clamp(10, 90);
    }
  }

  String _buildRotationSignature(
    String deviceId,
    List<String> vitals,
    Map<String, int> intervals,
  ) {
    final sortedVitals = [...vitals]..sort();
    final sortedIntervals = intervals.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final intervalPart = sortedIntervals
        .map((entry) => '${entry.key}:${entry.value}')
        .join(',');
    return '$deviceId|${sortedVitals.join(',')}|$intervalPart';
  }

  Future<void> _startManualVital(String deviceId, String vital) async {
    switch (vital) {
      case 'hr':
        await startHeartRateNotifications(deviceId);
        break;
      case 'spo2':
        await startSpO2Notifications(deviceId);
        break;
      case 'temp':
        await startTemperatureNotifications(deviceId);
        break;
      case 'bp':
        await startBloodPressureNotifications(deviceId);
        break;
      case 'hrv':
        await startHrvNotifications(deviceId);
        break;
    }
  }

  Future<void> _stopManualVital(String deviceId, String vital) async {
    try {
      switch (vital) {
        case 'hr':
          await stopHeartRateNotifications(deviceId);
          break;
        case 'spo2':
          await stopSpO2Notifications(deviceId);
          break;
        case 'temp':
          await stopTemperatureNotifications(deviceId);
          break;
        case 'bp':
          await stopBloodPressureNotifications(deviceId);
          break;
        case 'hrv':
          await stopHrvNotifications(deviceId);
          break;
      }
    } catch (e) {
      print('[VitalRotation] stop $vital failed: $e');
    }
  }

  /// Polls native cached vital values and injects any new data into streams.
  Future<void> _pollLastVitalValues(String deviceId) async {
    try {
      final res = await _ch.invokeMethod('getLastVitalValues');
      if (res is! Map) return;
      final map = Map<String, dynamic>.from(res);
      debugPrint(
        '[SDK POLL] raw values from native: hr=${map['hr']} spo2=${map['spo2']} sbp=${map['sbp']} dbp=${map['dbp']} temp=${map['temp']} hrv=${map['hrv']} stress=${map['stress']}',
      );

      final hr = (map['hr'] as num?)?.toInt() ?? 0;
      if (hr > 0 && hr != _lastPolledHr) {
        _lastPolledHr = hr;
        debugPrint('[SDK POLL] HR changed: $hr bpm (prev=$_lastPolledHr)');
        final metric = _processMetric(
          deviceId,
          MetricType.heartRate,
          hr.toDouble(),
        );
        if (metric != null) _emitMetric('hr', metric);
      }

      final spo2 = (map['spo2'] as num?)?.toInt() ?? 0;
      if (spo2 > 0 && spo2 != _lastPolledSpo2) {
        _lastPolledSpo2 = spo2;
        debugPrint('[SDK POLL] SpO2 changed: $spo2% (prev=${_lastPolledSpo2})');
        final metric = _processMetric(
          deviceId,
          MetricType.spo2,
          spo2.toDouble(),
        );
        if (metric != null) _emitMetric('spo2', metric);
      }

      final sbp = (map['sbp'] as num?)?.toInt() ?? 0;
      final dbp = (map['dbp'] as num?)?.toInt() ?? 0;
      if (sbp > 0 &&
          dbp > 0 &&
          (sbp != _lastPolledSbp || dbp != _lastPolledDbp)) {
        _lastPolledSbp = sbp;
        _lastPolledDbp = dbp;
        final s = _processMetric(
          deviceId,
          MetricType.bloodPressureSystolic,
          sbp.toDouble(),
        );
        final d = _processMetric(
          deviceId,
          MetricType.bloodPressureDiastolic,
          dbp.toDouble(),
        );
        if (s != null && d != null) {
          _ctrl<BloodPressure>(deviceId, 'bp').add(
            VitalSample(
              deviceId: deviceId,
              value: BloodPressure(s.value.round(), d.value.round()),
              ts: s.timestamp,
            ),
          );
        }
      }

      final tempRaw = (map['temp'] as num?)?.toInt() ?? 0;
      if (tempRaw > 0 && tempRaw != _lastPolledTemp) {
        _lastPolledTemp = tempRaw;
        final temp = tempRaw / 10.0;
        debugPrint('[SDK POLL] Temp changed: raw=$tempRaw => ${temp}\u00b0C');
        final metric = _processMetric(deviceId, MetricType.temperature, temp);
        if (metric != null) _emitMetric('temp', metric);
      }

      final hrv = (map['hrv'] as num?)?.toInt() ?? 0;
      if (hrv > 0 && hrv != _lastPolledHrv) {
        _lastPolledHrv = hrv;
        debugPrint('[SDK POLL] HRV changed: $hrv ms');
        final metric = _processMetric(deviceId, MetricType.hrv, hrv.toDouble());
        if (metric != null) _emitMetric('hrv', metric);
      }

      final stress = (map['stress'] as num?)?.toInt() ?? 0;
      if (stress > 0 && stress != _lastPolledStress) {
        _lastPolledStress = stress;
        debugPrint('[SDK POLL] Stress changed: $stress');
        final metric = _processMetric(
          deviceId,
          MetricType.stress,
          stress.toDouble(),
        );
        if (metric != null) _emitMetric('stress', metric);
      }
    } catch (e) {
      print('[VitalRotation] pollLastVitalValues error: $e');
    }
  }

  @override
  Future<void> stopVitalRotation(String deviceId) async {
    _rotating = false;
    _rotationSignature = null;
    _rotationTimer?.cancel();
    _rotationTimer = null;
    _pollTimer?.cancel();
    _pollTimer = null;
    _stepsTimer?.cancel();
    _stepsTimer = null;
    if (_currentManualVital != null) {
      await _stopManualVital(deviceId, _currentManualVital!);
      _currentManualVital = null;
    }
    try {
      await _ch.invokeMethod('stopContinuousMeasurement');
    } catch (_) {}
    _activeVitalCtrl.add('');
  }

  @override
  Future<Map<String, dynamic>?> syncSleep() async {
    try {
      final res = await _ch
          .invokeMethod('syncSleep')
          .timeout(const Duration(seconds: 25));
      if (res is Map) {
        final data = Map<String, dynamic>.from(res);
        // If old protocol returned zeros but we have segments, calculate from segments
        final total = (data['totalSleep'] as num?)?.toInt() ?? 0;
        if (total == 0 && data['segments'] is List) {
          final segments = data['segments'] as List;
          int deep = 0, light = 0, rem = 0, awake = 0;
          for (final seg in segments) {
            if (seg is Map) {
              final duration = (seg['duration'] as num?)?.toInt() ?? 0;
              final type = (seg['type'] as num?)?.toInt() ?? 0;
              switch (type) {
                case 1:
                  deep += duration;
                  break;
                case 2:
                  light += duration;
                  break;
                case 3:
                  rem += duration;
                  break;
                case 4:
                  awake += duration;
                  break;
              }
            }
          }
          final totalCalc = deep + light + rem;
          if (totalCalc > 0) {
            data['totalSleep'] = totalCalc;
            data['deepSleep'] = deep;
            data['lightSleep'] = light;
            data['remSleep'] = rem;
            data['awake'] = awake;
          }
        }
        return data;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
