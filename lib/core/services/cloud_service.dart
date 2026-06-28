import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/metric.dart';

/// Status sincronizare cloud.
enum CloudSyncStatus { idle, syncing, synced, error }

/// Starea serviciului cloud.
@immutable
class CloudState {
  final CloudSyncStatus syncStatus;
  final DateTime? lastSyncTime;
  final int pendingUploads;
  final bool backupEnabled;
  final bool remoteAccessEnabled;
  final bool serverNotificationsEnabled;
  final String? lastError;

  const CloudState({
    this.syncStatus = CloudSyncStatus.idle,
    this.lastSyncTime,
    this.pendingUploads = 0,
    this.backupEnabled = false,
    this.remoteAccessEnabled = false,
    this.serverNotificationsEnabled = false,
    this.lastError,
  });

  CloudState copyWith({
    CloudSyncStatus? syncStatus,
    DateTime? lastSyncTime,
    int? pendingUploads,
    bool? backupEnabled,
    bool? remoteAccessEnabled,
    bool? serverNotificationsEnabled,
    String? lastError,
  }) => CloudState(
    syncStatus: syncStatus ?? this.syncStatus,
    lastSyncTime: lastSyncTime ?? this.lastSyncTime,
    pendingUploads: pendingUploads ?? this.pendingUploads,
    backupEnabled: backupEnabled ?? this.backupEnabled,
    remoteAccessEnabled: remoteAccessEnabled ?? this.remoteAccessEnabled,
    serverNotificationsEnabled:
        serverNotificationsEnabled ?? this.serverNotificationsEnabled,
    lastError: lastError ?? this.lastError,
  );
}

/// Shared access entry – familie sau medic.
@immutable
class SharedAccessEntry {
  final String id;
  final String name;
  final String role; // 'family' | 'doctor'
  final String email;
  final bool isActive;
  final DateTime grantedAt;

  const SharedAccessEntry({
    required this.id,
    required this.name,
    required this.role,
    required this.email,
    this.isActive = true,
    required this.grantedAt,
  });
}

/// Server-side notification config.
@immutable
class ServerNotificationRule {
  final String id;
  final MetricType metricType;
  final double threshold;
  final bool isAbove; // true = alert when above, false = when below
  final bool enabled;
  final List<String> recipients; // email/push tokens

  const ServerNotificationRule({
    required this.id,
    required this.metricType,
    required this.threshold,
    required this.isAbove,
    this.enabled = true,
    this.recipients = const [],
  });
}

/// Mock cloud service – totul e simulat local.
class CloudService extends StateNotifier<CloudState> {
  CloudService() : super(const CloudState());

  // ── Mock shared access list ──
  final List<SharedAccessEntry> _sharedAccess = [
    SharedAccessEntry(
      id: 'sa_1',
      name: 'Dr. Ionescu',
      role: 'doctor',
      email: 'dr.ionescu@mock.ro',
      grantedAt: DateTime.now().subtract(const Duration(days: 30)),
    ),
    SharedAccessEntry(
      id: 'sa_2',
      name: 'Maria (soție)',
      role: 'family',
      email: 'maria@mock.ro',
      grantedAt: DateTime.now().subtract(const Duration(days: 15)),
    ),
  ];

  // ── Mock notification rules ──
  final List<ServerNotificationRule> _notificationRules = [
    const ServerNotificationRule(
      id: 'nr_1',
      metricType: MetricType.heartRate,
      threshold: 180,
      isAbove: true,
      recipients: ['dr.ionescu@mock.ro'],
    ),
    const ServerNotificationRule(
      id: 'nr_2',
      metricType: MetricType.spo2,
      threshold: 90,
      isAbove: false,
      recipients: ['dr.ionescu@mock.ro', 'maria@mock.ro'],
    ),
  ];

  List<SharedAccessEntry> get sharedAccess => List.unmodifiable(_sharedAccess);

  List<ServerNotificationRule> get notificationRules =>
      List.unmodifiable(_notificationRules);

  /// Mock: pornire sincronizare cloud.
  Future<void> syncNow() async {
    state = state.copyWith(syncStatus: CloudSyncStatus.syncing);
    // Simulăm latența
    await Future.delayed(const Duration(seconds: 2));
    state = state.copyWith(
      syncStatus: CloudSyncStatus.synced,
      lastSyncTime: DateTime.now(),
      pendingUploads: 0,
    );
    debugPrint('[CloudService] Mock sync complete');
  }

  /// Mock: backup complet.
  Future<void> createBackup() async {
    state = state.copyWith(syncStatus: CloudSyncStatus.syncing);
    await Future.delayed(const Duration(seconds: 3));
    state = state.copyWith(
      syncStatus: CloudSyncStatus.synced,
      lastSyncTime: DateTime.now(),
      backupEnabled: true,
    );
    debugPrint('[CloudService] Mock backup created');
  }

  /// Toggle backup automat.
  void setBackupEnabled(bool enabled) {
    state = state.copyWith(backupEnabled: enabled);
  }

  /// Toggle acces remote.
  void setRemoteAccessEnabled(bool enabled) {
    state = state.copyWith(remoteAccessEnabled: enabled);
  }

  /// Toggle notificări server-side.
  void setServerNotifications(bool enabled) {
    state = state.copyWith(serverNotificationsEnabled: enabled);
  }

  /// Mock: adăugare acces partajat.
  void addSharedAccess({
    required String name,
    required String role,
    required String email,
  }) {
    _sharedAccess.add(
      SharedAccessEntry(
        id: 'sa_${DateTime.now().millisecondsSinceEpoch}',
        name: name,
        role: role,
        email: email,
        grantedAt: DateTime.now(),
      ),
    );
    state = state.copyWith(); // trigger rebuild
  }

  /// Mock: revocare acces partajat.
  void revokeSharedAccess(String id) {
    _sharedAccess.removeWhere((e) => e.id == id);
    state = state.copyWith();
  }

  /// Mock: upload metrici (apelat periodic din background).
  Future<void> uploadMetrics(List<Metric> metrics) async {
    if (metrics.isEmpty) return;
    state = state.copyWith(
      pendingUploads: state.pendingUploads + metrics.length,
    );
    await Future.delayed(const Duration(milliseconds: 500));
    state = state.copyWith(pendingUploads: 0);
    debugPrint('[CloudService] Mock uploaded ${metrics.length} metrics');
  }
}

final cloudServiceProvider = StateNotifierProvider<CloudService, CloudState>(
  (ref) => CloudService(),
);
