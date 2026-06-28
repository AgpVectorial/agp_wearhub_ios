import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/vitals.dart';
import 'qc_sdk_service.dart';

abstract class SdkService {
  Future<void> startHeartRateNotifications(String deviceId);
  Future<void> stopHeartRateNotifications(String deviceId);
  Stream<VitalSample<int>> heartRateStream(String deviceId);

  Future<void> startSpO2Notifications(String deviceId);
  Future<void> stopSpO2Notifications(String deviceId);
  Stream<VitalSample<int>> spO2Stream(String deviceId);

  Future<void> startTemperatureNotifications(String deviceId);
  Future<void> stopTemperatureNotifications(String deviceId);
  Stream<VitalSample<double>> temperatureStream(String deviceId);

  Future<void> startStepsNotifications(String deviceId);
  Future<void> stopStepsNotifications(String deviceId);
  Stream<VitalSample<int>> stepsStream(String deviceId);

  Future<void> startBatteryNotifications(String deviceId);
  Future<void> stopBatteryNotifications(String deviceId);
  Stream<VitalSample<int>> batteryStream(String deviceId);

  Future<void> startHrvNotifications(String deviceId);
  Future<void> stopHrvNotifications(String deviceId);
  Stream<VitalSample<int>> hrvStream(String deviceId);

  Future<void> startBloodPressureNotifications(String deviceId);
  Future<void> stopBloodPressureNotifications(String deviceId);
  Stream<VitalSample<BloodPressure>> bloodPressureStream(String deviceId);

  Stream<VitalSample<int>> stressStream(String deviceId);

  /// Start sequential vital rotation — cycles through [vitals] with per-vital
  /// measurement durations from [intervals] (in seconds). Only one manual mode
  /// is active at a time on the bracelet.
  Future<void> startVitalRotation(
    String deviceId,
    List<String> vitals,
    Map<String, int> intervals,
  );

  /// Stop the running vital rotation.
  Future<void> stopVitalRotation(String deviceId);

  /// Stream that emits which vital key is currently being measured ('' when idle).
  Stream<String> get activeVitalStream;

  /// Whether a vital rotation is currently running.
  bool get isRotating;

  /// The device ID currently being rotated (null if idle).
  String? get rotationDeviceId;

  /// Sync sleep data from bracelet. Returns a map with sleep info or null.
  Future<Map<String, dynamic>?> syncSleep();

  // Action features
  Future<bool> findDevice();
  Future<bool> enterCamera();
  Future<bool> exitCamera();
  Future<void> disconnect();
  Future<bool> setCallReminder(bool enable);
  Future<bool> isNotificationAccessEnabled();
  Future<void> openNotificationAccessSettings();
  Future<bool> setSedentaryReminder({
    required bool enable,
    int interval = 60,
    int startHour = 9,
    int startMinute = 0,
    int endHour = 18,
    int endMinute = 0,
  });
  Future<bool> setDnd({
    required bool enable,
    int startHour = 22,
    int startMinute = 0,
    int endHour = 7,
    int endMinute = 0,
  });
  Future<bool> setAlarm({
    required int index,
    required bool enable,
    required int hour,
    required int minute,
    int weekMask = 0x7F,
  });
}

/// Provider-ul principal SDK — mereu QcSdkService (real singleton).
final sdkProvider = Provider<SdkService>((ref) {
  return QcSdkService();
});
