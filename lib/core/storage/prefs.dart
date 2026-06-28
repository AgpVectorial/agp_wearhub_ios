import 'package:shared_preferences/shared_preferences.dart';

class Prefs {
  static const _keyAdapter = 'adapter_kind';
  static const _keyLastDevice = 'last_device';

  static Future<void> saveAdapter(String adapter) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyAdapter, adapter);
  }

  static Future<String?> getAdapter() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyAdapter);
  }

  static Future<void> saveLastDevice(String id) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyLastDevice, id);
  }

  static Future<String?> getLastDevice() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keyLastDevice);
  }

  // ---------- Device Display Name ----------
  static String _nameKey(String deviceId) => 'device_name_$deviceId';

  static Future<void> saveDeviceName(String deviceId, String name) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_nameKey(deviceId), name);
  }

  static Future<String?> getDeviceName(String deviceId) async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_nameKey(deviceId));
  }


  // ---------- Generic helpers ----------
  static Future<void> setBool(String key, bool value) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(key, value);
  }

  static Future<bool?> getBool(String key) async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(key);
  }

  static Future<void> setInt(String key, int value) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(key, value);
  }

  static Future<int?> getInt(String key) async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(key);
  }

  static Future<void> setString(String key, String value) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(key, value);
  }

  static Future<String?> getString(String key) async {
    final p = await SharedPreferences.getInstance();
    return p.getString(key);
  }

}
