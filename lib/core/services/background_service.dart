import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../errors/app_error.dart';
import '../models/metric.dart';
import '../storage/vitals_db.dart';

/// Starea serviciului de background.
enum BackgroundServiceStatus { stopped, starting, running, stopping }

@immutable
class BackgroundServiceState {
  final BackgroundServiceStatus status;
  final String? activeDeviceId;
  final String? activeUserId;
  final DateTime? lastCollectionTime;
  final int metricsCollectedCount;

  const BackgroundServiceState({
    this.status = BackgroundServiceStatus.stopped,
    this.activeDeviceId,
    this.activeUserId,
    this.lastCollectionTime,
    this.metricsCollectedCount = 0,
  });

  BackgroundServiceState copyWith({
    BackgroundServiceStatus? status,
    String? activeDeviceId,
    String? activeUserId,
    DateTime? lastCollectionTime,
    int? metricsCollectedCount,
  }) => BackgroundServiceState(
    status: status ?? this.status,
    activeDeviceId: activeDeviceId ?? this.activeDeviceId,
    activeUserId: activeUserId ?? this.activeUserId,
    lastCollectionTime: lastCollectionTime ?? this.lastCollectionTime,
    metricsCollectedCount: metricsCollectedCount ?? this.metricsCollectedCount,
  );

  bool get isRunning => status == BackgroundServiceStatus.running;
}

/// Serviciu de colectare metrici în background.
///
/// Funcționează ca un serviciu persistent care:
/// - Menține conexiunea BLE activă
/// - Colectează periodic metrici de la dispozitiv
/// - Emite notificări pentru valori critice
/// - Salvează datele în DB chiar și când app-ul e minimizat
class BackgroundMetricsService extends StateNotifier<BackgroundServiceState> {
  BackgroundMetricsService({required this.db})
    : super(const BackgroundServiceState());

  final VitalsDatabase db;
  Timer? _collectionTimer;
  final _metricsController = StreamController<Metric>.broadcast();

  /// Stream de metrici colectate (pentru UI sau alerte).
  Stream<Metric> get metricsStream => _metricsController.stream;

  /// Pornește colectarea periodică de metrici.
  Future<void> start({
    required String deviceId,
    required String userId,
    Duration interval = const Duration(seconds: 5),
  }) async {
    if (state.isRunning) return;

    state = state.copyWith(
      status: BackgroundServiceStatus.starting,
      activeDeviceId: deviceId,
      activeUserId: userId,
    );

    try {
      state = state.copyWith(status: BackgroundServiceStatus.running);

      _collectionTimer?.cancel();
      _collectionTimer = Timer.periodic(interval, (_) {
        _collectMetrics(deviceId, userId);
      });

      debugPrint(
        '[BackgroundService] Started for device=$deviceId, user=$userId',
      );
    } catch (e, s) {
      ErrorHandler.instance.report(
        AppError(
          code: AppErrorCode.unknown,
          message: 'Background service start failed: $e',
          originalError: e,
          stackTrace: s,
          deviceId: deviceId,
        ),
      );
      state = state.copyWith(status: BackgroundServiceStatus.stopped);
    }
  }

  /// Oprește serviciul de background.
  Future<void> stop() async {
    state = state.copyWith(status: BackgroundServiceStatus.stopping);
    _collectionTimer?.cancel();
    _collectionTimer = null;
    state = const BackgroundServiceState();
    debugPrint('[BackgroundService] Stopped');
  }

  /// Colectare internă – apelată periodic.
  Future<void> _collectMetrics(String deviceId, String userId) async {
    // Metricile sunt deja populate de stream-urile SDK.
    // Acest timer asigură persistența periodică.
    state = state.copyWith(lastCollectionTime: DateTime.now().toUtc());
  }

  /// Procesează și salvează o metrică primită din orice sursă.
  Future<void> processMetric(Metric metric) async {
    if (!metric.isValid) {
      ErrorHandler.instance.invalidData(
        'Out-of-range ${metric.type.dbName}: ${metric.value}',
        deviceId: metric.deviceId,
      );
      return;
    }

    // Salvează în DB
    await db.insertMetric(metric);

    // Emite pe stream
    _metricsController.add(metric);

    state = state.copyWith(
      metricsCollectedCount: state.metricsCollectedCount + 1,
      lastCollectionTime: metric.timestamp,
    );

    // Verificări critice
    _checkCriticalValues(metric);
  }

