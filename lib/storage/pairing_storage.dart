import 'package:shared_preferences/shared_preferences.dart';

/// Persists the set of paired device IDs in SharedPreferences.
///
/// Storage key:  `ble_paired_devices` → List<String> of device IDs
class PairingStorage {
  PairingStorage._();

  static const _key = 'ble_paired_devices';

  // ── Read ─────────────────────────────────────────────────────────────────

  static Future<Set<String>> loadPairedIds() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_key) ?? []).toSet();
  }

  // ── Write ────────────────────────────────────────────────────────────────

  static Future<void> savePaired(String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    final ids = (prefs.getStringList(_key) ?? []).toSet()..add(deviceId);
    await prefs.setStringList(_key, ids.toList());
  }

  static Future<void> removePaired(String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    final ids = (prefs.getStringList(_key) ?? []).toSet()..remove(deviceId);
    await prefs.setStringList(_key, ids.toList());
  }
}
