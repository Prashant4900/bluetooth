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
///   • Hard max:  1000 entries per device (oldest pruned first)
///   • Time max:  24 hours (entries older than this are removed on load)
///   • Minimum guarantee: at least the last 30 minutes are always kept
///     (i.e. time-based pruning never removes entries newer than 30 min)
class LogStorage {
  static const _prefix = 'ble_log_';
  static const _hardMax = 1000;
  static const _maxAge = Duration(hours: 24);

  static String _key(String deviceId) => '$_prefix$deviceId';

  // ── Load ──────────────────────────────────────

  /// Load all persisted log entries for [deviceId].
  /// Entries older than [_maxAge] are discarded (unless they are within
  /// the last 30 minutes, which are always preserved).
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
          // Skip corrupted entries
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

      // Prune oldest if we exceed the hard max
      final pruned = raw.length > _hardMax
          ? raw.sublist(raw.length - _hardMax)
          : raw;

      await prefs.setStringList(key, pruned);
    } catch (e) {
      debugPrint('[LogStorage] appendLog error: $e');
    }
  }

  /// Append multiple [entries] in a single write (efficient batch).
  static Future<void> appendLogs(List<BleLogEntry> entries) async {
    if (entries.isEmpty) return;
    // Group by deviceId for minimal writes
    final byDevice = <String, List<BleLogEntry>>{};
    for (final e in entries) {
      byDevice.putIfAbsent(e.deviceId, () => []).add(e);
    }
    final prefs = await SharedPreferences.getInstance();
    for (final kv in byDevice.entries) {
      final key = _key(kv.key);
      final existing = prefs.getStringList(key) ?? [];
      existing.addAll(kv.value.map((e) => jsonEncode(e.toJson())));
      final pruned = existing.length > _hardMax
          ? existing.sublist(existing.length - _hardMax)
          : existing;
      await prefs.setStringList(key, pruned);
    }
  }

  // ── Clear ─────────────────────────────────────

  /// Clear all logs for [deviceId].
  static Future<void> clearLogs(String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(deviceId));
  }

  /// Clear logs for every known device.
  static Future<void> clearAllLogs() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith(_prefix)).toList();
    for (final k in keys) {
      await prefs.remove(k);
    }
  }

  // ── Stats ─────────────────────────────────────

  /// Returns the number of stored entries for [deviceId] without loading them.
  static Future<int> entryCount(String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_key(deviceId)) ?? []).length;
  }
}