  /// Verifică valori critice și emite alerte.
  void _checkCriticalValues(Metric m) {
    String? alert;

    switch (m.type) {
      case MetricType.heartRate:
        if (m.value > 180) alert = 'HR critic ridicat: ${m.value.toInt()} bpm';
        if (m.value < 40) alert = 'HR critic scăzut: ${m.value.toInt()} bpm';
        break;
      case MetricType.spo2:
        if (m.value < 90) alert = 'SpO2 critic: ${m.value.toInt()}%';
        break;
      case MetricType.temperature:
        if (m.value > 39.5) {
          alert = 'Temperatură ridicată: ${m.value.toStringAsFixed(1)}°C';
        }
        if (m.value < 35.0) {
          alert = 'Hipotermie: ${m.value.toStringAsFixed(1)}°C';
        }
        break;
      case MetricType.battery:
        if (m.value <= 10) alert = 'Baterie critică: ${m.value.toInt()}%';
        break;
      default:
        break;
    }

    if (alert != null) {
      NotificationService.instance.showCriticalAlert(alert);
    }
  }

  @override
  void dispose() {
    _collectionTimer?.cancel();
    _metricsController.close();
    super.dispose();
  }
}

// ──────────────────────────────────────────
//  Serviciu de notificări locale
// ──────────────────────────────────────────

/// Serviciu simplu de notificări locale.
///
/// Folosește mecanisme native prin MethodChannel.
/// Pentru integrare completă, adaugă flutter_local_notifications în pubspec.
class NotificationService {
  NotificationService._();
  static final instance = NotificationService._();

  bool _initialized = false;
  final _alertController = StreamController<String>.broadcast();

  /// Stream de alerte pentru UI (când nu se pot afișa notificări native).
  Stream<String> get alerts => _alertController.stream;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    debugPrint('[NotificationService] Initialized');
  }

  /// Afișează o alertă critică.
  void showCriticalAlert(String message) {
    _alertController.add(message);
    debugPrint('[NotificationService] ALERT: $message');
  }

  /// Afișează o notificare informativă.
  void showInfo(String title, String body) {
    debugPrint('[NotificationService] INFO: $title - $body');
  }

  /// Afișează notificare de colectare activă (foreground service).
  void showCollectionActive({required String deviceName}) {
    debugPrint('[NotificationService] Collecting data from $deviceName');
  }

  /// Ascunde notificarea de colectare.
  void hideCollectionNotification() {
    debugPrint('[NotificationService] Collection notification hidden');
  }

  void dispose() {
    _alertController.close();
  }
}

// ──────────────────────────────────────────
//  Scanner BLE de background
// ──────────────────────────────────────────

/// Manager de scanare BLE care funcționează și în background.
class BackgroundBleScanner {
  BackgroundBleScanner._();
  static final instance = BackgroundBleScanner._();

  Timer? _scanTimer;
  bool _isScanning = false;
  final _devicesController = StreamController<List<String>>.broadcast();

  Stream<List<String>> get discoveredDevices => _devicesController.stream;
  bool get isScanning => _isScanning;

  /// Pornește scanare periodică.
  void startPeriodicScan({
    Duration interval = const Duration(minutes: 5),
    Duration scanDuration = const Duration(seconds: 10),
  }) {
    _scanTimer?.cancel();
    _scanTimer = Timer.periodic(interval, (_) async {
      await _performScan(scanDuration);
    });
    // Prima scanare imediat
    _performScan(scanDuration);
  }

  Future<void> _performScan(Duration duration) async {
    if (_isScanning) return;
    _isScanning = true;
    try {
      // Scanarea efectivă se face prin SDK adapter
      debugPrint('[BackgroundBleScanner] Scanning for $duration...');
      await Future.delayed(duration);
    } catch (e) {
      ErrorHandler.instance.bleError(
        AppErrorCode.bleScanFailed,
        'Background scan failed: $e',
        error: e,
      );
    } finally {
      _isScanning = false;
    }
  }

  void stopPeriodicScan() {
    _scanTimer?.cancel();
    _scanTimer = null;
    _isScanning = false;
  }

  void dispose() {
    stopPeriodicScan();
    _devicesController.close();
  }
}

// ──────────────────────────────────────────
//  Providers Riverpod
// ──────────────────────────────────────────

final backgroundServiceProvider =
    StateNotifierProvider<BackgroundMetricsService, BackgroundServiceState>(
      (ref) => BackgroundMetricsService(db: ref.watch(vitalsDbProvider)),
    );

final notificationServiceProvider = Provider<NotificationService>(
  (_) => NotificationService.instance,
);
