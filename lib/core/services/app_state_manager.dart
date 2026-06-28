import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/metric.dart';
import '../errors/app_error.dart';

// ─────────────────────────────────────────
//  1. Device Connection State Manager
// ─────────────────────────────────────────

enum DeviceConnectionPhase {
  idle,
  scanning,
  connecting,
  discovering,
  ready,
  reconnecting,
  disconnected,
  error,
}

@immutable
class DeviceConnectionInfo {
  final DeviceConnectionPhase phase;
  final String? deviceId;
  final String? deviceName;
  final int signalStrength; // RSSI
  final int reconnectAttempts;
  final String? errorMessage;
  final DateTime? connectedSince;

  const DeviceConnectionInfo({
    this.phase = DeviceConnectionPhase.idle,
    this.deviceId,
    this.deviceName,
    this.signalStrength = 0,
    this.reconnectAttempts = 0,
    this.errorMessage,
    this.connectedSince,
  });

  DeviceConnectionInfo copyWith({
    DeviceConnectionPhase? phase,
    String? deviceId,
    String? deviceName,
    int? signalStrength,
    int? reconnectAttempts,
    String? errorMessage,
    DateTime? connectedSince,
  }) => DeviceConnectionInfo(
    phase: phase ?? this.phase,
    deviceId: deviceId ?? this.deviceId,
    deviceName: deviceName ?? this.deviceName,
    signalStrength: signalStrength ?? this.signalStrength,
    reconnectAttempts: reconnectAttempts ?? this.reconnectAttempts,
    errorMessage: errorMessage ?? this.errorMessage,
    connectedSince: connectedSince ?? this.connectedSince,
  );

  bool get isReady => phase == DeviceConnectionPhase.ready;
  bool get isConnecting =>
      phase == DeviceConnectionPhase.connecting ||
      phase == DeviceConnectionPhase.discovering;

  Duration? get uptime => connectedSince != null
      ? DateTime.now().difference(connectedSince!)
      : null;
}

class DeviceConnectionManager extends StateNotifier<DeviceConnectionInfo> {
  DeviceConnectionManager() : super(const DeviceConnectionInfo());

  void startScanning() {
    state = state.copyWith(phase: DeviceConnectionPhase.scanning);
  }

  void startConnecting(String deviceId, String deviceName) {
    state = state.copyWith(
      phase: DeviceConnectionPhase.connecting,
      deviceId: deviceId,
      deviceName: deviceName,
      errorMessage: null,
    );
  }

  void onDiscovering() {
    state = state.copyWith(phase: DeviceConnectionPhase.discovering);
  }

  void onConnected() {
    state = state.copyWith(
      phase: DeviceConnectionPhase.ready,
      reconnectAttempts: 0,
      connectedSince: DateTime.now(),
      errorMessage: null,
    );
  }

  void onDisconnected() {
    state = state.copyWith(
      phase: DeviceConnectionPhase.disconnected,
      connectedSince: null,
    );
  }

  void onReconnecting(int attempt) {
    state = state.copyWith(
      phase: DeviceConnectionPhase.reconnecting,
      reconnectAttempts: attempt,
    );
  }

  void reportError(String message) {
    state = state.copyWith(
      phase: DeviceConnectionPhase.error,
      errorMessage: message,
    );
  }

  void updateSignalStrength(int rssi) {
    state = state.copyWith(signalStrength: rssi);
  }

  void reset() {
    state = const DeviceConnectionInfo();
  }
}

final deviceConnectionManagerProvider =
    StateNotifierProvider<DeviceConnectionManager, DeviceConnectionInfo>(
      (ref) => DeviceConnectionManager(),
    );

// ─────────────────────────────────────────
//  2. Metric Streams State Manager
// ─────────────────────────────────────────

enum MetricStreamStatus { inactive, active, paused, error }

@immutable
class MetricStreamInfo {
  final MetricType type;
  final MetricStreamStatus status;
  final double? lastValue;
  final DateTime? lastUpdate;
  final int samplesReceived;

  const MetricStreamInfo({
    required this.type,
    this.status = MetricStreamStatus.inactive,
    this.lastValue,
    this.lastUpdate,
    this.samplesReceived = 0,
  });

  MetricStreamInfo copyWith({
    MetricStreamStatus? status,
    double? lastValue,
    DateTime? lastUpdate,
    int? samplesReceived,
  }) => MetricStreamInfo(
    type: type,
    status: status ?? this.status,
    lastValue: lastValue ?? this.lastValue,
    lastUpdate: lastUpdate ?? this.lastUpdate,
    samplesReceived: samplesReceived ?? this.samplesReceived,
  );

  bool get isActive => status == MetricStreamStatus.active;
  bool get isStale =>
      lastUpdate != null &&
      DateTime.now().difference(lastUpdate!) > const Duration(seconds: 30);
}

@immutable
class MetricStreamsState {
  final Map<MetricType, MetricStreamInfo> streams;

  const MetricStreamsState({this.streams = const {}});

  MetricStreamsState copyWithStream(MetricType type, MetricStreamInfo info) {
    return MetricStreamsState(streams: {...streams, type: info});
  }

  int get activeCount =>
      streams.values.where((s) => s.status == MetricStreamStatus.active).length;

