import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../models/user_profile.dart';
import '../errors/app_error.dart';

/// Repository pentru gestionarea utilizatorilor.
///
/// Funcționalități:
/// - CRUD profiluri
/// - Autentificare prin PIN
/// - Schimbare utilizator activ
/// - Separarea datelor pe utilizator (prin userId)
class UserRepository {
  static const _dbName = 'users.db';
  static const _table = 'users';
  static const _version = 1;

  Database? _db;
  static UserRepository? _instance;

  UserRepository._();
  factory UserRepository() => _instance ??= UserRepository._();

  Future<Database> get database async {
    if (_db != null) return _db!;
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, _dbName);
    _db = await openDatabase(
      path,
      version: _version,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_table (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT NOT NULL UNIQUE,
            displayName TEXT NOT NULL,
            pinHash TEXT,
            createdAt INTEGER NOT NULL,
            lastLoginAt INTEGER NOT NULL,
            isActive INTEGER NOT NULL DEFAULT 0,
            age INTEGER,
            gender TEXT,
            heightCm REAL,
            weightKg REAL,
            emergencyPhone TEXT
          )
        ''');
        await db.execute(
          'CREATE UNIQUE INDEX idx_username ON $_table (username)',
        );
      },
    );
    return _db!;
  }

  /// Hash PIN cu SHA-256 + salt bazat pe username.
  String _hashPin(String pin, String username) {
    final salted = '$username:$pin';
    return sha256.convert(utf8.encode(salted)).toString();
  }

  /// Creează un utilizator nou.
  Future<UserProfile> createUser({
    required String username,
    required String displayName,
    String? pin,
    int? age,
    String? gender,
    double? heightCm,
    double? weightKg,
    String? emergencyPhone,
  }) async {
    final db = await database;
    final now = DateTime.now().toUtc();
    final pinHash = pin != null ? _hashPin(pin, username) : null;

    final profile = UserProfile(
      username: username,
      displayName: displayName,
      pinHash: pinHash,
      createdAt: now,
      lastLoginAt: now,
      isActive: false,
      age: age,
      gender: gender,
      heightCm: heightCm,
      weightKg: weightKg,
      emergencyPhone: emergencyPhone,
    );

    final id = await db.insert(_table, profile.toMap());
    return profile.copyWith(id: id);
  }

  /// Autentifică un utilizator prin PIN.
  /// Returnează profilul dacă PIN-ul e corect, null altfel.
  Future<UserProfile?> authenticate(String username, String pin) async {
    final db = await database;
    final rows = await db.query(
      _table,
      where: 'username = ?',
      whereArgs: [username],
      limit: 1,
    );

    if (rows.isEmpty) {
      ErrorHandler.instance.report(
        AppError(
          code: AppErrorCode.userNotFound,
          message: 'User not found: $username',
        ),
      );
      return null;
    }

    final user = UserProfile.fromMap(rows.first);
    if (user.pinHash == null) {
      // Utilizator fără PIN → acces direct
      return user;
    }

    final hash = _hashPin(pin, username);
    if (hash != user.pinHash) {
      ErrorHandler.instance.report(
        AppError(
          code: AppErrorCode.pinIncorrect,
          message: 'Incorrect PIN for user: $username',
        ),
      );
      return null;
    }

    // Update last login
    await db.update(
      _table,
      {'lastLoginAt': DateTime.now().toUtc().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [user.id],
    );

    return user.copyWith(lastLoginAt: DateTime.now().toUtc());
  }

  /// Schimbă utilizatorul activ.
  Future<void> setActiveUser(int userId) async {
    final db = await database;
    await db.transaction((txn) async {
      // Dezactivează toți utilizatorii
      await txn.update(_table, {'isActive': 0});
      // Activează utilizatorul selectat
      await txn.update(
        _table,
        {
          'isActive': 1,
          'lastLoginAt': DateTime.now().toUtc().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [userId],
      );
    });
  }

  /// Returnează utilizatorul activ (sau null dacă nu e nimeni logat).
  Future<UserProfile?> getActiveUser() async {
    final db = await database;
    final rows = await db.query(_table, where: 'isActive = 1', limit: 1);
    if (rows.isEmpty) return null;
    return UserProfile.fromMap(rows.first);
  }

  /// Returnează toți utilizatorii.
  Future<List<UserProfile>> getAllUsers() async {
    final db = await database;
    final rows = await db.query(_table, orderBy: 'displayName ASC');
    return rows.map(UserProfile.fromMap).toList();
  }

  /// Returnează un utilizator după ID.
  Future<UserProfile?> getUserById(int id) async {
    final db = await database;
    final rows = await db.query(
      _table,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return UserProfile.fromMap(rows.first);
  }

  /// Actualizează profilul unui utilizator.
  Future<void> updateUser(UserProfile user) async {
    if (user.id == null) return;
    final db = await database;
    await db.update(
      _table,
      user.toMap(),
      where: 'id = ?',
      whereArgs: [user.id],
    );
  }

  /// Schimbă PIN-ul unui utilizator.
  Future<bool> changePin(int userId, String? oldPin, String newPin) async {
    final user = await getUserById(userId);
    if (user == null) return false;

    // Verifică PIN-ul vechi (dacă exista)
    if (user.pinHash != null && oldPin != null) {
      final hash = _hashPin(oldPin, user.username);
      if (hash != user.pinHash) return false;
    }

    final newHash = _hashPin(newPin, user.username);
    final db = await database;
    await db.update(
      _table,
      {'pinHash': newHash},
      where: 'id = ?',
      whereArgs: [userId],
    );
    return true;
  }

  /// Șterge un utilizator (cu confirmare implicită din UI).
  Future<void> deleteUser(int userId) async {
    final db = await database;
    await db.delete(_table, where: 'id = ?', whereArgs: [userId]);
  }

  /// Verifică dacă există cel puțin un utilizator.
  Future<bool> hasUsers() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) as cnt FROM $_table');
    return ((result.first['cnt'] as int?) ?? 0) > 0;
  }

  /// Asigură că există un utilizator implicit la prima rulare.
  Future<UserProfile> ensureDefaultUser() async {
    final active = await getActiveUser();
    if (active != null) return active;

    final users = await getAllUsers();
    if (users.isNotEmpty) {
      await setActiveUser(users.first.id!);
      return users.first.copyWith(isActive: true);
    }

    // Crează utilizatorul implicit
    final user = await createUser(
      username: 'default',
      displayName: 'Default User',
    );
    await setActiveUser(user.id!);
    return user.copyWith(isActive: true);
  }
}

// ──────────────────────────────────────────
//  Providers Riverpod
// ──────────────────────────────────────────

final userRepositoryProvider = Provider<UserRepository>(
  (_) => UserRepository(),
);

/// State-ul curent al sesiunii de utilizator.
class UserSession extends StateNotifier<UserProfile?> {
  final UserRepository _repo;
  bool _initialized = false;
  bool get initialized => _initialized;

  UserSession(this._repo) : super(null) {
    _init();
  }

  Future<void> _init() async {
    // Nu setăm state din DB — LoginPage apare mereu la pornire.
    // Datele rămân în DB, utilizatorul trebuie să se autentifice din nou.
    state = null;
    _initialized = true;
  }

  /// ID-ul utilizatorului activ.
  String get userId => state?.id?.toString() ?? 'default';
  String get displayName => state?.displayName ?? 'User';

  /// Autentifică și setează utilizatorul activ.
  Future<bool> login(String username, String pin) async {
    final user = await _repo.authenticate(username, pin);
    if (user == null) return false;
    await _repo.setActiveUser(user.id!);
    state = user.copyWith(isActive: true);
    await _syncProfileToPrefs(state!);
    return true;
  }

  /// Login fără PIN (pentru utilizatori fără PIN setat).
  Future<bool> loginWithoutPin(String username) async {
    final users = await _repo.getAllUsers();
    final user = users.where((u) => u.username == username).firstOrNull;
    if (user == null) return false;
    if (user.pinHash != null) return false; // necesită PIN

    await _repo.setActiveUser(user.id!);
    state = user.copyWith(isActive: true);
    await _syncProfileToPrefs(state!);
    return true;
  }

  /// Schimbă pe alt utilizator (cu re-autentificare).
  Future<bool> switchUser(int userId, {String? pin}) async {
    final user = await _repo.getUserById(userId);
    if (user == null) return false;

    if (user.pinHash != null) {
      if (pin == null) return false;
      final authed = await _repo.authenticate(user.username, pin);
      if (authed == null) return false;
    }

    await _repo.setActiveUser(userId);
    state = user.copyWith(isActive: true, lastLoginAt: DateTime.now().toUtc());
    await _syncProfileToPrefs(state!);
    return true;
  }

  /// Deconectare utilizator curent.
  Future<void> logout() async {
    state = null;
  }

  /// Reîncarcă profilul activ din DB.
  Future<void> refresh() async {
    state = await _repo.getActiveUser();
    if (state != null) await _syncProfileToPrefs(state!);
  }

  /// Sincronizează datele de profil din UserProfile → SharedPreferences
  /// astfel încât SettingsController să afișeze datele corecte.
  Future<void> _syncProfileToPrefs(UserProfile user) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('user.name', user.displayName);
    if (user.age != null) {
      await p.setInt('user.age', user.age!);
    } else {
      await p.remove('user.age');
    }
    if (user.weightKg != null) {
      await p.setDouble('user.weight', user.weightKg!);
    } else {
      await p.remove('user.weight');
    }
    if (user.heightCm != null) {
      await p.setDouble('user.height', user.heightCm!);
    } else {
      await p.remove('user.height');
    }
    if (user.emergencyPhone != null) {
      await p.setString('user.emergency_phone', user.emergencyPhone!);
    } else {
      await p.remove('user.emergency_phone');
    }
  }
}

final userSessionProvider = StateNotifierProvider<UserSession, UserProfile?>(
  (ref) => UserSession(ref.watch(userRepositoryProvider)),
);

/// True când sesiunea s-a inițializat (a verificat dacă există utilizator activ).
final sessionInitializedProvider = StateProvider<bool>((_) => false);
