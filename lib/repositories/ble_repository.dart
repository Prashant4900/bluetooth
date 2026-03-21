import 'dart:async';

import 'package:bluetooth/bluetooth_service.dart';
import 'package:bluetooth/models/ble_log_entry.dart';
import 'package:bluetooth/repositories/ble_log_repository.dart';
import 'package:bluetooth/services/background_service_bridge.dart';
import 'package:bluetooth/storage/pairing_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Events & enums
// ─────────────────────────────────────────────────────────────────────────────

enum RepoConnectionStatus { connecting, connected, disconnected }

class RepoConnectionEvent {
  final BleDevice device;
  final RepoConnectionStatus status;
  RepoConnectionEvent(this.device, this.status);
}

class RepoPairingEvent {
  final String deviceId;
  final bool isLoading;
  final bool? isPaired;
  RepoPairingEvent(this.deviceId, this.isLoading, {this.isPaired});
}

// ─────────────────────────────────────────────────────────────────────────────
// BleRepository
// ─────────────────────────────────────────────────────────────────────────────

class BleRepository {
  final BluetoothService ble = BluetoothService();
  final BleLogRepository logRepository;

  BleRepository({required this.logRepository});

  // ── Public state ─────────────────────────────────────────────────────────

  Set<String> _pairedDeviceIds = {};
  Set<String> get pairedDeviceIds => Set.unmodifiable(_pairedDeviceIds);

  final List<BleDevice> _discoveredDevices = [];
  List<BleDevice> get discoveredDevices =>
      List.unmodifiable(_discoveredDevices);

  bool isScanning = false;

  final Map<String, BleDevice> _connectedDevices = {};
  Map<String, BleDevice> get connectedDevices =>
      Map.unmodifiable(_connectedDevices);

  // ── Streams ──────────────────────────────────────────────────────────────

  final _pairedDevicesController = StreamController<Set<String>>.broadcast();
  Stream<Set<String>> get onPairedDevicesChanged =>
      _pairedDevicesController.stream;

  final _scanStateController = StreamController<void>.broadcast();
  Stream<void> get onScanStateChanged => _scanStateController.stream;

  final _connectionStateController =
      StreamController<RepoConnectionEvent>.broadcast();
  Stream<RepoConnectionEvent> get onConnectionStateChanged =>
      _connectionStateController.stream;

  final _errorController = StreamController<String>.broadcast();
  Stream<String> get onError => _errorController.stream;

  final _pairingEventController =
      StreamController<RepoPairingEvent>.broadcast();
  Stream<RepoPairingEvent> get onPairingEvent => _pairingEventController.stream;

  // ── Internal subscriptions & state ───────────────────────────────────────

  StreamSubscription<BleConnectionEvent>? _globalConnectionSub;
  StreamSubscription<BleDevice>? _scanSub;
  final Set<String> _connectingDevices = {};
  final Map<String, StreamSubscription<Uint8List>> _notifySubs = {};

  // ✅ FIX: Cache the last-seen BleDevice per deviceId so we can reconnect
  // even after the device is removed from _discoveredDevices on scan restart.
  final Map<String, BleDevice> _seenDevices = {};

  // ✅ FIX: Guard against overlapping reconnect attempts triggered by both
  // the foreground disconnect handler and the background task.
  final Set<String> _reconnecting = {};

  // ── Initialization ───────────────────────────────────────────────────────

  Future<void> initialize() async {
    try {
      await ble.stopScanIfActive();
      final availState = await ble.initialize();
      await _loadPairedDevices();
      _listenToConnectionEvents();
      if (availState == AvailabilityState.poweredOn) await startScan();
    } catch (e) {
      _errorController.add(e.toString());
    }
  }

  Future<void> _loadPairedDevices() async {
    _pairedDeviceIds = await PairingStorage.loadPairedIds();
    _pairedDevicesController.add(Set.unmodifiable(_pairedDeviceIds));
  }

