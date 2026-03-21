import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:universal_ble/universal_ble.dart';

/// A single connection-state change event from any BLE device.
class BleConnectionEvent {
  const BleConnectionEvent({
    required this.deviceId,
    required this.isConnected,
    this.error,
  });
  final String deviceId;
  final bool isConnected;
  final String? error;
}

// ─────────────────────────────────────────────────────────────────────────────
// BluetoothService
// ─────────────────────────────────────────────────────────────────────────────
class BluetoothService {
  final _connectionEventController =
      StreamController<BleConnectionEvent>.broadcast();

  Stream<BleConnectionEvent> get connectionStateStream =>
      _connectionEventController.stream;

  bool _initialized = false;

  // Keepalive + dead-device detection state.
  final Map<String, BleCharacteristic?> _connectedDeviceKeepalive = {};

  // ✅ Track consecutive ping failures per device.
  // After [_maxConsecutiveFailures] failures we synthesise a disconnect event
  // rather than waiting for the BLE stack's supervision timeout (which can
  // take up to 2 minutes on some peripherals).
  final Map<String, int> _pingFailureCount = {};
  static const int _maxConsecutiveFailures = 2;

  Timer? _keepaliveTimer;

  // ══════════════════════════════════════════════
  // SECTION 1 – INITIALIZE
  // ══════════════════════════════════════════════

  Stream<AvailabilityState> get availabilityStream =>
      UniversalBle.availabilityStream;

  Future<AvailabilityState> initialize() async {
    if (!_initialized) {
      _initialized = true;

      FlutterForegroundTask.addTaskDataCallback((data) {
        if (data is Map && data['type'] == 'connectionChange') {
          final deviceId = data['deviceId'] as String?;
          final isConnected = data['isConnected'] as bool?;
          final error = data['error'] as String?;

          if (deviceId != null && isConnected != null) {
            debugPrint(
              '[BLE-BG-SYNC] Connection change: $deviceId → '
              '${isConnected ? "connected" : "disconnected"}'
              '${error != null ? " ($error)" : ""}',
            );
            _connectionEventController.add(
              BleConnectionEvent(
                deviceId: deviceId,
                isConnected: isConnected,
                error: error,
              ),
            );

            if (!isConnected) {
              _clearDeviceState(deviceId);
            }
          }
        }
      });

      UniversalBle.onConnectionChange = (deviceId, isConnected, error) {
        debugPrint(
          '[BLE] Connection change: $deviceId → '
          '${isConnected ? "connected" : "disconnected"}'
          '${error != null ? " ($error)" : ""}',
        );
        _connectionEventController.add(
          BleConnectionEvent(
            deviceId: deviceId,
            isConnected: isConnected,
            error: error,
          ),
        );

        if (!isConnected) {
          _clearDeviceState(deviceId);
        }
      };

      // ✅ Ping every 8s — frequent enough to detect a dead device well
      // within the shortest possible supervision timeout (~10s) so the UI
      // updates promptly when the user switches off their device.
      _keepaliveTimer = Timer.periodic(
        const Duration(seconds: 8),
        (_) => _pingAllConnected(),
      );
    }

    await UniversalBle.setLogLevel(BleLogLevel.verbose);
    UniversalBle.queueType = QueueType.perDevice;

    // ✅ Short ATT timeout so a ping to a dead device fails fast (~5s)
    // rather than hanging for the full BLE supervision window.
    UniversalBle.timeout = const Duration(seconds: 5);

    UniversalBle.onAvailabilityChange = (AvailabilityState state) {
      debugPrint('[BLE] Availability changed → $state');
    };

    return await UniversalBle.getBluetoothAvailabilityState();
  }

  // ── Foreground GATT keepalive + dead-device detection ────────────────────

  Future<void> _pingAllConnected() async {
    for (final deviceId in List<String>.from(_connectedDeviceKeepalive.keys)) {
      await _pingDevice(deviceId);
    }
  }

