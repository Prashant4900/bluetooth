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

  // ── Per-device keepalive state ───────────────────────────────────────────

  // Best readable characteristic for dead-device detection pings.
  final Map<String, BleCharacteristic?> _readChar = {};

  // Best writable characteristic for firmware inactivity-reset pings.
  // This is what actually resets the vendor's 3-minute auto-off timer.
  final Map<String, BleCharacteristic?> _writeChar = {};

  // Consecutive read-ping failures — used to synthesise a disconnect event
  // before the BLE stack's own supervision timeout fires.
  final Map<String, int> _pingFailureCount = {};
  static const int _maxConsecutiveFailures = 2;

  // Timer 1 — fires every 8 s.
  // Reads a characteristic to (a) keep the BLE link alive at the radio level
  // and (b) detect a powered-off device quickly via failure counting.
  Timer? _connectionCheckTimer;

  // Timer 2 — fires every 2 min.
  // Writes a dummy byte to the best writable characteristic so the firmware's
  // application-layer inactivity timer is reset before the 3-min threshold.
  // Once the vendor supplies the real heartbeat UUID this timer keeps working —
  // just swap _writeChar resolution to prefer that UUID.
  Timer? _firmwareKeepAliveTimer;

  // ══════════════════════════════════════════════
  // SECTION 1 – INITIALIZE
  // ══════════════════════════════════════════════

  Stream<AvailabilityState> get availabilityStream =>
      UniversalBle.availabilityStream;

  Future<AvailabilityState> initialize() async {
    if (!_initialized) {
      _initialized = true;

      // Forward background-isolate connection events into our stream.
      FlutterForegroundTask.addTaskDataCallback((data) {
        if (data is Map && data['type'] == 'connectionChange') {
          final deviceId = data['deviceId'] as String?;
          final isConnected = data['isConnected'] as bool?;
          final error = data['error'] as String?;
          if (deviceId != null && isConnected != null) {
            debugPrint(
              '[BLE-BG-SYNC] $deviceId → '
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
            if (!isConnected) _clearDeviceState(deviceId);
          }
        }
      });

      // Forward platform-level connection events.
      UniversalBle.onConnectionChange = (deviceId, isConnected, error) {
        debugPrint(
          '[BLE] $deviceId → '
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
        if (!isConnected) _clearDeviceState(deviceId);
      };

      // ── Timer 1: connection-check ping every 8 s ─────────────────────────
      // Reads a characteristic. Fast failure (5 s ATT timeout × 2 failures)
      // means we detect a powered-off device within ~18 s instead of waiting
      // for the BLE supervision timeout (up to 2 min).
      _connectionCheckTimer = Timer.periodic(
        const Duration(seconds: 8),
        (_) => _connectionCheckPing(),
      );

      // ── Timer 2: firmware keepalive write every 2 min ────────────────────
      // Writes a dummy byte to the device's application layer.
      // This is the only traffic the firmware's inactivity timer cares about.
      // 2 min < 3 min firmware threshold → timer resets before auto-off fires.
      _firmwareKeepAliveTimer = Timer.periodic(
        const Duration(minutes: 2),
        (_) => _firmwareKeepAlivePing(),
      );
    }

    await UniversalBle.setLogLevel(BleLogLevel.verbose);
    UniversalBle.queueType = QueueType.perDevice;

    // 5 s ATT timeout — dead device read fails fast rather than hanging.
    UniversalBle.timeout = const Duration(seconds: 5);

    UniversalBle.onAvailabilityChange = (state) =>
        debugPrint('[BLE] Availability → $state');

    return await UniversalBle.getBluetoothAvailabilityState();
  }

  // ── Timer 1: connection-check read ping ──────────────────────────────────

  Future<void> _connectionCheckPing() async {
    for (final deviceId in List<String>.from(_readChar.keys)) {
      final char = _readChar[deviceId];
      if (char == null) continue;

      try {
        await char.read();
        _pingFailureCount[deviceId] = 0;
        debugPrint('[BLE] Connection-check OK → $deviceId');
      } catch (e) {
        final failures = (_pingFailureCount[deviceId] ?? 0) + 1;
        _pingFailureCount[deviceId] = failures;
        debugPrint(
          '[BLE] Connection-check FAIL ($failures/$_maxConsecutiveFailures)'
          ' → $deviceId: $e',
        );
        if (failures >= _maxConsecutiveFailures) {
          debugPrint('[BLE] Presumed OFF → synthesising disconnect: $deviceId');
          _synthesiseDisconnect(deviceId);
        }
      }
    }
  }

  // ── Timer 2: firmware inactivity-reset write ping ────────────────────────

  Future<void> _firmwareKeepAlivePing() async {
    for (final deviceId in List<String>.from(_writeChar.keys)) {
      final char = _writeChar[deviceId];
      if (char == null) continue;

      try {
        // Write a single 0x00 byte with no response required.
        // The content doesn't matter — any write reaching the application
        // processor resets the firmware's inactivity counter.
        // withResponse: false avoids an extra round-trip and is less
        // likely to be rejected by an unknown characteristic.
        await char.write([0x00], withResponse: false);
        debugPrint('[BLE] Firmware keepalive write OK → $deviceId');
      } catch (e) {
        // Write failed — try with response as fallback.
        try {
          await char.write([0x00], withResponse: true);
          debugPrint(
            '[BLE] Firmware keepalive write OK (with response) → $deviceId',
          );
        } catch (e2) {
          debugPrint('[BLE] Firmware keepalive write FAILED → $deviceId: $e2');
          // Connection-check timer will handle disconnect detection;
          // don't duplicate logic here.
        }
      }
    }
  }

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

  void _clearDeviceState(String deviceId) {
    _readChar.remove(deviceId);
    _writeChar.remove(deviceId);
    _pingFailureCount.remove(deviceId);
  }

  // ══════════════════════════════════════════════
  // SECTION 2 – SCANNING
  // ══════════════════════════════════════════════

  Stream<BleDevice> get scanStream => UniversalBle.scanStream;

  Future<void> stopScanIfActive() async {
    try {
      if (await UniversalBle.isScanning()) {
        await UniversalBle.stopScan();
        debugPrint('[BLE] Stopped residual scan');
      }
    } catch (_) {}
  }

  Future<void> startScan({List<String> withServices = const []}) async {
    await stopScanIfActive();
    final filter = withServices.isNotEmpty
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
    // Slots are registered; chars resolved after discoverServices().
    _readChar[device.deviceId] = null;
    _writeChar[device.deviceId] = null;
    _pingFailureCount[device.deviceId] = 0;
    debugPrint('[BLE] Connected');
  }

  Future<void> disconnect(BleDevice device) async {
    debugPrint('[BLE] Disconnecting from ${device.name ?? device.deviceId}');
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

    // Resolve both chars and cache them for the two timers.
    _readChar[device.deviceId] = _resolveReadChar(device.deviceId, services);
    _writeChar[device.deviceId] = _resolveWriteChar(device.deviceId, services);
    _pingFailureCount[device.deviceId] = 0;

    debugPrint(
      '[BLE] Keepalive chars resolved for ${device.deviceId} — '
      'read: ${_readChar[device.deviceId]?.uuid ?? "none"}, '
      'write: ${_writeChar[device.deviceId]?.uuid ?? "none"}',
    );

    return services;
  }

  /// Finds the best characteristic for read-based dead-device detection.
  ///
  /// Priority:
  ///   1. Non-GAP/GATT service readable char  ← reaches application processor
  ///   2. Generic Access 0x2A00               ← controller-level fallback
  BleCharacteristic? _resolveReadChar(
    String deviceId,
    List<BleService> services,
  ) {
    // Skip standard GAP (0x1800) and GATT (0x1801) services — those are
    // answered by the BLE controller chip, not the firmware.
    final appServices = services.where(
      (s) =>
          !s.uuid.toUpperCase().contains('1800') &&
          !s.uuid.toUpperCase().contains('1801'),
    );

    for (final svc in appServices) {
      for (final ch in svc.characteristics) {
        if (ch.properties.contains(CharacteristicProperty.read)) {
          debugPrint('[BLE] Read char (app layer): ${ch.uuid}');
          return ch;
        }
      }
    }

    // Fallback to GAP Device Name if no application char found.
    for (final svc in services) {
      for (final ch in svc.characteristics) {
        if (ch.properties.contains(CharacteristicProperty.read)) {
          debugPrint('[BLE] Read char (GAP fallback): ${ch.uuid}');
          return ch;
        }
      }
    }

    debugPrint('[BLE] No readable char found for $deviceId');
    return null;
  }

  /// Finds the best characteristic for write-based firmware keepalive.
  ///
  /// Priority:
  ///   1. Non-GAP/GATT writable-without-response char  ← fastest, no ACK needed
  ///   2. Non-GAP/GATT writable-with-response char
  ///   3. Any writable char (including GAP) as last resort
  BleCharacteristic? _resolveWriteChar(
    String deviceId,
    List<BleService> services,
  ) {
    final appServices = services.where(
      (s) =>
          !s.uuid.toUpperCase().contains('1800') &&
          !s.uuid.toUpperCase().contains('1801'),
    );

    // Pass 1: write-without-response on application services.
    for (final svc in appServices) {
      for (final ch in svc.characteristics) {
        if (ch.properties.contains(
          CharacteristicProperty.writeWithoutResponse,
        )) {
          debugPrint('[BLE] Write char (app, no-response): ${ch.uuid}');
          return ch;
        }
      }
    }

    // Pass 2: write-with-response on application services.
    for (final svc in appServices) {
      for (final ch in svc.characteristics) {
        if (ch.properties.contains(CharacteristicProperty.write)) {
          debugPrint('[BLE] Write char (app, with-response): ${ch.uuid}');
          return ch;
        }
      }
    }

    // Pass 3: any writable char anywhere.
    for (final svc in services) {
      for (final ch in svc.characteristics) {
        if (ch.properties.contains(
              CharacteristicProperty.writeWithoutResponse,
            ) ||
            ch.properties.contains(CharacteristicProperty.write)) {
          debugPrint('[BLE] Write char (fallback): ${ch.uuid}');
          return ch;
        }
      }
    }

    debugPrint(
      '[BLE] No writable char found for $deviceId — '
      'firmware keepalive will be inactive until vendor UUID is provided',
    );
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
    _connectionCheckTimer?.cancel();
    _firmwareKeepAliveTimer?.cancel();
    _connectionCheckTimer = null;
    _firmwareKeepAliveTimer = null;
    _readChar.clear();
    _writeChar.clear();
    _pingFailureCount.clear();
    _connectionEventController.close();
  }
}
