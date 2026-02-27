import 'dart:async';

import 'package:flutter/foundation.dart';
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

  // ══════════════════════════════════════════════
  // SECTION 1 – INITIALIZE
  // ══════════════════════════════════════════════
  // Call this once at app start (e.g. from main or
  // BLoC constructor) to:
  //   • check Bluetooth availability
  //   • wire up the global availability listener
  //   • configure queue / timeout / log level
  //
  // Returns the current [AvailabilityState] so the
  // caller can decide whether scanning is possible.
  // ══════════════════════════════════════════════

  /// Stream that broadcasts [AvailabilityState] changes.
  Stream<AvailabilityState> get availabilityStream =>
      UniversalBle.availabilityStream;

  /// Initialise BLE and return the current [AvailabilityState].
  ///
  /// Safe to call multiple times – subsequent calls are no-ops
  /// because universal_ble manages its own native state.
  Future<AvailabilityState> initialize() async {
    // Set log level so we can see all BLE ops in the console
    // during this POC phase.
    await UniversalBle.setLogLevel(BleLogLevel.verbose);

    // Use a per-device queue so multiple devices can be
    // operated in parallel without blocking each other.
    UniversalBle.queueType = QueueType.perDevice;

    // 10-second command timeout (default, kept explicit).
    UniversalBle.timeout = const Duration(seconds: 10);

    // Wire the global availability handler.
    UniversalBle.onAvailabilityChange = (AvailabilityState state) {
      debugPrint('[BLE] Availability changed → $state');
    };

    // ── Global connection change handler ────────────────────────
    // This fires for EVERY device: explicitly-connected GATT devices
    // AND system-paired devices (earbuds, headsets) that connect or
    // disconnect independently of the app.
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

    // Return current state so cubit can show the right UI.
    final state = await UniversalBle.getBluetoothAvailabilityState();
    debugPrint('[BLE] Initial availability state: $state');
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

  /// Returns devices that are already connected to the system
  /// (e.g. paired via Settings) – they won't appear in scan results.
  Future<List<BleDevice>> getSystemDevices({
    List<String> withServices = const [],
  }) async {
    return UniversalBle.getSystemDevices(withServices: withServices);
  }

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

  /// Check whether a device is currently paired.
  Future<bool?> isPaired(BleDevice device, {BleCommand? pairingCommand}) =>
      device.isPaired(pairingCommand: pairingCommand);

  /// Stream that emits `true`/`false` whenever pairing state changes.
  Stream<bool> pairingStateStream(BleDevice device) =>
      device.pairingStateStream;

  // ══════════════════════════════════════════════
  // SECTION 8 – EXTRAS (MTU / RSSI / PERMISSIONS)
  // ══════════════════════════════════════════════

  /// Request a larger MTU. Actual value is OS-controlled; this is
  /// best-effort. Returns the negotiated MTU.
  Future<int> requestMtu(BleDevice device, int desiredMtu) async {
    final mtu = await device.requestMtu(desiredMtu);
    debugPrint('[BLE] Negotiated MTU: $mtu');
    return mtu;
  }

  /// Read RSSI (signal strength) of a connected device.
  /// Supported on Android, iOS, macOS only.
  Future<int> readRssi(BleDevice device) => device.readRssi();

  /// Request runtime Bluetooth permissions.
  /// On Android you can control whether fine-location is requested.
  Future<void> requestPermissions({bool withAndroidFineLocation = false}) =>
      UniversalBle.requestPermissions(
        withAndroidFineLocation: withAndroidFineLocation,
      );
}
