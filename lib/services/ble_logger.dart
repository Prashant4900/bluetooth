import 'dart:async';
import 'dart:convert';

import 'package:bluetooth/models/ble_log_entry.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A simplified, statically accessible logger that combines memory caching
/// and SharedPreferences persistence into a single file.
class BleLogger {
  BleLogger._();

  static const _prefix = 'ble_log_';
  static const _hardMax = 1000;
  static const _maxAge = Duration(hours: 24);

  static final Map<String, List<BleLogEntry>> _deviceLogs = {};

  static final _logUpdateController = StreamController<String>.broadcast();

  /// Stream that emits the deviceId (or 'all') whenever logs are updated.
  static Stream<String> get onLogsUpdated => _logUpdateController.stream;

  /// Loads all stored logs into memory. Call this once during app startup.
  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((k) => k.startsWith(_prefix));
      final cutoff = DateTime.now().subtract(_maxAge);

      for (final key in keys) {
        final deviceId = key.replaceFirst(_prefix, '');
        final raw = prefs.getStringList(key) ?? [];
        final List<BleLogEntry> logs = [];

        for (final s in raw) {
          try {
            final entry = BleLogEntry.fromJson(
              jsonDecode(s) as Map<String, dynamic>,
            );
            if (entry.timestamp.isAfter(cutoff)) {
              logs.add(entry);
            }
          } catch (_) {}
        }

        if (logs.isNotEmpty) {
          _deviceLogs[deviceId] = logs;
        }
      }
      _logUpdateController.add('all');
    } catch (e) {
      debugPrint('[BleLogger] init error: $e');
    }
  }

  /// Adds a new log, caches it in memory, and appends it to SharedPreferences.
  static Future<void> addLog(BleLogEntry entry) async {
    final list = _deviceLogs.putIfAbsent(entry.deviceId, () => []);

    // Deduplication check: ignore if the exact same message was logged <1s ago
    if (list.isNotEmpty) {
      final lastLog = list.last;
      if (lastLog.message == entry.message &&
          entry.timestamp.difference(lastLog.timestamp).inMilliseconds < 1000) {
        return;
      }
    }

    // Add to memory and enforce max limit
    list.add(entry);
    if (list.length > _hardMax) {
      _deviceLogs[entry.deviceId] = list.sublist(list.length - _hardMax);
    }

    _logUpdateController.add(entry.deviceId);
    _logUpdateController.add('all');

    // Persist to SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = '$_prefix${entry.deviceId}';
      final raw = _deviceLogs[entry.deviceId]!
          .map((e) => jsonEncode(e.toJson()))
          .toList();
      await prefs.setStringList(key, raw);
    } catch (e) {
      debugPrint('[BleLogger] addLog error: $e');
    }
  }

  /// Returns all combined logs from memory, sorted chronologically.
  static List<BleLogEntry> get allLogs {
    final all = <BleLogEntry>[];
    for (final logs in _deviceLogs.values) {
      all.addAll(logs);
    }
    all.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return all;
  }
}