  /// Subscribes to the global BLE connection stream and handles
  /// connect / disconnect events.
  void _listenToConnectionEvents() {
    _globalConnectionSub?.cancel();
    _globalConnectionSub = ble.connectionStateStream.listen((event) async {
      // ✅ FIX: Do NOT filter on device name here.
      //
      // Previously this code looked up `knownName` from _discoveredDevices
      // and then checked `knownName?.startsWith('LMNP') != true`, which
      // silently dropped every event for background-connected devices
      // (where knownName is null) and every event that arrived before
      // the device appeared in _discoveredDevices.
      //
      // Instead, only filter on whether the device is in our paired set.
      // The name check is still done, but falls back to _seenDevices so
      // background connections are handled correctly.
      if (!_pairedDeviceIds.contains(event.deviceId)) return;

      // Resolve the best device name we have, checking multiple caches.
      final knownName =
          _connectedDevices[event.deviceId]?.name ??
          _seenDevices[event.deviceId]?.name ??
          _discoveredDevices
              .cast<BleDevice?>()
              .firstWhere(
                (d) => d?.deviceId == event.deviceId,
                orElse: () => null,
              )
              ?.name;

      // ✅ FIX: Additional guard — only process LMNP devices, but now using
      // the enriched name lookup above so null names don't cause false misses.
      if (knownName != null && !knownName.startsWith('LMNP')) return;

      final device =
          _seenDevices[event.deviceId] ??
          BleDevice(deviceId: event.deviceId, name: knownName);

      _connectingDevices.remove(event.deviceId);
      _reconnecting.remove(event.deviceId);

      if (event.isConnected) {
        await _handleConnected(device, event.error);
      } else {
        await _handleDisconnected(device, event.error);
      }
    });
  }

  Future<void> _handleConnected(BleDevice device, String? error) async {
    _connectedDevices[device.deviceId] = device;

    // Add to discovered list if it arrived via a background connection.
    if (!_discoveredDevices.any((d) => d.deviceId == device.deviceId)) {
      _discoveredDevices.add(device);
      _scanStateController.add(null);
    }

    _connectionStateController.add(
      RepoConnectionEvent(device, RepoConnectionStatus.connected),
    );

    // ✅ FIX: Trigger service discovery on connect so BluetoothService can
    // resolve and cache the keepalive characteristic immediately. Without
    // this, the foreground keepalive timer has no char to ping.
    _discoverServicesForKeepalive(device);

    await _log(
      device,
      'Connected to "${device.name ?? device.deviceId}"'
      '${error != null ? " ($error)" : ""}',
    );
    await logRepository.loadDeviceLogs(device.deviceId);
  }

  Future<void> _handleDisconnected(BleDevice device, String? error) async {
    _connectedDevices.remove(device.deviceId);
    _connectionStateController.add(
      RepoConnectionEvent(device, RepoConnectionStatus.disconnected),
    );

    await _log(
      device,
      error != null
          ? 'Disconnected from "${device.name ?? device.deviceId}" — $error'
          : 'Disconnected from "${device.name ?? device.deviceId}"',
    );

    // ✅ FIX: Attempt foreground reconnect when the app is running.
    // The background task handles reconnect when the app is not in the
    // foreground, but when the app IS open we need to do it here.
    // Only attempt if the device is still in our paired set and we're
    // not already reconnecting.
    if (_pairedDeviceIds.contains(device.deviceId) &&
        !_reconnecting.contains(device.deviceId)) {
      _scheduleReconnect(device);
    }
  }