  /// Reads one characteristic from [deviceId].
  ///
  /// On success  → resets failure counter (device is alive).
  /// On failure  → increments failure counter; after [_maxConsecutiveFailures]
  ///               consecutive failures, synthesises a disconnect event so the
  ///               UI updates immediately without waiting for the BLE stack.
  Future<void> _pingDevice(String deviceId) async {
    final char = _connectedDeviceKeepalive[deviceId];
    if (char == null) return;

    try {
      await char.read();
      // Device responded — reset failure streak.
      _pingFailureCount[deviceId] = 0;
      debugPrint('[BLE] Keepalive OK → $deviceId');
    } catch (e) {
      final failures = (_pingFailureCount[deviceId] ?? 0) + 1;
      _pingFailureCount[deviceId] = failures;

      debugPrint(
        '[BLE] Keepalive FAIL ($failures/$_maxConsecutiveFailures) → $deviceId: $e',
      );

      if (failures >= _maxConsecutiveFailures) {
        debugPrint(
          '[BLE] Device presumed OFF — synthesising disconnect for $deviceId',
        );
        _synthesiseDisconnect(deviceId);
      }
    }
  }

  /// Emits a synthetic disconnect event and cleans up state for [deviceId].
  /// Called when ping failures exceed the threshold, before the BLE stack
  /// has fired its own onConnectionChange callback.
  void _synthesiseDisconnect(String deviceId) {
    _clearDeviceState(deviceId);
    _connectionEventController.add(
      BleConnectionEvent(
        deviceId: deviceId,
        isConnected: false,
        error: 'Device unreachable — presumed powered off',
      ),
    );
  }

  /// Removes all per-device keepalive and failure state.
  void _clearDeviceState(String deviceId) {
    _connectedDeviceKeepalive.remove(deviceId);
    _pingFailureCount.remove(deviceId);
  }

  // ══════════════════════════════════════════════
  // SECTION 2 – SCANNING
  // ══════════════════════════════════════════════

  Stream<BleDevice> get scanStream => UniversalBle.scanStream;

  Future<void> stopScanIfActive() async {
    try {
      final scanning = await UniversalBle.isScanning();
      if (scanning) {
        await UniversalBle.stopScan();
        debugPrint('[BLE] Stopped residual scan before starting new one');
      }
    } catch (_) {}
  }

  Future<void> startScan({List<String> withServices = const []}) async {
    await stopScanIfActive();
    final ScanFilter? filter = withServices.isNotEmpty
        ? ScanFilter(withServices: withServices)
        : null;
    await UniversalBle.startScan(scanFilter: filter);
    debugPrint('[BLE] Scan started');
  }

  Future<void> stopScan() async {
    await UniversalBle.stopScan();
    debugPrint('[BLE] Scan stopped');
  }

  Future<bool> isScanning() => UniversalBle.isScanning();

  // ══════════════════════════════════════════════
  // SECTION 3 – CONNECTION
  // ══════════════════════════════════════════════

  Future<void> connect(BleDevice device) async {
    debugPrint('[BLE] Connecting to ${device.name ?? device.deviceId}');
    await device.connect();
    debugPrint('[BLE] Connected');
    // Register for keepalive; char is resolved after service discovery.
    _connectedDeviceKeepalive[device.deviceId] = null;
    _pingFailureCount[device.deviceId] = 0;
  }

  Future<void> disconnect(BleDevice device) async {
    debugPrint('[BLE] Disconnecting from ${device.name ?? device.deviceId}');
    // Remove before disconnecting so the timer doesn't ping a device
    // we are intentionally closing.
    _clearDeviceState(device.deviceId);
    await device.disconnect();
    debugPrint('[BLE] Disconnected');
  }

  Stream<bool> connectionStream(BleDevice device) => device.connectionStream;

  // ══════════════════════════════════════════════
  // SECTION 4 – SERVICE & CHARACTERISTIC DISCOVERY
  // ══════════════════════════════════════════════

  Future<List<BleService>> discoverServices(BleDevice device) async {
    final services = await device.discoverServices();
    debugPrint('[BLE] Discovered ${services.length} service(s)');

    // Cache the keepalive char so pings can start immediately.
    final keepaliveChar = await _resolveKeepaliveChar(
      device.deviceId,
      services,
    );
    _connectedDeviceKeepalive[device.deviceId] = keepaliveChar;
    _pingFailureCount[device.deviceId] = 0;

    return services;
  }

