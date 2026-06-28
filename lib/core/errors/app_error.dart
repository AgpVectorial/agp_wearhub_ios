import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// ──────────────────────────────────────────
//  Tipuri de erori ale aplicației
// ──────────────────────────────────────────

enum AppErrorSeverity { info, warning, critical }

enum AppErrorCode {
  // BLE
  blePermissionDenied,
  bleConnectionLost,
  bleConnectionTimeout,
  bleScanFailed,
  bleCharacteristicNotFound,
  bleDeviceIncompatible,
  bleAdapterOff,

  // SDK
  sdkInitFailed,
  sdkMethodCallFailed,
  sdkDataParseError,
  sdkTimeout,

  // Data
  invalidData,
  dataOutOfRange,
  dataParseFailed,

  // Device
  deviceNotConnected,
  deviceIncompatible,
  deviceBatteryLow,

  // Storage
  databaseError,
  storageFull,

  // User
  authFailed,
  userNotFound,
  pinIncorrect,

  // General
  unknown,
  networkError,
  timeout,
}

extension AppErrorCodeInfo on AppErrorCode {
  AppErrorSeverity get defaultSeverity => switch (this) {
    AppErrorCode.bleConnectionLost => AppErrorSeverity.warning,
    AppErrorCode.bleConnectionTimeout => AppErrorSeverity.warning,
    AppErrorCode.blePermissionDenied => AppErrorSeverity.critical,
    AppErrorCode.bleAdapterOff => AppErrorSeverity.critical,
    AppErrorCode.bleDeviceIncompatible => AppErrorSeverity.critical,
    AppErrorCode.deviceIncompatible => AppErrorSeverity.critical,
    AppErrorCode.sdkInitFailed => AppErrorSeverity.critical,
    AppErrorCode.invalidData => AppErrorSeverity.info,
    AppErrorCode.dataOutOfRange => AppErrorSeverity.info,
    AppErrorCode.deviceBatteryLow => AppErrorSeverity.warning,
    AppErrorCode.authFailed => AppErrorSeverity.warning,
    AppErrorCode.pinIncorrect => AppErrorSeverity.warning,
    _ => AppErrorSeverity.warning,
  };

  bool get isRetryable => switch (this) {
    AppErrorCode.bleConnectionLost => true,
    AppErrorCode.bleConnectionTimeout => true,
    AppErrorCode.bleScanFailed => true,
    AppErrorCode.sdkMethodCallFailed => true,
    AppErrorCode.sdkTimeout => true,
    AppErrorCode.timeout => true,
    AppErrorCode.networkError => true,
    _ => false,
  };
}

/// Eroare structurată a aplicației.
@immutable
class AppError {
  final AppErrorCode code;
  final String message;
  final AppErrorSeverity severity;
  final Object? originalError;
  final StackTrace? stackTrace;
  final DateTime timestamp;
  final String? deviceId;

  AppError({
    required this.code,
    required this.message,
    AppErrorSeverity? severity,
    this.originalError,
    this.stackTrace,
    this.deviceId,
  }) : severity = severity ?? code.defaultSeverity,
       timestamp = DateTime.now().toUtc();

  bool get isRetryable => code.isRetryable;

  @override
  String toString() =>
      'AppError(${code.name}: $message, severity=${severity.name})';
}

// ──────────────────────────────────────────
//  Handler central de erori
// ──────────────────────────────────────────

typedef ErrorCallback = void Function(AppError error);

class ErrorHandler {
  ErrorHandler._();
  static final instance = ErrorHandler._();

  final _controller = StreamController<AppError>.broadcast();
  final List<AppError> _recentErrors = [];
  static const _maxRecent = 50;

  ErrorCallback? onCriticalError;

  /// Stream de erori pentru UI (snackbar, banner etc.).
  Stream<AppError> get errors => _controller.stream;

  /// Ultimele erori (pentru diagnostics page).
  List<AppError> get recentErrors => List.unmodifiable(_recentErrors);

  /// Raportează o eroare.
  void report(AppError error) {
    _recentErrors.add(error);
    if (_recentErrors.length > _maxRecent) {
      _recentErrors.removeAt(0);
    }
    _controller.add(error);

    if (error.severity == AppErrorSeverity.critical) {
      onCriticalError?.call(error);
    }

    debugPrint('[ErrorHandler] $error');
  }

  /// Scurtătură: eroare BLE.
  void bleError(
    AppErrorCode code,
    String message, {
    Object? error,
    StackTrace? stack,
    String? deviceId,
  }) {
    report(
      AppError(
        code: code,
        message: message,
        originalError: error,
        stackTrace: stack,
        deviceId: deviceId,
      ),
    );
  }

  /// Scurtătură: eroare SDK.
  void sdkError(String message, {Object? error, StackTrace? stack}) {
    report(
      AppError(
        code: AppErrorCode.sdkMethodCallFailed,
        message: message,
        originalError: error,
        stackTrace: stack,
      ),
    );
  }

  /// Scurtătură: date invalide.
  void invalidData(String message, {String? deviceId}) {
    report(
      AppError(
        code: AppErrorCode.invalidData,
        message: message,
        deviceId: deviceId,
      ),
    );
  }

  /// Scurtătură: timeout.
  void timeoutError(String message, {String? deviceId}) {
    report(
      AppError(
        code: AppErrorCode.timeout,
        message: message,
        deviceId: deviceId,
      ),
    );
  }

  /// Curăță istoricul de erori.
  void clearHistory() => _recentErrors.clear();

  void dispose() {
    _controller.close();
  }
}

/// Execută o operație cu timeout și tratament de erori.
Future<T?> withTimeout<T>(
  Future<T> Function() operation, {
  Duration timeout = const Duration(seconds: 10),
  required String operationName,
  String? deviceId,
}) async {
  try {
    return await operation().timeout(timeout);
  } on TimeoutException {
    ErrorHandler.instance.timeoutError(
      '$operationName timeout (${timeout.inSeconds}s)',
      deviceId: deviceId,
    );
    return null;
  } catch (e, s) {
    ErrorHandler.instance.report(
      AppError(
        code: AppErrorCode.unknown,
        message: '$operationName failed: $e',
        originalError: e,
        stackTrace: s,
        deviceId: deviceId,
      ),
    );
    return null;
  }
}

/// Execută o operație cu retry automat.
Future<T?> withRetry<T>(
  Future<T> Function() operation, {
  int maxRetries = 3,
  Duration delay = const Duration(seconds: 1),
  required String operationName,
  String? deviceId,
}) async {
  for (var i = 0; i <= maxRetries; i++) {
    try {
      return await operation();
    } catch (e, s) {
      if (i == maxRetries) {
        ErrorHandler.instance.report(
          AppError(
            code: AppErrorCode.unknown,
            message:
                '$operationName failed after ${maxRetries + 1} attempts: $e',
            originalError: e,
            stackTrace: s,
            deviceId: deviceId,
          ),
        );
        return null;
      }
      await Future.delayed(delay * (i + 1));
    }
  }
  return null;
}

// ──────────────────────────────────────────
//  Provider Riverpod
// ──────────────────────────────────────────

final errorHandlerProvider = Provider<ErrorHandler>(
  (_) => ErrorHandler.instance,
);

final errorStreamProvider = StreamProvider<AppError>((ref) {
  return ref.watch(errorHandlerProvider).errors;
});