  /// Schedules a reconnect attempt with a short back-off delay.
  /// Uses [_reconnecting] as a guard so only one attempt is in flight at a time.
  void _scheduleReconnect(BleDevice device, {int attemptNumber = 1}) {
    if (_reconnecting.contains(device.deviceId)) return;
    if (!_pairedDeviceIds.contains(device.deviceId)) return;

    _reconnecting.add(device.deviceId);

    // Back-off: 1 s → 2 s → 4 s → 8 s → cap at 15 s.
    final delaySeconds = attemptNumber <= 1
        ? 1
        : (1 << (attemptNumber - 1)).clamp(1, 15);

    debugPrint(
      '[BLE] Scheduling reconnect for ${device.name ?? device.deviceId} '
      'in ${delaySeconds}s (attempt $attemptNumber)',
    );

    Future.delayed(Duration(seconds: delaySeconds), () async {
      // Bail out if the device was unpaired or already reconnected
      // while we were waiting.
      if (!_pairedDeviceIds.contains(device.deviceId)) {
        _reconnecting.remove(device.deviceId);
        return;
      }
      if (_connectedDevices.containsKey(device.deviceId)) {
        _reconnecting.remove(device.deviceId);
        return;
      }

      try {
        // Check the OS-level connection state first — the background task
        // may have reconnected already.
        final state = await UniversalBle.getConnectionState(device.deviceId);
        if (state == BleConnectionState.connected) {
          debugPrint(
            '[BLE] ${device.name ?? device.deviceId} already connected at OS level — syncing',
          );
          _reconnecting.remove(device.deviceId);
          // Sync state without emitting a duplicate connect call.
          _connectedDevices[device.deviceId] = device;
          _connectionStateController.add(
            RepoConnectionEvent(device, RepoConnectionStatus.connected),
          );
          _discoverServicesForKeepalive(device);
          return;
        }
      } catch (_) {
        // getConnectionState unavailable on some platforms — proceed to connect.
      }

      _reconnecting.remove(device.deviceId);
      await _log(
        device,
        '[FG] Reconnecting to "${device.name ?? device.deviceId}" '
        '(attempt $attemptNumber)…',
      );
      await connect(device);

      // If connect() didn't result in a confirmed connection within a few
      // seconds, schedule another attempt with increasing back-off.
      await Future.delayed(const Duration(seconds: 5));
      if (!_connectedDevices.containsKey(device.deviceId) &&
          _pairedDeviceIds.contains(device.deviceId) &&
          !_reconnecting.contains(device.deviceId)) {
        _scheduleReconnect(device, attemptNumber: attemptNumber + 1);
      }
    });
  }

  // ── Service discovery (keepalive integration) ─────────────────────────────

  /// Discovers services and lets [BluetoothService] cache the keepalive char.
  /// Called automatically after every successful connection.
  /// Errors are swallowed — keepalive is best-effort, not critical path.
  void _discoverServicesForKeepalive(BleDevice device) {
    // Run fire-and-forget; don't await so we don't block _handleConnected.
    Future.microtask(() async {
      try {
        // ✅ This calls the updated BluetoothService.discoverServices which
        // now resolves and caches the keepalive characteristic.
        final services = await ble.discoverServices(device);
        await _log(
          device,
          'Discovered ${services.length} service(s): '
          '${services.map((s) => s.uuid).join(", ")}',
        );
      } catch (e) {
        debugPrint(
          '[BLE] Service discovery failed for '
          '${device.name ?? device.deviceId}: $e',
        );
      }
    });
  }

  // ── Scanning ─────────────────────────────────────────────────────────────

  Future<void> startScan({List<String> withServices = const []}) async {
    // ✅ FIX: Only remove non-paired AND non-connected devices from the list.
    // Previously ALL non-paired devices were removed, which could wipe entries
    // for devices in the middle of a pairing flow.
    _discoveredDevices.removeWhere(
      (d) =>
          !_pairedDeviceIds.contains(d.deviceId) &&
          !_connectedDevices.containsKey(d.deviceId),
    );
    isScanning = true;
    _scanStateController.add(null);

    try {
      _scanSub?.cancel();
      _scanSub = ble.scanStream.listen(_onDeviceDiscovered);
      await ble.startScan(withServices: withServices);
    } catch (e) {
      _errorController.add(e.toString());
    }
  }

  Future<void> stopScan() async {
    try {
      await ble.stopScan();
      _scanSub?.cancel();
      isScanning = false;
      _scanStateController.add(null);
    } catch (e) {
      _errorController.add(e.toString());
    }
  }

  /// Called for each advertisement packet received during a scan.
  Future<void> _onDeviceDiscovered(BleDevice device) async {
    if (device.name?.startsWith('LMNP') != true) return;

    // ✅ FIX: Always update _seenDevices, even for known devices, so we
    // have a fresh reference for reconnect attempts.
    _seenDevices[device.deviceId] = device;

    // Log only the first time we see this device in the current scan session.
    if (!_discoveredDevices.any((d) => d.deviceId == device.deviceId)) {
      _discoveredDevices.add(device);
      _scanStateController.add(null);
      await _log(
        device,
        'Discovered: "${device.name ?? "Unknown"}"'
        '${device.rssi != null ? " — RSSI ${device.rssi} dBm" : ""}',
      );
    }

    final isPaired = _pairedDeviceIds.contains(device.deviceId);
    final isHandled =
        _connectedDevices.containsKey(device.deviceId) ||
        _connectingDevices.contains(device.deviceId) ||
        _reconnecting.contains(
          device.deviceId,
        ); // ✅ FIX: also check _reconnecting

    if (!isPaired || isHandled) return;

    // Check the OS-level connection state before sending a connect request.
    try {
      final state = await UniversalBle.getConnectionState(device.deviceId);
      if (state == BleConnectionState.connected) {
        debugPrint(
          '[BLE] ${device.name ?? device.deviceId} already connected at OS level — syncing state',
        );
        _connectedDevices[device.deviceId] = device;
        _connectingDevices.remove(device.deviceId);
        _connectionStateController.add(
          RepoConnectionEvent(device, RepoConnectionStatus.connected),
        );
        _discoverServicesForKeepalive(device);
        await _log(
          device,
          'Already connected to "${device.name ?? device.deviceId}" — synced state',
        );
        return;
      }
    } catch (_) {
      // Platform doesn't support getConnectionState — fall through to connect.
    }

    connect(device, delay: const Duration(milliseconds: 800));
  }

