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
        // ✅ FIX: Tick every 20s — short enough to keepalive before the
        // typical BLE supervision timeout (which defaults to ~20–40s on
        // most stacks when no traffic is exchanged).
        eventAction: ForegroundTaskEventAction.repeat(20000),
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

  // ✅ FIX: Track discovered-but-not-yet-connected paired devices so we
  // can attempt connection even after the scan result stream goes quiet.
  final Map<String, BleDevice> _seenPaired = {};

  // ✅ FIX: Cache services/characteristics for keepalive reads so we
  // don't re-discover every tick (expensive and can cause GATT 133).
  final Map<String, BleCharacteristic?> _keepaliveChar = {};

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('[BleTask] started (${starter.name})');
    _registerConnectionCallback();
    await _startScan();
  }

  /// Called every 20 s.
  /// 1. Ping every connected device to keep the GATT link alive.
  /// 2. Restart the scan if not all paired devices are connected yet.
  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    final paired = await PairingStorage.loadPairedIds();
    if (paired.isEmpty) {
      await BleBackgroundService.stop();
      return;
    }

    // ✅ FIX: Send a keepalive ping to every connected device.
    // This produces traffic on the link and resets the BLE supervision
    // timer on both sides, preventing the radio from dropping the connection.
    await _pingConnectedDevices();

    // Restart scan only if some paired devices are still not connected.
    final allConnected = paired.every(_connected.contains);
    if (!allConnected) {
      await _startScan();
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    debugPrint('[BleTask] destroyed (timeout=$isTimeout)');
  }

  // ── GATT keepalive ───────────────────────────────────────────────────────

  /// Read the Generic Access "Device Name" characteristic (0x2A00) on every
  /// connected device. This is universally supported and produces the minimal
  /// traffic needed to reset the BLE supervision timeout.
  ///
  /// If a device doesn't expose 0x2A00 we silently skip it — the mere attempt
  /// to exchange an ATT packet is usually enough on most stacks.
  Future<void> _pingConnectedDevices() async {
    for (final deviceId in List<String>.from(_connected)) {
      try {
        // ✅ Use cached characteristic when possible.
        if (!_keepaliveChar.containsKey(deviceId)) {
          _keepaliveChar[deviceId] = await _resolveKeepaliveChar(deviceId);
        }

        final char = _keepaliveChar[deviceId];
        if (char != null) {
          await char.read();
          debugPrint('[BleTask] Keepalive ping sent to $deviceId');
        }
      } catch (e) {
        // A failure here usually means the device dropped — the
        // onConnectionChange callback will handle reconnection.
        debugPrint('[BleTask] Keepalive ping failed for $deviceId: $e');
        _keepaliveChar.remove(deviceId);
      }
    }
  }

  /// Resolve the cheapest readable characteristic we can use for keepalive.
  /// Priority: Generic Access "Device Name" (0x2A00) → first readable char.
  Future<BleCharacteristic?> _resolveKeepaliveChar(String deviceId) async {
    try {
      final services = await UniversalBle.discoverServices(deviceId);

      // Try Generic Access Device Name first — it's always readable.
      for (final svc in services) {
        if (svc.uuid.toUpperCase().contains('1800')) {
          for (final ch in svc.characteristics) {
            if (ch.uuid.toUpperCase().contains('2A00') &&
                ch.properties.contains(CharacteristicProperty.read)) {
              return ch;
            }
          }
        }
      }

      // Fallback: first characteristic with read property.
      for (final svc in services) {
        for (final ch in svc.characteristics) {
          if (ch.properties.contains(CharacteristicProperty.read)) {
            return ch;
          }
        }
      }
    } catch (e) {
      debugPrint(
        '[BleTask] Could not resolve keepalive char for $deviceId: $e',
      );
    }
    return null;
  }

  // ── BLE scan + auto-connect logic ────────────────────────────────────────

  // ✅ FIX: Register the connection callback once — not inside _startScan()
  // which can be called repeatedly and would overwrite the handler each time,
  // losing events that fire between two _startScan() calls.
  void _registerConnectionCallback() {
    UniversalBle.onConnectionChange = _onConnectionChanged;
  }

  Future<void> _startScan() async {
    final paired = await PairingStorage.loadPairedIds();
    if (paired.isEmpty) return;

    // Stop any currently running scan before starting a new one.
    try {
      if (await UniversalBle.isScanning()) {
        await UniversalBle.stopScan();
      }
    } catch (_) {}

    try {
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
    // ✅ NOTE: onConnectionChange is registered once in onStart via
    // _registerConnectionCallback() — do NOT reassign it here.
  }

  /// Triggered for every advertisement packet received during the scan.
  Future<void> _onDeviceFound(BleDevice device, Set<String> paired) async {
    final id = device.deviceId;

    if (!paired.contains(id)) return;

    // ✅ FIX: Cache the device so we can retry if the first attempt fails.
    _seenPaired[id] = device;

    if (_connected.contains(id) || _connecting.contains(id)) return;

    _connecting.add(id);
    await _log(
      id,
      device.name,
      '[BG] Paired device in range — auto-connecting…',
    );

    // Small delay to stabilise the Android BLE stack (reduces GATT 133).
    await Future.delayed(const Duration(milliseconds: 800));

    if (_connected.contains(id)) {
      _connecting.remove(id);
      return;
    }

    try {
      await UniversalBle.connect(id);
      _connected.add(id);
      // ✅ FIX: Pre-resolve the keepalive characteristic right after connect
      // so the first keepalive tick doesn't incur a service-discovery delay.
      _keepaliveChar[id] = await _resolveKeepaliveChar(id);
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
    // ✅ FIX: Clear cached keepalive state so next connection gets a fresh one.
    _keepaliveChar.remove(deviceId);

    await _log(
      deviceId,
      null,
      '[BG] Device disconnected — waiting to reconnect',
    );
    FlutterForegroundTask.updateService(
      notificationTitle: 'BLE Monitor',
      notificationText: 'Watching for your paired devices…',
    );

    // ✅ FIX: If we already saw this device in a scan result, retry
    // immediately rather than waiting for the next scan cycle.
    if (_seenPaired.containsKey(deviceId)) {
      final device = _seenPaired[deviceId]!;
      final paired = await PairingStorage.loadPairedIds();
      await _onDeviceFound(device, paired);
    } else {
      // Otherwise re-open the scan so we catch it when it comes back.
      await _startScan();
    }
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
