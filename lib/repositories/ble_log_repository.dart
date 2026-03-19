import 'dart:async';

import 'package:bluetooth/models/ble_log_entry.dart';
import 'package:bluetooth/storage/log_storage.dart';

/// In-memory log buffer with persistence via [LogStorage].
///
/// Consumers subscribe to [onLogsUpdated] to know when to refresh the UI.
/// The stream emits either a specific deviceId or the sentinel value `'all'`.
class BleLogRepository {
  final Map<String, List<BleLogEntry>> _deviceLogs = {};

  final _logUpdateController = StreamController<String>.broadcast();
  Stream<String> get onLogsUpdated => _logUpdateController.stream;

  // ── Write ────────────────────────────────────────────────────────────────

  /// Adds [entry] to the in-memory buffer, persists it, and notifies listeners.
  ///
  /// Duplicate guard: if the identical message was logged less than 1 second
  /// ago for the same device, the entry is silently dropped.
  Future<void> addLog(BleLogEntry entry) async {
    final list = _deviceLogs.putIfAbsent(entry.deviceId, () => []);

    if (list.isNotEmpty) {
      final last = list.last;
      final isDuplicate =
          last.message == entry.message &&
          entry.timestamp.difference(last.timestamp).inMilliseconds < 1000;
      if (isDuplicate) return;
    }

    list.add(entry);
    LogStorage.appendLog(entry).ignore(); // persist in background
    _logUpdateController.add(entry.deviceId);
    _logUpdateController.add('all');
  }

  // ── Read ─────────────────────────────────────────────────────────────────

  /// Returns all logs across every device, sorted oldest-first.
  List<BleLogEntry> get allLogs {
    final all = _deviceLogs.values.expand((logs) => logs).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return List.unmodifiable(all);
  }

  /// Returns logs for a specific [deviceId].
  List<BleLogEntry> deviceLogs(String deviceId) =>
      List.unmodifiable(_deviceLogs[deviceId] ?? []);

  // ── Load from storage ────────────────────────────────────────────────────

  /// Loads persisted logs for [deviceId], merges with in-memory entries, and notifies listeners.
  Future<void> loadDeviceLogs(String deviceId) async {
    final stored = await LogStorage.loadLogs(deviceId);
    final inMemory = _deviceLogs[deviceId] ?? [];

    // Merge: start with stored entries, add any in-memory entries not yet persisted.
    final inMemoryIds = stored.map((e) => e.id).toSet();
    final merged = [
      ...stored,
      ...inMemory.where((e) => !inMemoryIds.contains(e.id)),
    ]..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    _deviceLogs[deviceId] = merged;
    _logUpdateController.add(deviceId);
  }

  /// Loads persisted logs for all known devices and emits a combined `'all'` update.
  Future<void> loadAllLogs() async {
    final deviceIds = await LogStorage.getDevicesWithLogs();
    await Future.wait(deviceIds.map(loadDeviceLogs));
    _logUpdateController.add('all');
  }

  // ── Cleanup ──────────────────────────────────────────────────────────────

  void dispose() => _logUpdateController.close();
}
