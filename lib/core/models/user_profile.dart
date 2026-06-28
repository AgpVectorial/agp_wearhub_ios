import 'package:flutter/foundation.dart';

/// Profil utilizator.
@immutable
class UserProfile {
  final int? id;
  final String username;
  final String displayName;
  final String? pinHash; // SHA-256 hash al PIN-ului
  final DateTime createdAt;
  final DateTime lastLoginAt;
  final bool isActive; // profilul curent

  // Date de profil suplimentare
  final int? age;
  final String? gender; // male, female, other
  final double? heightCm;
  final double? weightKg;
  final String? emergencyPhone;

  const UserProfile({
    this.id,
    required this.username,
    required this.displayName,
    this.pinHash,
    required this.createdAt,
    required this.lastLoginAt,
    this.isActive = false,
    this.age,
    this.gender,
    this.heightCm,
    this.weightKg,
    this.emergencyPhone,
  });

  UserProfile copyWith({
    int? id,
    String? username,
    String? displayName,
    String? pinHash,
    DateTime? createdAt,
    DateTime? lastLoginAt,
    bool? isActive,
    int? age,
    String? gender,
    double? heightCm,
    double? weightKg,
    String? emergencyPhone,
  }) => UserProfile(
    id: id ?? this.id,
    username: username ?? this.username,
    displayName: displayName ?? this.displayName,
    pinHash: pinHash ?? this.pinHash,
    createdAt: createdAt ?? this.createdAt,
    lastLoginAt: lastLoginAt ?? this.lastLoginAt,
    isActive: isActive ?? this.isActive,
    age: age ?? this.age,
    gender: gender ?? this.gender,
    heightCm: heightCm ?? this.heightCm,
    weightKg: weightKg ?? this.weightKg,
    emergencyPhone: emergencyPhone ?? this.emergencyPhone,
  );

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'username': username,
    'displayName': displayName,
    'pinHash': pinHash,
    'createdAt': createdAt.toUtc().millisecondsSinceEpoch,
    'lastLoginAt': lastLoginAt.toUtc().millisecondsSinceEpoch,
    'isActive': isActive ? 1 : 0,
    'age': age,
    'gender': gender,
    'heightCm': heightCm,
    'weightKg': weightKg,
    'emergencyPhone': emergencyPhone,
  };

  factory UserProfile.fromMap(Map<String, dynamic> m) => UserProfile(
    id: m['id'] as int?,
    username: m['username'] as String,
    displayName: (m['displayName'] as String?) ?? m['username'] as String,
    pinHash: m['pinHash'] as String?,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      m['createdAt'] as int,
      isUtc: true,
    ),
    lastLoginAt: DateTime.fromMillisecondsSinceEpoch(
      m['lastLoginAt'] as int,
      isUtc: true,
    ),
    isActive: (m['isActive'] as int?) == 1,
    age: m['age'] as int?,
    gender: m['gender'] as String?,
    heightCm: (m['heightCm'] as num?)?.toDouble(),
    weightKg: (m['weightKg'] as num?)?.toDouble(),
    emergencyPhone: m['emergencyPhone'] as String?,
  );

  /// Utilizatorul implicit (fără autentificare).
  static UserProfile defaultUser() => UserProfile(
    username: 'default',
    displayName: 'Default User',
    createdAt: DateTime.now().toUtc(),
    lastLoginAt: DateTime.now().toUtc(),
    isActive: true,
  );

  @override
  String toString() => 'UserProfile($username, active=$isActive)';
}
