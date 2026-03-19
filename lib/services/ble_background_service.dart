import 'dart:io';

import 'package:bluetooth/models/ble_log_entry.dart';
import 'package:bluetooth/storage/log_storage.dart';
import 'package:bluetooth/storage/pairing_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
// ignore: implementation_imports
import 'package:universal_ble/src/universal_ble_pigeon/universal_ble.g.dart';
import 'package:universal_ble/universal_ble.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Background isolate entry point — must be a top-level function.
// ─────────────────────────────────────────────────────────────────────────────

@pragma('vm:entry-point')
void startCallback() => FlutterForegroundTask.setTaskHandler(_BleTaskHandler());

// ─────────────────────────────────────────────────────────────────────────────
// BleBackgroundService — public API used by the rest of the app.
// ─────────────────────────────────────────────────────────────────────────────

class BleBackgroundService {
  BleBackgroundService._();

  /// Call once in main() before runApp() to configure the foreground task.
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
        // iOS CoreBluetooth handles reconnection natively — no notification needed.
        showNotification: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(30000), // tick every 30 s
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  /// Starts the foreground service (or restarts it if already running).
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

  static Future<ServiceRequestResult> stop() =>
      FlutterForegroundTask.stopService();

  static Future<bool> get isRunning => FlutterForegroundTask.isRunningService;
}

// ─────────────────────────────────────────────────────────────────────────────
// _BleTaskHandler — runs inside the background isolate.
// ─────────────────────────────────────────────────────────────────────────────

class _BleTaskHandler extends TaskHandler {
  // Tracks devices we are already connected to or are busy connecting to,
  // so we never fire duplicate connect attempts for the same device.
  final Set<String> _connected = {};
  final Set<String> _connecting = {};

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('[BleTask] started (${starter.name})');
    await _startScan();
  }

  /// Called every 30 s. Stops the service if no devices are paired,
  /// otherwise re-triggers the scan in case it stopped on its own.
  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    final paired = await PairingStorage.loadPairedIds();
    if (paired.isEmpty) {
      await BleBackgroundService.stop();
      return;
    }
    await _startScan();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    debugPrint('[BleTask] destroyed (timeout=$isTimeout)');
  }

  // ── BLE scan + auto-connect logic ────────────────────────────────────────

  Future<void> _startScan() async {
    final paired = await PairingStorage.loadPairedIds();
    if (paired.isEmpty) return;

    try {
      // Platform channel vs high-level API:
      // On mobile/macOS we use the low-level platform channel directly so the
      // background isolate doesn't fight with the main isolate's plugin state.
      if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
        await UniversalBlePlatformChannel().startScan(
          UniversalScanFilter(
            withServices: [],
            withNamePrefix: [],
            withManufacturerData: [],
          ),
        );
      } else {
        await UniversalBle.startScan(scanFilter: ScanFilter(withServices: []));
      }
    } catch (e) {
      debugPrint('[BleTask] scan start error: $e');
      return;
    }

    UniversalBle.onScanResult = (device) => _onDeviceFound(device, paired);
    UniversalBle.onConnectionChange = _onConnectionChanged;
  }

  /// Triggered for every advertisement packet received during the scan.
  Future<void> _onDeviceFound(BleDevice device, Set<String> paired) async {
    final id = device.deviceId;

    // Ignore devices that aren't paired, or that we're already handling.
    if (!paired.contains(id)) return;
    if (_connected.contains(id) || _connecting.contains(id)) return;

    _connecting.add(id);
    await _log(
      id,
      device.name,
      '[BG] Paired device in range — auto-connecting…',
    );

    // Small delay to stabilise the Android BLE stack (reduces GATT 133 errors).
    await Future.delayed(const Duration(milliseconds: 800));

    // Another isolate may have connected during the delay — bail out if so.
    if (_connected.contains(id)) {
      _connecting.remove(id);
      return;
    }

    try {
      await UniversalBle.connect(id);
      _connected.add(id);
      await _log(id, device.name, '[BG] Auto-connected successfully');
      FlutterForegroundTask.updateService(
        notificationTitle: 'BLE Monitor',
        notificationText: 'Connected: ${device.name ?? id}',
      );
    } catch (e) {
      await _log(id, device.name, '[BG] Auto-connect failed: $e');
    } finally {
      _connecting.remove(id);
    }
  }

  /// Triggered whenever a device connects or disconnects.
  Future<void> _onConnectionChanged(
    String deviceId,
    bool isConnected,
    String? error,
  ) async {
    // Notify the main isolate so the UI stays in sync.
    FlutterForegroundTask.sendDataToMain({
      'type': 'connectionChange',
      'deviceId': deviceId,
      'isConnected': isConnected,
      'error': error,
    });

    if (isConnected) return;

    _connected.remove(deviceId);
    await _log(
      deviceId,
      null,
      '[BG] Device disconnected — waiting to reconnect',
    );
    FlutterForegroundTask.updateService(
      notificationTitle: 'BLE Monitor',
      notificationText: 'Watching for your paired devices…',
    );

    // Resume scanning so we catch the device when it comes back in range.
    await _startScan();
  }

  // ── Logging helper ───────────────────────────────────────────────────────

  Future<void> _log(String deviceId, String? deviceName, String message) async {
    try {
      await LogStorage.appendLog(
        BleLogEntry.system(
          deviceId: deviceId,
          deviceName: deviceName,
          message: message,
        ),
      );
    } catch (e) {
      debugPrint('[BleTask] log error: $e');
    }
  }
}