  int get totalSamples =>
      streams.values.fold(0, (sum, s) => sum + s.samplesReceived);

  List<MetricStreamInfo> get activeStreams =>
      streams.values.where((s) => s.isActive).toList();

  List<MetricStreamInfo> get staleStreams =>
      streams.values.where((s) => s.isStale).toList();
}

class MetricStreamsManager extends StateNotifier<MetricStreamsState> {
  MetricStreamsManager() : super(const MetricStreamsState());

  void activateStream(MetricType type) {
    final current = state.streams[type] ?? MetricStreamInfo(type: type);
    state = state.copyWithStream(
      type,
      current.copyWith(status: MetricStreamStatus.active),
    );
  }

  void deactivateStream(MetricType type) {
    final current = state.streams[type];
    if (current == null) return;
    state = state.copyWithStream(
      type,
      current.copyWith(status: MetricStreamStatus.inactive),
    );
  }

  void onMetricReceived(MetricType type, double value) {
    final current =
        state.streams[type] ??
        MetricStreamInfo(type: type, status: MetricStreamStatus.active);
    state = state.copyWithStream(
      type,
      current.copyWith(
        lastValue: value,
        lastUpdate: DateTime.now(),
        samplesReceived: current.samplesReceived + 1,
      ),
    );
  }

  void onStreamError(MetricType type) {
    final current = state.streams[type];
    if (current == null) return;
    state = state.copyWithStream(
      type,
      current.copyWith(status: MetricStreamStatus.error),
    );
  }

  void pauseAll() {
    final updated = <MetricType, MetricStreamInfo>{};
    for (final entry in state.streams.entries) {
      if (entry.value.isActive) {
        updated[entry.key] = entry.value.copyWith(
          status: MetricStreamStatus.paused,
        );
      } else {
        updated[entry.key] = entry.value;
      }
    }
    state = MetricStreamsState(streams: updated);
  }

  void resumeAll() {
    final updated = <MetricType, MetricStreamInfo>{};
    for (final entry in state.streams.entries) {
      if (entry.value.status == MetricStreamStatus.paused) {
        updated[entry.key] = entry.value.copyWith(
          status: MetricStreamStatus.active,
        );
      } else {
        updated[entry.key] = entry.value;
      }
    }
    state = MetricStreamsState(streams: updated);
  }

  void resetAll() {
    state = const MetricStreamsState();
  }
}

final metricStreamsManagerProvider =
    StateNotifierProvider<MetricStreamsManager, MetricStreamsState>(
      (ref) => MetricStreamsManager(),
    );

// ─────────────────────────────────────────
//  3. Error & Reconnect State Manager
// ─────────────────────────────────────────

@immutable
class ErrorReconnectState {
  final List<AppError> recentErrors;
  final bool isReconnecting;
  final int consecutiveErrors;
  final DateTime? lastErrorAt;
  final bool circuitBreakerOpen; // prea multe erori consecutive

  const ErrorReconnectState({
    this.recentErrors = const [],
    this.isReconnecting = false,
    this.consecutiveErrors = 0,
    this.lastErrorAt,
    this.circuitBreakerOpen = false,
  });

  ErrorReconnectState copyWith({
    List<AppError>? recentErrors,
    bool? isReconnecting,
    int? consecutiveErrors,
    DateTime? lastErrorAt,
    bool? circuitBreakerOpen,
  }) => ErrorReconnectState(
    recentErrors: recentErrors ?? this.recentErrors,
    isReconnecting: isReconnecting ?? this.isReconnecting,
    consecutiveErrors: consecutiveErrors ?? this.consecutiveErrors,
    lastErrorAt: lastErrorAt ?? this.lastErrorAt,
    circuitBreakerOpen: circuitBreakerOpen ?? this.circuitBreakerOpen,
  );
}

class ErrorReconnectManager extends StateNotifier<ErrorReconnectState> {
  ErrorReconnectManager() : super(const ErrorReconnectState());

  static const _circuitBreakerThreshold = 5;
  static const _maxRecentErrors = 20;

  void reportError(AppError error) {
    final errors = [...state.recentErrors, error];
    if (errors.length > _maxRecentErrors) {
      errors.removeRange(0, errors.length - _maxRecentErrors);
    }

    final consecutive = state.consecutiveErrors + 1;
    final circuitOpen = consecutive >= _circuitBreakerThreshold;

    state = state.copyWith(
      recentErrors: errors,
      consecutiveErrors: consecutive,
      lastErrorAt: DateTime.now(),
      circuitBreakerOpen: circuitOpen,
    );

    if (circuitOpen) {
      debugPrint(
        '[ErrorReconnectManager] Circuit breaker OPEN after $consecutive errors',
      );
    }
  }

  void onSuccess() {
    state = state.copyWith(consecutiveErrors: 0, circuitBreakerOpen: false);
  }

  void setReconnecting(bool value) {
    state = state.copyWith(isReconnecting: value);
  }

  void clearErrors() {
    state = const ErrorReconnectState();
  }

  /// Verifică dacă putem face retry (circuit breaker).
  bool get canRetry => !state.circuitBreakerOpen;
}

final errorReconnectManagerProvider =
    StateNotifierProvider<ErrorReconnectManager, ErrorReconnectState>(
      (ref) => ErrorReconnectManager(),
    );