  // ── Connection ───────────────────────────────────────────────────────────

  Future<void> connect(
    BleDevice device, {
    Duration delay = Duration.zero,
  }) async {
    if (_connectingDevices.contains(device.deviceId) ||
        _connectedDevices.containsKey(device.deviceId))
      return;

    _connectingDevices.add(device.deviceId);

    if (delay > Duration.zero) {
      await Future.delayed(delay);
      if (_connectedDevices.containsKey(device.deviceId)) {
        _connectingDevices.remove(device.deviceId);
        return;
      }
    }

    _connectionStateController.add(
      RepoConnectionEvent(device, RepoConnectionStatus.connecting),
    );
    await _log(device, 'Connecting to "${device.name ?? device.deviceId}"…');

    try {
      await ble.connect(device);
      // _listenToConnectionEvents handles the confirmation and logging.
    } catch (e) {
      _connectingDevices.remove(device.deviceId);
      await _log(device, 'Connection failed: $e');
      _errorController.add(e.toString());
    }
  }

  Future<void> disconnect(BleDevice device) async {
    if (!_connectedDevices.containsKey(device.deviceId)) return;

    // ✅ FIX: Clear reconnect guard so an intentional disconnect doesn't
    // trigger an automatic reconnect attempt.
    _reconnecting.add(device.deviceId);

    try {
      await ble.disconnect(device);
      // _listenToConnectionEvents handles confirmation.
    } catch (e) {
      _reconnecting.remove(device.deviceId);
      _errorController.add(e.toString());
    } finally {
      // Remove the guard after a short delay so _handleDisconnected fires
      // first and sees the guard, then we release it.
      Future.delayed(const Duration(seconds: 2), () {
        _reconnecting.remove(device.deviceId);
      });
    }
  }

  // ── GATT operations ──────────────────────────────────────────────────────

  Future<void> discoverServices(BleDevice device) async {
    try {
      // ✅ Delegates to BluetoothService which now caches the keepalive char.
      final services = await ble.discoverServices(device);
      await _log(
        device,
        'Discovered ${services.length} service(s): '
        '${services.map((s) => s.uuid).join(", ")}',
      );
    } catch (e) {
      _errorController.add(e.toString());
    }
  }

  Future<void> read(
    BleCharacteristic characteristic, {
    String? deviceId,
    String? deviceName,
  }) async {
    try {
      await ble.read(characteristic);
      if (deviceId != null) {
        await _logRaw(deviceId, deviceName, 'Read from ${characteristic.uuid}');
      }
    } catch (e) {
      _errorController.add(e.toString());
    }
  }

  Future<void> write(
    BleCharacteristic characteristic,
    List<int> data, {
    bool withResponse = true,
    String? deviceId,
    String? deviceName,
  }) async {
    try {
      await ble.write(characteristic, data, withResponse: withResponse);
      if (deviceId != null) {
        await _logRaw(
          deviceId,
          deviceName,
          'Write${withResponse ? " (with response)" : " (no response)"} '
          'to ${characteristic.uuid}',
        );
      }
    } catch (e) {
      _errorController.add(e.toString());
    }
  }

