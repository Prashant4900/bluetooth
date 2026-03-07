import 'dart:async';

import 'package:bluetooth/models/ble_log_entry.dart';
import 'package:bluetooth/storage/log_storage.dart';

/// Central repository for managing BLE logs in memory and delegating to persistent storage.
class BleLogRepository {
  /// Simple flat list of all logs in memory.
  final List<BleLogEntry> _logs = [];

  final _logUpdateController = StreamController<String>.broadcast();

  /// Stream that emits the deviceId (or 'all') whenever logs are updated.
  Stream<String> get onLogsUpdated => _logUpdateController.stream;

  /// Returns logs for a specific device.
  List<BleLogEntry> deviceLogs(String deviceId) {
    return _logs.where((l) => l.deviceId == deviceId).toList();
  }

  /// Returns all logs across every device, sorted by timestamp.
  List<BleLogEntry> get allLogs {
    return List.unmodifiable(_logs);
  }

  /// Adds [entry] to the in-memory buffer, persists it, and broadcasts the update.
  Future<void> addLog(BleLogEntry entry) async {
    final deviceLogs = this.deviceLogs(entry.deviceId);

    // Deduplication check: ignore if the exact same message was logged <1s ago
    if (deviceLogs.isNotEmpty) {
      final lastLog = deviceLogs.last;
      if (lastLog.message == entry.message &&
          entry.timestamp.difference(lastLog.timestamp).inMilliseconds < 1000) {
        return;
      }
    }

    _logs.add(entry);
    _logUpdateController.add(entry.deviceId);
    _logUpdateController.add('all');
    LogStorage.appendLog(entry).ignore();
  }

  /// Loads persisted logs for [deviceId], merges with in-memory entries.
  Future<void> loadDeviceLogs(String deviceId) async {
    final stored = await LogStorage.loadLogs(deviceId);

    // Add stored logs if they aren't already in memory
    for (final s in stored) {
      if (!_logs.any((l) => l.id == s.id)) {
        _logs.add(s);
      }
    }

    _logs.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    _logUpdateController.add(deviceId);
  }

  /// Loads persisted logs for all known devices.
  Future<void> loadAllLogs() async {
    final deviceIds = await LogStorage.getDevicesWithLogs();
    await Future.wait(deviceIds.map((id) => loadDeviceLogs(id)));
    _logUpdateController.add('all');
  }

  void dispose() {
    _logUpdateController.close();
  }
}
