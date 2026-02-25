import 'package:shared_preferences/shared_preferences.dart';

/// Persists paired device IDs locally using SharedPreferences.
///
/// Key layout:
///   ble_paired_devices  →  JSON-like comma-separated list of device IDs
class PairingStorage {
  static const _kKey = 'ble_paired_devices';

  // ── Read ──────────────────────────────────────

  /// Returns the set of device IDs that have been saved as paired.
  static Future<Set<String>> loadPairedIds() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_kKey) ?? [];
    return raw.toSet();
  }

  /// Returns true if [deviceId] has been saved as paired.
  static Future<bool> isPaired(String deviceId) async {
    final ids = await loadPairedIds();
    return ids.contains(deviceId);
  }

  // ── Write ─────────────────────────────────────

  /// Mark [deviceId] as paired and persist it.
  static Future<void> savePaired(String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    final ids = (prefs.getStringList(_kKey) ?? []).toSet();
    ids.add(deviceId);
    await prefs.setStringList(_kKey, ids.toList());
  }

  /// Remove [deviceId] from the paired list.
  static Future<void> removePaired(String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    final ids = (prefs.getStringList(_kKey) ?? []).toSet();
    ids.remove(deviceId);
    await prefs.setStringList(_kKey, ids.toList());
  }

  /// Clear all stored paired device IDs.
  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kKey);
  }
}
