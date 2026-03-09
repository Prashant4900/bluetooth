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

// ─────────────────────────────────────────────────
// BluetoothService
// A thin wrapper over universal_ble that exposes
// each feature group as a clearly separated section.
// ─────────────────────────────────────────────────
class BluetoothService {
  // Global stream of connection state changes for ALL BLE devices.
  // Fed directly by UniversalBle.onConnectionChange so it fires
  // for system-paired devices (earbuds, headsets) too, not just
  // devices explicitly connected through BluetoothService.
  final _connectionEventController =
      StreamController<BleConnectionEvent>.broadcast();

  Stream<BleConnectionEvent> get connectionStateStream =>
      _connectionEventController.stream;

  bool _initialized = false;

  // ══════════════════════════════════════════════
  // SECTION 1 – INITIALIZE
  // ══════════════════════════════════════════════

  /// Stream that broadcasts [AvailabilityState] changes.
  Stream<AvailabilityState> get availabilityStream =>
      UniversalBle.availabilityStream;

  /// Initialise BLE and return the current [AvailabilityState].
  ///
  /// Safe to call multiple times – subsequent calls are no-ops
  /// because universal_ble manages its own native state.
  Future<AvailabilityState> initialize() async {
    if (!_initialized) {
      _initialized = true;

      // Receive connection events forwarded by the background isolate.
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
          }
        }
      });

      // Fire for ALL connection changes at the platform level.
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
      };
    }

    // Set log level, queue type, and timeout.
    await UniversalBle.setLogLevel(BleLogLevel.verbose);
    UniversalBle.queueType = QueueType.perDevice;
    UniversalBle.timeout = const Duration(seconds: 10);

    UniversalBle.onAvailabilityChange = (AvailabilityState state) {
      debugPrint('[BLE] Availability changed → $state');
    };

    final state = await UniversalBle.getBluetoothAvailabilityState();
    return state;
  }

  // ══════════════════════════════════════════════
  // SECTION 2 – SCANNING
  // ══════════════════════════════════════════════

  /// Stream of discovered [BleDevice] objects.
  Stream<BleDevice> get scanStream => UniversalBle.scanStream;

  /// Silently stop any active scan. Safe to call even when not scanning.
  /// Call this on app init (hot restart guard) or before starting a new scan.
  Future<void> stopScanIfActive() async {
    try {
      final scanning = await UniversalBle.isScanning();
      if (scanning) {
        await UniversalBle.stopScan();
        debugPrint('[BLE] Stopped residual scan before starting new one');
      }
    } catch (_) {
      // Ignore – best-effort cleanup
    }
  }

  /// Start scanning. Pass an optional [withServices] list to
  /// filter results (required on Web).
  Future<void> startScan({List<String> withServices = const []}) async {
    // Always stop any lingering scan first (hot restart safety net)
    await stopScanIfActive();
    final ScanFilter? filter = withServices.isNotEmpty
        ? ScanFilter(withServices: withServices)
        : null;
    await UniversalBle.startScan(scanFilter: filter);
    debugPrint('[BLE] Scan started');
  }

  /// Stop an ongoing scan.
  Future<void> stopScan() async {
    await UniversalBle.stopScan();
    debugPrint('[BLE] Scan stopped');
  }

  /// Whether a scan is currently in progress.
  Future<bool> isScanning() => UniversalBle.isScanning();

  // ══════════════════════════════════════════════
  // SECTION 3 – CONNECTION
  // ══════════════════════════════════════════════

  /// Connect to a BLE device.
  Future<void> connect(BleDevice device) async {
    debugPrint('[BLE] Connecting to ${device.name ?? device.deviceId}');
    await device.connect();
    debugPrint('[BLE] Connected');
  }

  /// Disconnect from a BLE device.
  Future<void> disconnect(BleDevice device) async {
    debugPrint('[BLE] Disconnecting from ${device.name ?? device.deviceId}');
    await device.disconnect();
    debugPrint('[BLE] Disconnected');
  }

  /// A stream of connection state booleans for [device].
  Stream<bool> connectionStream(BleDevice device) => device.connectionStream;

  // ══════════════════════════════════════════════
  // SECTION 4 – SERVICE & CHARACTERISTIC DISCOVERY
  // ══════════════════════════════════════════════

  /// Discover all services advertised by [device].
  Future<List<BleService>> discoverServices(BleDevice device) async {
    final services = await device.discoverServices();
    debugPrint('[BLE] Discovered ${services.length} service(s)');
    return services;
  }

  /// Get a specific service by UUID (uses cache by default).
  Future<BleService> getService(BleDevice device, String serviceUuid) =>
      device.getService(serviceUuid);

  /// Get a specific characteristic (uses cache by default).
  Future<BleCharacteristic> getCharacteristic(
    BleDevice device,
    String serviceUuid,
    String characteristicUuid,
  ) => device.getCharacteristic(characteristicUuid, service: serviceUuid);

  // ══════════════════════════════════════════════
  // SECTION 5 – READ / WRITE DATA
  // ══════════════════════════════════════════════

  /// Read the current value of [characteristic].
  Future<Uint8List> read(BleCharacteristic characteristic) async {
    final value = await characteristic.read();
    debugPrint('[BLE] Read ${value.length} byte(s)');
    return value;
  }

  /// Write [data] to [characteristic].
  ///
  /// Set [withResponse] to `false` for write-without-response
  /// (faster, no acknowledgement).
  Future<void> write(
    BleCharacteristic characteristic,
    List<int> data, {
    bool withResponse = true,
  }) async {
    await characteristic.write(data, withResponse: withResponse);
    debugPrint(
      '[BLE] Wrote ${data.length} byte(s) '
      '(withResponse: $withResponse)',
    );
  }

  // ══════════════════════════════════════════════
  // SECTION 6 – SUBSCRIPTIONS (NOTIFY / INDICATE)
  // ══════════════════════════════════════════════

  /// Subscribe to notifications on [characteristic].
  /// Returns a [StreamSubscription] so the caller can cancel it.
  Future<StreamSubscription<Uint8List>> subscribeNotifications(
    BleCharacteristic characteristic,
    void Function(Uint8List value) onData,
  ) async {
    await characteristic.notifications.subscribe();
    debugPrint('[BLE] Notifications subscribed');
    return characteristic.onValueReceived.listen(onData);
  }

  /// Subscribe to indications on [characteristic].
  Future<StreamSubscription<Uint8List>> subscribeIndications(
    BleCharacteristic characteristic,
    void Function(Uint8List value) onData,
  ) async {
    await characteristic.indications.subscribe();
    debugPrint('[BLE] Indications subscribed');
    return characteristic.onValueReceived.listen(onData);
  }

  /// Unsubscribe from notifications/indications on [characteristic].
  Future<void> unsubscribe(BleCharacteristic characteristic) async {
    await characteristic.unsubscribe();
    debugPrint('[BLE] Unsubscribed');
  }

  // ══════════════════════════════════════════════
  // SECTION 7 – PAIRING
  // ══════════════════════════════════════════════

  /// Trigger pairing. On Android/Windows/Linux this prompts the OS
  /// dialog. On Apple/Web pass an optional [pairingCommand] pointing
  /// to an encrypted characteristic to trigger pairing indirectly.
  Future<void> pair(BleDevice device, {BleCommand? pairingCommand}) async {
    debugPrint('[BLE] Pairing with ${device.name ?? device.deviceId}');
    await device.pair(pairingCommand: pairingCommand);
    debugPrint('[BLE] Pair request sent');
  }

  /// Unpair a device. Supported on Android, Windows, Linux.
  Future<void> unpair(BleDevice device) async {
    await device.unpair();
    debugPrint('[BLE] Unpaired');
  }

  /// Request runtime Bluetooth permissions.
  Future<void> requestPermissions({bool withAndroidFineLocation = false}) =>
      UniversalBle.requestPermissions(
        withAndroidFineLocation: withAndroidFineLocation,
      );
}