  Future<void> subscribe(
    BleCharacteristic characteristic, {
    bool useIndications = false,
    String? deviceId,
    String? deviceName,
  }) async {
    try {
      final subKey = characteristic.uuid.toString();
      _notifySubs[subKey]?.cancel();

      void handler(Uint8List data) {
        debugPrint('[BLE] Data received: ${data.length} byte(s)');
      }

      _notifySubs[subKey] = useIndications
          ? await ble.subscribeIndications(characteristic, handler)
          : await ble.subscribeNotifications(characteristic, handler);

      if (deviceId != null) {
        await _logRaw(
          deviceId,
          deviceName,
          'Subscribed to ${useIndications ? "indications" : "notifications"} '
          'on ${characteristic.uuid}',
        );
      }
    } catch (e) {
      _errorController.add(e.toString());
    }
  }

  Future<void> unsubscribe(BleCharacteristic characteristic) async {
    try {
      await ble.unsubscribe(characteristic);
      final subKey = characteristic.uuid.toString();
      _notifySubs[subKey]?.cancel();
      _notifySubs.remove(subKey);
    } catch (e) {
      _errorController.add(e.toString());
    }
  }

  // ── Pairing ──────────────────────────────────────────────────────────────

  Future<void> pairDevice(
    BleDevice device, {
    BleCommand? pairingCommand,
  }) async {
    _pairingEventController.add(RepoPairingEvent(device.deviceId, true));
    await _log(
      device,
      'Pairing requested with "${device.name ?? device.deviceId}"…',
    );

    try {
      await ble.pair(device, pairingCommand: pairingCommand);
      await PairingStorage.savePaired(device.deviceId);
      _pairedDeviceIds = await PairingStorage.loadPairedIds();
      await _log(device, 'Paired successfully & saved to storage');
      await BackgroundServiceBridge.start();
      _pairedDevicesController.add(Set.unmodifiable(_pairedDeviceIds));
      _pairingEventController.add(
        RepoPairingEvent(device.deviceId, false, isPaired: true),
      );
      connect(device);
    } catch (e) {
      await _log(device, 'Pair failed: $e');
      _errorController.add(e.toString());
    }
  }

  Future<void> unpairDevice(BleDevice device) async {
    _pairingEventController.add(RepoPairingEvent(device.deviceId, true));
    await _log(
      device,
      'Unpair requested for "${device.name ?? device.deviceId}"…',
    );

    try {
      // ✅ FIX: Set the reconnect guard BEFORE disconnecting so that
      // _handleDisconnected doesn't schedule a reconnect during unpairing.
      _reconnecting.add(device.deviceId);

      if (_connectedDevices.containsKey(device.deviceId)) {
        await ble.disconnect(device);
        _connectedDevices.remove(device.deviceId);
        debugPrint(
          '[BLE] Disconnected before unpairing '
          '${device.name ?? device.deviceId}',
        );
      }

      await ble.unpair(device);
      await PairingStorage.removePaired(device.deviceId);
      _pairedDeviceIds = await PairingStorage.loadPairedIds();
      await _log(device, 'Unpaired & removed from storage');

      // ✅ FIX: Clean up all tracking state for this device.
      _seenDevices.remove(device.deviceId);
      _reconnecting.remove(device.deviceId);

      if (_pairedDeviceIds.isEmpty) await BackgroundServiceBridge.stop();

      _pairedDevicesController.add(Set.unmodifiable(_pairedDeviceIds));
      _pairingEventController.add(
        RepoPairingEvent(device.deviceId, false, isPaired: false),
      );
    } catch (e) {
      _reconnecting.remove(device.deviceId);
      await _log(device, 'Unpair failed: $e');
      _errorController.add(e.toString());
    }
  }

  // ── Cleanup ──────────────────────────────────────────────────────────────

  void dispose() {
    _globalConnectionSub?.cancel();
    _scanSub?.cancel();
    for (final sub in _notifySubs.values) sub.cancel();
    _pairedDevicesController.close();
    _scanStateController.close();
    _connectionStateController.close();
    _errorController.close();
    _pairingEventController.close();
    ble.dispose(); // ✅ FIX: Cancel the foreground keepalive timer.
  }

  // ── Logging helpers ──────────────────────────────────────────────────────

  Future<void> _log(BleDevice device, String message) => logRepository.addLog(
    BleLogEntry.system(
      deviceId: device.deviceId,
      deviceName: device.name,
      message: message,
    ),
  );

  Future<void> _logRaw(String deviceId, String? deviceName, String message) =>
      logRepository.addLog(
        BleLogEntry.system(
          deviceId: deviceId,
          deviceName: deviceName,
          message: message,
        ),
      );
}
