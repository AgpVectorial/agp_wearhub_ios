import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Eveniment de audit pentru acces date.
@immutable
class AuditEntry {
  final String id;
  final DateTime timestamp;
  final String action; // 'view' | 'export' | 'share' | 'delete'
  final String userId;
  final String? targetMetric;
  final String? details;

  const AuditEntry({
    required this.id,
    required this.timestamp,
    required this.action,
    required this.userId,
    this.targetMetric,
    this.details,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'timestamp': timestamp.toIso8601String(),
    'action': action,
    'userId': userId,
    'targetMetric': targetMetric,
    'details': details,
  };
}

/// Starea securității.
@immutable
class SecurityState {
  final bool localEncryptionEnabled;
  final bool metricsAccessProtection;
  final bool auditEnabled;
  final bool gdprConsentGiven;
  final DateTime? gdprConsentDate;
  final DateTime? lastDataExportRequest;
  final DateTime? lastDataDeletionRequest;

  const SecurityState({
    this.localEncryptionEnabled = true,
    this.metricsAccessProtection = true,
    this.auditEnabled = true,
    this.gdprConsentGiven = false,
    this.gdprConsentDate,
    this.lastDataExportRequest,
    this.lastDataDeletionRequest,
  });

  SecurityState copyWith({
    bool? localEncryptionEnabled,
    bool? metricsAccessProtection,
    bool? auditEnabled,
    bool? gdprConsentGiven,
    DateTime? gdprConsentDate,
    DateTime? lastDataExportRequest,
    DateTime? lastDataDeletionRequest,
  }) => SecurityState(
    localEncryptionEnabled:
        localEncryptionEnabled ?? this.localEncryptionEnabled,
    metricsAccessProtection:
        metricsAccessProtection ?? this.metricsAccessProtection,
    auditEnabled: auditEnabled ?? this.auditEnabled,
    gdprConsentGiven: gdprConsentGiven ?? this.gdprConsentGiven,
    gdprConsentDate: gdprConsentDate ?? this.gdprConsentDate,
    lastDataExportRequest: lastDataExportRequest ?? this.lastDataExportRequest,
    lastDataDeletionRequest:
        lastDataDeletionRequest ?? this.lastDataDeletionRequest,
  );
}

/// Serviciu mock de securitate.
class SecurityService extends StateNotifier<SecurityState> {
  SecurityService() : super(const SecurityState()) {
    _load();
  }

  final List<AuditEntry> _auditLog = [];
  static const _kEncryption = 'sec.encryption';
  static const _kAccessProtection = 'sec.access_protection';
  static const _kAudit = 'sec.audit';
  static const _kGdprConsent = 'sec.gdpr_consent';
  static const _kGdprDate = 'sec.gdpr_date';

  List<AuditEntry> get auditLog => List.unmodifiable(_auditLog);

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    state = SecurityState(
      localEncryptionEnabled: p.getBool(_kEncryption) ?? true,
      metricsAccessProtection: p.getBool(_kAccessProtection) ?? true,
      auditEnabled: p.getBool(_kAudit) ?? true,
      gdprConsentGiven: p.getBool(_kGdprConsent) ?? false,
      gdprConsentDate: p.getString(_kGdprDate) != null
          ? DateTime.tryParse(p.getString(_kGdprDate)!)
          : null,
    );
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kEncryption, state.localEncryptionEnabled);
    await p.setBool(_kAccessProtection, state.metricsAccessProtection);
    await p.setBool(_kAudit, state.auditEnabled);
    await p.setBool(_kGdprConsent, state.gdprConsentGiven);
    if (state.gdprConsentDate != null) {
      await p.setString(_kGdprDate, state.gdprConsentDate!.toIso8601String());
    }
  }

  /// Mock: criptare date locale (simulare AES-256).
  String encryptData(String plainText) {
    if (!state.localEncryptionEnabled) return plainText;
    // Mock – doar base64 + hash prefix ca indicator vizual
    final hash = sha256
        .convert(utf8.encode(plainText))
        .toString()
        .substring(0, 8);
    final encoded = base64Encode(utf8.encode(plainText));
    debugPrint('[SecurityService] Mock encrypted ${plainText.length} chars');
    return 'ENC:$hash:$encoded';
  }

  /// Mock: decriptare.
  String decryptData(String cipherText) {
    if (!cipherText.startsWith('ENC:')) return cipherText;
    final parts = cipherText.split(':');
    if (parts.length < 3) return cipherText;
    return utf8.decode(base64Decode(parts[2]));
  }

  /// Toggle criptare locală.
  void setEncryption(bool enabled) {
    state = state.copyWith(localEncryptionEnabled: enabled);
    _save();
    _addAudit('config', details: 'encryption=${enabled ? "on" : "off"}');
  }

  /// Toggle protecție acces metrici.
  void setAccessProtection(bool enabled) {
    state = state.copyWith(metricsAccessProtection: enabled);
    _save();
    _addAudit('config', details: 'access_protection=${enabled ? "on" : "off"}');
  }

  /// Toggle audit.
  void setAuditEnabled(bool enabled) {
    state = state.copyWith(auditEnabled: enabled);
    _save();
  }

  /// GDPR: Acordă consimțământul.
  void giveGdprConsent() {
    state = state.copyWith(
      gdprConsentGiven: true,
      gdprConsentDate: DateTime.now(),
    );
    _save();
    _addAudit('gdpr_consent', details: 'consent given');
  }

  /// GDPR: Retrage consimțământul.
  void revokeGdprConsent() {
    state = state.copyWith(gdprConsentGiven: false);
    _save();
    _addAudit('gdpr_consent', details: 'consent revoked');
  }

  /// GDPR: Cerere export date (Art. 20).
  Future<void> requestDataExport() async {
    _addAudit('export', details: 'GDPR data export requested');
    await Future.delayed(const Duration(seconds: 1));
    state = state.copyWith(lastDataExportRequest: DateTime.now());
    debugPrint('[SecurityService] Mock GDPR data export generated');
  }

  /// GDPR: Cerere ștergere date (Art. 17 – Right to be forgotten).
  Future<void> requestDataDeletion() async {
    _addAudit('delete', details: 'GDPR data deletion requested');
    await Future.delayed(const Duration(seconds: 1));
    state = state.copyWith(lastDataDeletionRequest: DateTime.now());
    debugPrint('[SecurityService] Mock GDPR data deletion processed');
  }

  /// Adaugă o intrare de audit.
  void logAccess({
    required String userId,
    required String action,
    String? targetMetric,
    String? details,
  }) {
    if (!state.auditEnabled) return;
    _auditLog.add(
      AuditEntry(
        id: 'audit_${DateTime.now().millisecondsSinceEpoch}',
        timestamp: DateTime.now(),
        action: action,
        userId: userId,
        targetMetric: targetMetric,
        details: details,
      ),
    );
    if (_auditLog.length > 200) _auditLog.removeAt(0);
  }

  void _addAudit(String action, {String? details}) {
    logAccess(userId: 'system', action: action, details: details);
  }
}

final securityServiceProvider =
    StateNotifierProvider<SecurityService, SecurityState>(
      (ref) => SecurityService(),
    );