  Future<BleCharacteristic?> _resolveKeepaliveChar(
    String deviceId,
    List<BleService> services,
  ) async {
    try {
      // Prefer Generic Access Device Name (0x2A00) — universally readable.
      for (final svc in services) {
        if (svc.uuid.toUpperCase().contains('1800')) {
          for (final ch in svc.characteristics) {
            if (ch.uuid.toUpperCase().contains('2A00') &&
                ch.properties.contains(CharacteristicProperty.read)) {
              debugPrint(
                '[BLE] Keepalive char resolved (0x2A00) for $deviceId',
              );
              return ch;
            }
          }
        }
      }
      // Fallback: first characteristic with read property.
      for (final svc in services) {
        for (final ch in svc.characteristics) {
          if (ch.properties.contains(CharacteristicProperty.read)) {
            debugPrint(
              '[BLE] Keepalive char resolved (fallback) for $deviceId',
            );
            return ch;
          }
        }
      }
    } catch (e) {
      debugPrint('[BLE] Could not resolve keepalive char for $deviceId: $e');
    }
    return null;
  }

  Future<BleService> getService(BleDevice device, String serviceUuid) =>
      device.getService(serviceUuid);

  Future<BleCharacteristic> getCharacteristic(
    BleDevice device,
    String serviceUuid,
    String characteristicUuid,
  ) => device.getCharacteristic(characteristicUuid, service: serviceUuid);

  // ══════════════════════════════════════════════
  // SECTION 5 – READ / WRITE DATA
  // ══════════════════════════════════════════════

  Future<Uint8List> read(BleCharacteristic characteristic) async {
    final value = await characteristic.read();
    debugPrint('[BLE] Read ${value.length} byte(s)');
    return value;
  }

  Future<void> write(
    BleCharacteristic characteristic,
    List<int> data, {
    bool withResponse = true,
  }) async {
    await characteristic.write(data, withResponse: withResponse);
    debugPrint(
      '[BLE] Wrote ${data.length} byte(s) (withResponse: $withResponse)',
    );
  }

  // ══════════════════════════════════════════════
  // SECTION 6 – SUBSCRIPTIONS (NOTIFY / INDICATE)
  // ══════════════════════════════════════════════

  Future<StreamSubscription<Uint8List>> subscribeNotifications(
    BleCharacteristic characteristic,
    void Function(Uint8List value) onData,
  ) async {
    await characteristic.notifications.subscribe();
    debugPrint('[BLE] Notifications subscribed');
    return characteristic.onValueReceived.listen(onData);
  }

  Future<StreamSubscription<Uint8List>> subscribeIndications(
    BleCharacteristic characteristic,
    void Function(Uint8List value) onData,
  ) async {
    await characteristic.indications.subscribe();
    debugPrint('[BLE] Indications subscribed');
    return characteristic.onValueReceived.listen(onData);
  }

  Future<void> unsubscribe(BleCharacteristic characteristic) async {
    await characteristic.unsubscribe();
    debugPrint('[BLE] Unsubscribed');
  }

  // ══════════════════════════════════════════════
  // SECTION 7 – PAIRING
  // ══════════════════════════════════════════════

  Future<void> pair(BleDevice device, {BleCommand? pairingCommand}) async {
    debugPrint('[BLE] Pairing with ${device.name ?? device.deviceId}');
    await device.pair(pairingCommand: pairingCommand);
    debugPrint('[BLE] Pair request sent');
  }

  Future<void> unpair(BleDevice device) async {
    _clearDeviceState(device.deviceId);
    await device.unpair();
    debugPrint('[BLE] Unpaired');
  }

  Future<void> requestPermissions({bool withAndroidFineLocation = false}) =>
      UniversalBle.requestPermissions(
        withAndroidFineLocation: withAndroidFineLocation,
      );

  // ══════════════════════════════════════════════
  // SECTION 8 – DISPOSE
  // ══════════════════════════════════════════════

  void dispose() {
    _keepaliveTimer?.cancel();
    _keepaliveTimer = null;
    _connectedDeviceKeepalive.clear();
    _pingFailureCount.clear();
    _connectionEventController.close();
  }
}
