import 'package:bluetooth/models/ble_log_entry.dart';
import 'package:bluetooth/storage/log_storage.dart';
import 'package:bluetooth/storage/pairing_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:universal_ble/universal_ble.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Entry point — called by flutter_foreground_task in the background isolate.
// Must be a top-level function annotated with @pragma('vm:entry-point').
// ─────────────────────────────────────────────────────────────────────────────

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(_BleTaskHandler());
}

// ─────────────────────────────────────────────────────────────────────────────
// BleBackgroundService — public API called from the app
// ─────────────────────────────────────────────────────────────────────────────

class BleBackgroundService {
  BleBackgroundService._();

  /// Initialise the foreground task configuration.
  /// Call once in main() before runApp().
  static void initialize() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'ble_monitor_channel',
        channelName: 'BLE Auto-Connect Monitor',
        channelDescription:
            'Keeps your paired BLE devices connected in the background.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false, // iOS CoreBluetooth handles reconnect natively
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(30000), // every 30 s
        autoRunOnBoot: true, // restart after device reboot
        autoRunOnMyPackageReplaced: true, // restart after app update
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  /// Start the foreground service (shows a persistent notification on Android).
  static Future<ServiceRequestResult> start() async {
    if (await FlutterForegroundTask.isRunningService) {
      return FlutterForegroundTask.restartService();
    }
    return FlutterForegroundTask.startService(
      serviceId: 7788,
      notificationTitle: 'BLE Monitor',
      notificationText: 'Watching for your paired devices…',
      callback: startCallback,
    );
  }

  /// Stop the foreground service.
  static Future<ServiceRequestResult> stop() =>
      FlutterForegroundTask.stopService();

  /// Whether the service is currently running.
  static Future<bool> get isRunning => FlutterForegroundTask.isRunningService;
}

// ─────────────────────────────────────────────────────────────────────────────
// Task handler — runs inside the background isolate
// ─────────────────────────────────────────────────────────────────────────────

class _BleTaskHandler extends TaskHandler {
  final Set<String> _connected = {};
  final Set<String> _connecting = {};

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('[BleTask] started (${starter.name})');
    await _startScan();
  }

  /// Called every 30 seconds by ForegroundTaskEventAction.repeat
  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    final paired = await PairingStorage.loadPairedIds();
    if (paired.isEmpty) {
      await BleBackgroundService.stop();
      return;
    }
    // Re-trigger scan in case it stopped
    await _startScan();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    debugPrint('[BleTask] destroyed (timeout=$isTimeout)');
  }

  // ── BLE logic ─────────────────────────────────────────────────

  Future<void> _startScan() async {
    try {
      final paired = await PairingStorage.loadPairedIds();
      if (paired.isEmpty) return;

      await UniversalBle.startScan(scanFilter: ScanFilter(withServices: []));

      UniversalBle.onScanResult = (device) async {
        if (!paired.contains(device.deviceId)) return;
        if (_connected.contains(device.deviceId)) return;
        if (_connecting.contains(device.deviceId)) return;

        _connecting.add(device.deviceId);
        await _log(
          device.deviceId,
          device.name,
          LogDirection.system,
          LogType.scan,
          '[BG] Paired device in range — auto-connecting…',
        );

        try {
          await UniversalBle.connect(device.deviceId);
          _connected.add(device.deviceId);
          _connecting.remove(device.deviceId);

          await _log(
            device.deviceId,
            device.name,
            LogDirection.incoming,
            LogType.connect,
            '[BG] Auto-connected successfully (background)',
          );

          // Update notification
          FlutterForegroundTask.updateService(
            notificationTitle: 'BLE Monitor',
            notificationText: 'Connected: ${device.name ?? device.deviceId}',
          );
        } catch (e) {
          _connecting.remove(device.deviceId);
          await _log(
            device.deviceId,
            device.name,
            LogDirection.system,
            LogType.error,
            '[BG] Auto-connect failed: $e',
          );
        }
      };

      UniversalBle.onConnectionChange = (deviceId, isConnected, _) async {
        if (!isConnected) {
          _connected.remove(deviceId);
          await _log(
            deviceId,
            null,
            LogDirection.system,
            LogType.disconnect,
            '[BG] Device disconnected — waiting to reconnect',
          );
          FlutterForegroundTask.updateService(
            notificationTitle: 'BLE Monitor',
            notificationText: 'Watching for your paired devices…',
          );
        }
      };
    } catch (e) {
      debugPrint('[BleTask] scan error: $e');
    }
  }

  Future<void> _log(
    String deviceId,
    String? deviceName,
    LogDirection direction,
    LogType type,
    String message,
  ) async {
    try {
      final entry = BleLogEntry.system(
        deviceId: deviceId,
        deviceName: deviceName,
        type: type,
        message: message,
      );
      await LogStorage.appendLog(entry);
    } catch (e) {
      debugPrint('[BleTask] log error: $e');
    }
  }
}
