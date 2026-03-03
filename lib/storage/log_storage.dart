import 'dart:convert';

import 'package:bluetooth/models/ble_log_entry.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists BLE log entries per device using SharedPreferences.
///
/// Storage layout:
///   ble_log_{deviceId}  →  JSON-encoded List of BleLogEntry objects
///
/// Retention policy:
///   • Hard max: 1000 entries per device (oldest pruned first)
///   • Time max: 24 hours (entries older than this are removed on load)
class LogStorage {
  static const _prefix = 'ble_log_';
  static const _hardMax = 1000;
  static const _maxAge = Duration(hours: 24);

  static String _key(String deviceId) => '$_prefix$deviceId';

  // ── Load ──────────────────────────────────────

  /// Load all persisted log entries for [deviceId].
  /// Entries older than 24 hours are automatically discarded.
  static Future<List<BleLogEntry>> loadLogs(String deviceId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_key(deviceId)) ?? [];
      final cutoff = DateTime.now().subtract(_maxAge);
      final List<BleLogEntry> logs = [];
      for (final s in raw) {
        try {
          final entry = BleLogEntry.fromJson(
            jsonDecode(s) as Map<String, dynamic>,
          );
          if (entry.timestamp.isAfter(cutoff)) {
            logs.add(entry);
          }
        } catch (_) {
          // Skip corrupted entries.
        }
      }
      return logs;
    } catch (e) {
      debugPrint('[LogStorage] loadLogs error: $e');
      return [];
    }
  }

  // ── Append ────────────────────────────────────

  /// Append [entry] to the log for its device.
  /// Automatically prunes to [_hardMax] entries if exceeded.
  static Future<void> appendLog(BleLogEntry entry) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _key(entry.deviceId);
      final raw = prefs.getStringList(key) ?? [];

      raw.add(jsonEncode(entry.toJson()));

      final pruned = raw.length > _hardMax
          ? raw.sublist(raw.length - _hardMax)
          : raw;

      await prefs.setStringList(key, pruned);
    } catch (e) {
      debugPrint('[LogStorage] appendLog error: $e');
    }
  }

  // ── Query ─────────────────────────────────────

  /// Get a list of all device IDs that currently have stored logs.
  static Future<List<String>> getDevicesWithLogs() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith(_prefix)).toList();
    return keys.map((k) => k.replaceFirst(_prefix, '')).toList();
  }
}
