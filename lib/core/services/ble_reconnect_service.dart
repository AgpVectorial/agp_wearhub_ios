import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../errors/app_error.dart';
import '../sdk/sdk_adapter.dart';
import 'medical_alert_service.dart';

enum BleReconnectStatus { idle, monitoring, reconnecting, connected, failed }

class BleReconnectState {
  final BleReconnectStatus status;
  final String? deviceId;
  final int attempt;
  final String? message;

  const BleReconnectState({
    this.status = BleReconnectStatus.idle,
    this.deviceId,
    this.attempt = 0,
    this.message,
  });

  BleReconnectState copyWith({
    BleReconnectStatus? status,
    String? deviceId,
    int? attempt,
    String? message,
  }) =>
      BleReconnectState(
        status: status ?? this.status,
        deviceId: deviceId ?? this.deviceId,
        attempt: attempt ?? this.attempt,
        message: message ?? this.message,
      );
}

class BleReconnectService extends StateNotifier<BleReconnectState> {
  BleReconnectService({
    required this.sdk,
    required this.alerts,
  }) : super(const BleReconnectState());

  final WearSdk sdk;
  final MedicalAlertService alerts;

  StreamSubscription<ConnectionUpdate>? _connectionSub;
  Timer? _retryTimer;
  bool _manualStop = false;
  bool _reconnectInFlight = false;

  Future<void> monitor(String deviceId) async {
    _manualStop = false;
    await _connectionSub?.cancel();
    _connectionSub = sdk.connectionUpdates(deviceId).listen((update) {
      if (update.connected) {
        _onConnected(update.deviceId);
      } else {
        _onDisconnected(update.deviceId);
      }
    });
    state = BleReconnectState(
      status: BleReconnectStatus.monitoring,
      deviceId: deviceId,
    );
  }

  Future<void> markConnected(String deviceId) async {
    await monitor(deviceId);
    _onConnected(deviceId);
  }

  Future<void> stop() async {
    _manualStop = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _connectionSub?.cancel();
    _connectionSub = null;
    state = const BleReconnectState();
  }

  void _onConnected(String deviceId) {
    _retryTimer?.cancel();
    _retryTimer = null;
    _reconnectInFlight = false;
    state = BleReconnectState(
      status: BleReconnectStatus.connected,
      deviceId: deviceId,
    );
  }

  Future<void> _onDisconnected(String deviceId) async {
    if (_manualStop) return;
    await alerts.connectionLost(deviceId);
    state = BleReconnectState(
      status: BleReconnectStatus.reconnecting,
      deviceId: deviceId,
      attempt: 0,
      message: 'Conexiune pierduta. Reconnect automat...',
    );
    _scheduleRetry(deviceId, 1);
  }

  void _scheduleRetry(String deviceId, int attempt) {
    _retryTimer?.cancel();
    final seconds = math.min(45, math.pow(2, attempt).round());
    _retryTimer = Timer(Duration(seconds: seconds), () {
      _tryReconnect(deviceId, attempt);
    });
  }

  Future<void> _tryReconnect(String deviceId, int attempt) async {
    if (_manualStop || _reconnectInFlight) return;
    if (attempt > 8) {
      state = state.copyWith(
        status: BleReconnectStatus.failed,
        attempt: attempt,
        message: 'Reconnect esuat dupa mai multe incercari.',
      );
      ErrorHandler.instance.bleError(
        AppErrorCode.bleConnectionTimeout,
        'Reconnect failed for $deviceId',
        deviceId: deviceId,
      );
      return;
    }

    _reconnectInFlight = true;
    state = state.copyWith(
      status: BleReconnectStatus.reconnecting,
      attempt: attempt,
      message: 'Reconnect BLE: incercarea $attempt',
    );

    try {
      final ok = await sdk
          .connect(deviceId, autoReconnect: true)
          .timeout(const Duration(seconds: 18));
      if (ok) {
        _onConnected(deviceId);
        return;
      }
      _scheduleRetry(deviceId, attempt + 1);
    } catch (e, s) {
      debugPrint('[BleReconnect] attempt $attempt failed: $e');
      ErrorHandler.instance.bleError(
        AppErrorCode.bleConnectionLost,
        'Reconnect attempt $attempt failed',
        error: e,
        stack: s,
        deviceId: deviceId,
      );
      _scheduleRetry(deviceId, attempt + 1);
    } finally {
      _reconnectInFlight = false;
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _connectionSub?.cancel();
    super.dispose();
  }
}

final bleReconnectProvider =
    StateNotifierProvider<BleReconnectService, BleReconnectState>((ref) {
  return BleReconnectService(
    sdk: MethodChannelWearSdk(),
    alerts: ref.watch(medicalAlertProvider.notifier),
  );
});
