import 'dart:async';

import 'package:bluetooth/models/ble_log_entry.dart';
import 'package:bluetooth/storage/log_storage.dart';

/// Central repository for managing BLE logs in memory and delegating to persistent storage.
class BleLogRepository {
  /// Per-device in-memory log buffer.
  final Map<String, List<BleLogEntry>> _deviceLogs = {};

  final _logUpdateController = StreamController<String>.broadcast();

  /// Stream that emits the deviceId (or 'all') whenever logs are updated.
  Stream<String> get onLogsUpdated => _logUpdateController.stream;

  /// Adds [entry] to the in-memory buffer, persists it, and broadcasts the update.
  Future<void> addLog(BleLogEntry entry) async {
    final list = _deviceLogs.putIfAbsent(entry.deviceId, () => []);

    // Deduplication check: ignore if the exact same message was logged <1s ago
    if (list.isNotEmpty) {
      final lastLog = list.last;
      if (lastLog.message == entry.message &&
          entry.timestamp.difference(lastLog.timestamp).inMilliseconds < 1000) {
        return;
      }
    }

    list.add(entry);
    _logUpdateController.add(entry.deviceId);
    _logUpdateController.add('all');
    LogStorage.appendLog(entry).ignore();
  }

  /// Loads persisted logs for [deviceId], merges with in-memory entries, and broadcasts.
  Future<void> loadDeviceLogs(String deviceId) async {
    final stored = await LogStorage.loadLogs(deviceId);
    final inMem = _deviceLogs[deviceId] ?? [];
    final merged = <BleLogEntry>[...stored];
    for (final e in inMem) {
      if (!merged.any((s) => s.id == e.id)) merged.add(e);
    }
    merged.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    _deviceLogs[deviceId] = merged;
    _logUpdateController.add(deviceId);
  }

  /// Loads persisted logs for all known devices and emits a combined update.
  Future<void> loadAllLogs() async {
    final deviceIds = await LogStorage.getDevicesWithLogs();
    await Future.wait(deviceIds.map((id) => loadDeviceLogs(id)));
    _logUpdateController.add('all');
  }

  /// Returns all logs across every device, sorted by timestamp.
  List<BleLogEntry> get allLogs {
    final all = <BleLogEntry>[];
    for (final logs in _deviceLogs.values) {
      all.addAll(logs);
    }
    all.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return List.unmodifiable(all);
  }

  /// Returns logs for a specific device.
  List<BleLogEntry> deviceLogs(String deviceId) {
    return List.unmodifiable(_deviceLogs[deviceId] ?? []);
  }

  void dispose() {
    _logUpdateController.close();
  }
}
