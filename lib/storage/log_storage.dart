import 'dart:convert';

import 'package:bluetooth/models/ble_log_entry.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists BLE log entries per device in SharedPreferences.
///
/// Storage key:  `ble_log_{deviceId}` → JSON-encoded list of entries
/// Retention:    Max 1 000 entries per device; entries older than 24 h are
///               dropped automatically when loading.
class LogStorage {
  LogStorage._();

  static const _prefix = 'ble_log_';
  static const _maxEntries = 1000;
  static const _maxAge = Duration(hours: 24);

  static String _key(String deviceId) => '$_prefix$deviceId';

  // ── Read ─────────────────────────────────────────────────────────────────

  /// Loads log entries for [deviceId], discarding anything older than 24 h.
  static Future<List<BleLogEntry>> loadLogs(String deviceId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_key(deviceId)) ?? [];
      final cutoff = DateTime.now().subtract(_maxAge);

      return raw
          .map((s) {
            try {
              return BleLogEntry.fromJson(
                jsonDecode(s) as Map<String, dynamic>,
              );
            } catch (_) {
              return null; // skip corrupted entries
            }
          })
          .whereType<BleLogEntry>()
          .where((e) => e.timestamp.isAfter(cutoff))
          .toList();
    } catch (e) {
      debugPrint('[LogStorage] loadLogs error: $e');
      return [];
    }
  }

  // ── Write ────────────────────────────────────────────────────────────────

  /// Appends [entry] to its device log, pruning to [_maxEntries] if needed.
  static Future<void> appendLog(BleLogEntry entry) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _key(entry.deviceId);
      final raw = prefs.getStringList(key) ?? [];

      raw.add(jsonEncode(entry.toJson()));

      // Keep only the most recent entries when the limit is exceeded.
      final trimmed = raw.length > _maxEntries
          ? raw.sublist(raw.length - _maxEntries)
          : raw;

      await prefs.setStringList(key, trimmed);
    } catch (e) {
      debugPrint('[LogStorage] appendLog error: $e');
    }
  }

  // ── Query ────────────────────────────────────────────────────────────────

  /// Returns device IDs that have at least one stored log entry.
  static Future<List<String>> getDevicesWithLogs() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs
        .getKeys()
        .where((k) => k.startsWith(_prefix))
        .map((k) => k.replaceFirst(_prefix, ''))
        .toList();
  }
}
