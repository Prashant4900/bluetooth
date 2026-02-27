import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:bluetooth/bluetooth_service.dart';
import 'package:bluetooth/models/ble_log_entry.dart';
import 'package:bluetooth/services/background_service_bridge.dart';
import 'package:bluetooth/services/notification_service.dart';
import 'package:bluetooth/storage/log_storage.dart';
import 'package:bluetooth/storage/pairing_storage.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

part 'bluetooth_state.dart';

class BluetoothCubit extends Cubit<BluetoothState> {
  BluetoothCubit() : super(BluetoothInitial());

  final BluetoothService _ble = BluetoothService();

  // In-memory cache of paired device IDs (mirrored from SharedPreferences)
  Set<String> _pairedDeviceIds = {};

  /// Convenience getter for the UI.
  Set<String> get pairedDeviceIds => Set.unmodifiable(_pairedDeviceIds);

  // In-memory log buffer per device
  final Map<String, List<BleLogEntry>> _deviceLogs = {};

  // UI state for filtering
  bool _showOnlyLmnp = false;
  bool get showOnlyLmnp => _showOnlyLmnp;

  void toggleLmnpFilter() {
    _showOnlyLmnp = !_showOnlyLmnp;
    // Re-emit state to trigger UI rebuild
    if (state is BluetoothScanResult) {
      // Refresh scan list
      emit(BluetoothScanResult(List.unmodifiable(_discoveredDevices)));
    } else {
      // Just emit current state to force rebuild if not scanning
      emit(
        BluetoothLoading(),
      ); // tiny placeholder to force toggle, then back to real
      emit(state);
    }
    // Also broadcast logs updated so the global log screen refreshes
    emit(BluetoothLogsUpdated('all', allLogs));
  }

  /// Return in-memory logs for [deviceId] (empty list if none yet).
  List<BleLogEntry> logsFor(String deviceId) =>
      List.unmodifiable(_deviceLogs[deviceId] ?? []);

  // ══════════════════════════════════════════════
  // SECTION 1 – INITIALIZE
  // ══════════════════════════════════════════════

  StreamSubscription<AvailabilityState>? _availabilitySub;
  StreamSubscription<BleConnectionEvent>? _globalConnectionSub;

  /// Initialise BLE stack and start listening for availability changes.
  Future<void> initialize() async {
    emit(BluetoothLoading());
    try {
      // Clean up any scan left over from a previous session / hot restart
      await _ble.stopScanIfActive();

      final availState = await _ble.initialize();

      // Keep listening for future availability changes.
      _availabilitySub?.cancel();
      _availabilitySub = _ble.availabilityStream.listen((state) {
        emit(BluetoothAvailabilityChanged(state));
      });

      // Load stored paired device IDs before emitting initialized.
      await _loadPairedDevices();

      // ── Global connection state listener ─────────────────────────
      // Fires for ANY device: GATT devices we connect to explicitly
      // AND system-paired devices (earbuds, headsets) that connect or
      // disconnect on their own (e.g. opening/closing the case, picking
      // up/ending a call).
      _globalConnectionSub?.cancel();
      _globalConnectionSub = _ble.connectionStateStream.listen((event) {
        final knownName = _discoveredDevices
            .cast<BleDevice?>()
            .firstWhere(
              (d) => d?.deviceId == event.deviceId,
              orElse: () => null,
            )
            ?.name;

        if (event.isConnected) {
          // Try to construct a BleDevice to update the state
          final dev = BleDevice(deviceId: event.deviceId, name: knownName);
          _connectedDevice = dev;
          emit(BluetoothConnected(dev));

          _log(
            BleLogEntry.system(
              deviceId: event.deviceId,
              deviceName: knownName,
              type: LogType.connect,
              message:
                  'Connected'
                  '${event.error != null ? " (${event.error})" : ""}',
            ),
          );
        } else {
          final dev = BleDevice(deviceId: event.deviceId, name: knownName);
          emit(BluetoothDisconnected(dev));

          _log(
            BleLogEntry.system(
              deviceId: event.deviceId,
              deviceName: knownName,
              type: LogType.disconnect,
              message: event.error != null
                  ? 'Disconnected — ${event.error}'
                  : 'Disconnected',
            ),
          );
          // Clear connected device if it matches
          if (_connectedDevice?.deviceId == event.deviceId) {
            _connectedDevice = null;
          }
          // Resume scanning to catch the device when it returns
          startScan();
        }
      });
      emit(BluetoothInitialized(availState));

      // Auto-start scanning if BLE is already on
      if (availState == AvailabilityState.poweredOn) {
        await startScan();
        // Also query devices already connected at the OS level
        // (earbuds paired via system settings don't appear in scan).
        await _checkSystemDevices();
      }
    } catch (e) {
      emit(BluetoothError(e.toString()));
    }
  }

  /// Query system-connected devices (paired via OS, not this app's scan).
  /// Logs any that are in our paired list so the user sees the connection.
  Future<void> _checkSystemDevices() async {
    try {
      final systemDevices = await _ble.getSystemDevices();
      for (final device in systemDevices) {
        // Add to discovered list so connection events can resolve the name
        if (!_discoveredDevices.any((d) => d.deviceId == device.deviceId)) {
          _discoveredDevices.add(device);
        }
        // Log the fact they are already connected
        await _log(
          BleLogEntry.system(
            deviceId: device.deviceId,
            deviceName: device.name,
            type: LogType.connect,
            message: 'Already connected (system/OS paired device)',
          ),
        );
      }
      if (systemDevices.isNotEmpty) {
        emit(BluetoothScanResult(List.unmodifiable(_discoveredDevices)));
      }
    } catch (_) {
      // Best-effort — ignore if unsupported
    }
  }

  /// Load paired device IDs from SharedPreferences and update cache.
  Future<void> _loadPairedDevices() async {
    _pairedDeviceIds = await PairingStorage.loadPairedIds();
    emit(BluetoothPairedDevicesLoaded(Set.unmodifiable(_pairedDeviceIds)));
    debugPrint(
      '[BLE] Loaded ${_pairedDeviceIds.length} stored paired device(s)',
    );
  }

  // ══════════════════════════════════════════════
  // SECTION 8 – LOGGING
  // ══════════════════════════════════════════════

  /// Core log helper: writes to memory, persists, and emits state.
  Future<void> _log(BleLogEntry entry) async {
    final list = _deviceLogs.putIfAbsent(entry.deviceId, () => []);
    list.add(entry);
    emit(BluetoothLogsUpdated(entry.deviceId, List.unmodifiable(list)));
    // Also notify listeners watching 'all' logs
    emit(BluetoothLogsUpdated('all', allLogs));
    // Persist asynchronously (fire-and-forget; UI already updated)
    LogStorage.appendLog(entry).ignore();
  }

  /// Load historical logs for [deviceId] from SharedPreferences into memory
  /// and emit [BluetoothLogsUpdated].
  Future<void> loadDeviceLogs(String deviceId) async {
    final stored = await LogStorage.loadLogs(deviceId);
    // Merge: stored first, then any in-memory newer entries
    final inMem = _deviceLogs[deviceId] ?? [];
    final merged = <BleLogEntry>[...stored];
    for (final e in inMem) {
      if (!merged.any((s) => s.id == e.id)) merged.add(e);
    }
    merged.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    _deviceLogs[deviceId] = merged;
    emit(BluetoothLogsUpdated(deviceId, List.unmodifiable(merged)));
  }

  /// Load historical logs for all devices that have stored logs.
  Future<void> loadAllLogs() async {
    final deviceIds = await LogStorage.getDevicesWithLogs();

    // Attempt to load logs for all devices that have storage entries
    await Future.wait(deviceIds.map((id) => loadDeviceLogs(id)));

    // We emit with a special 'all' ID to trigger UI updates for screens watching all logs
    emit(BluetoothLogsUpdated('all', allLogs));
  }

  /// Get a single combined list of all logs across all devices, sorted chronologically.
  List<BleLogEntry> get allLogs {
    final all = <BleLogEntry>[];
    for (final logs in _deviceLogs.values) {
      all.addAll(logs);
    }
    all.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return List.unmodifiable(all);
  }

  /// Clear in-memory and persisted logs for [deviceId].
  Future<void> clearDeviceLogs(String deviceId) async {
    _deviceLogs.remove(deviceId);
    await LogStorage.clearLogs(deviceId);
    emit(BluetoothLogsUpdated(deviceId, const []));
    // Also notify listeners watching 'all' logs
    emit(BluetoothLogsUpdated('all', allLogs));
  }

  // ══════════════════════════════════════════════
  // SECTION 2 – SCANNING
  // ══════════════════════════════════════════════

  StreamSubscription<BleDevice>? _scanSub;
  final List<BleDevice> _discoveredDevices = [];
  List<BleDevice> get discoveredDevices =>
      List.unmodifiable(_discoveredDevices);

  /// Start scanning. Already-seen devices are de-duplicated by ID.
  Future<void> startScan({List<String> withServices = const []}) async {
    _discoveredDevices.clear();
    emit(BluetoothScanning());

    try {
      _scanSub?.cancel();
      _scanSub = _ble.scanStream.listen((device) {
        final exists = _discoveredDevices.any(
          (d) => d.deviceId == device.deviceId,
        );
        if (!exists) {
          _discoveredDevices.add(device);
          emit(BluetoothScanResult(List.unmodifiable(_discoveredDevices)));
          // Log each new device discovery
          _log(
            BleLogEntry.system(
              deviceId: device.deviceId,
              deviceName: device.name,
              type: LogType.scan,
              message:
                  'Discovered: "${device.name ?? "Unknown"}"'
                  '${device.rssi != null ? " — RSSI ${device.rssi} dBm" : ""}',
            ),
          );

          // ── In-app auto-reconnect ──────────────────────────────────
          // If this device is in our paired list and we are not already
          // connecting/connected to it, auto-connect immediately.
          if (_pairedDeviceIds.contains(device.deviceId) &&
              state is! BluetoothConnecting &&
              state is! BluetoothConnected) {
            debugPrint(
              '[BLE] Auto-connecting to paired device: ${device.deviceId}',
            );
            connect(device);
          }
        }
      });

      await _ble.startScan(withServices: withServices);
    } catch (e) {
      emit(BluetoothError(e.toString()));
    }
  }

  /// Stop scanning.
  Future<void> stopScan() async {
    try {
      await _ble.stopScan();
      _scanSub?.cancel();
      emit(BluetoothScanStopped());
    } catch (e) {
      emit(BluetoothError(e.toString()));
    }
  }

  // ══════════════════════════════════════════════
  // SECTION 3 – CONNECTION
  // ══════════════════════════════════════════════

  BleDevice? _connectedDevice;
  BleDevice? get connectedDevice => _connectedDevice;
  StreamSubscription<bool>? _connectionSub;

  /// Connect to [device] and start monitoring its connection state.
  Future<void> connect(BleDevice device) async {
    emit(BluetoothConnecting(device));
    await _log(
      BleLogEntry.system(
        deviceId: device.deviceId,
        deviceName: device.name,
        type: LogType.connect,
        message: 'Connecting to "${device.name ?? device.deviceId}"…',
      ),
    );
    try {
      await _ble.connect(device);
      _connectedDevice = device;

      _connectionSub?.cancel();
      _connectionSub = _ble.connectionStream(device).listen((isConnected) {
        if (isConnected) {
          emit(BluetoothConnected(device));
          _log(
            BleLogEntry.system(
              deviceId: device.deviceId,
              deviceName: device.name,
              type: LogType.connect,
              message: 'Connected to "${device.name ?? device.deviceId}"',
            ),
          );
        } else {
          emit(BluetoothDisconnected(device));
          _connectedDevice = null;
          _log(
            BleLogEntry.system(
              deviceId: device.deviceId,
              deviceName: device.name,
              type: LogType.disconnect,
              message: 'Disconnected from "${device.name ?? device.deviceId}"',
            ),
          );
          NotificationService.showNotification(
            id: device.deviceId.hashCode ^ 3,
            title: 'Device Disconnected',
            body: 'Lost connection to ${device.name ?? device.deviceId}',
          );
        }
      });

      emit(BluetoothConnected(device));
    } catch (e) {
      await _log(
        BleLogEntry.system(
          deviceId: device.deviceId,
          deviceName: device.name,
          type: LogType.error,
          message: 'Connection failed: $e',
        ),
      );
      emit(BluetoothError(e.toString()));
    }
  }

  /// Disconnect from the currently connected device.
  Future<void> disconnect() async {
    final device = _connectedDevice;
    if (device == null) return;
    try {
      await _ble.disconnect(device);
      _connectionSub?.cancel();
      emit(BluetoothDisconnected(device));
      _connectedDevice = null;
      await _log(
        BleLogEntry.system(
          deviceId: device.deviceId,
          deviceName: device.name,
          type: LogType.disconnect,
          message: 'Disconnected (user initiated)',
        ),
      );
    } catch (e) {
      emit(BluetoothError(e.toString()));
    }
  }

  // ══════════════════════════════════════════════
  // SECTION 4 – SERVICE DISCOVERY
  // ══════════════════════════════════════════════

  List<BleService> _services = [];

  /// Discover services on [device] (auto-called if you skip it).
  Future<void> discoverServices(BleDevice device) async {
    try {
      _services = await _ble.discoverServices(device);
      await _log(
        BleLogEntry.system(
          deviceId: device.deviceId,
          deviceName: device.name,
          type: LogType.serviceDiscovery,
          message:
              'Discovered ${_services.length} service(s): '
              '${_services.map((s) => s.uuid).join(", ")}',
        ),
      );
      emit(BluetoothServicesDiscovered(device, _services));
    } catch (e) {
      emit(BluetoothError(e.toString()));
    }
  }

  // ══════════════════════════════════════════════
  // SECTION 5 – READ / WRITE DATA
  // ══════════════════════════════════════════════

  /// Read from [characteristic] and emit [BluetoothDataRead].
  Future<void> read(
    BleCharacteristic characteristic, {
    String? deviceId,
    String? deviceName,
  }) async {
    try {
      final data = await _ble.read(characteristic);
      if (deviceId != null) {
        await _log(
          BleLogEntry.data(
            deviceId: deviceId,
            deviceName: deviceName,
            direction: LogDirection.incoming,
            type: LogType.read,
            message: 'Read from ${characteristic.uuid}',
            bytes: data,
          ),
        );
      }
      emit(BluetoothDataRead(data));
    } catch (e) {
      emit(BluetoothError(e.toString()));
    }
  }

  /// Write [data] to [characteristic].
  Future<void> write(
    BleCharacteristic characteristic,
    List<int> data, {
    bool withResponse = true,
    String? deviceId,
    String? deviceName,
  }) async {
    try {
      await _ble.write(characteristic, data, withResponse: withResponse);
      if (deviceId != null) {
        await _log(
          BleLogEntry.data(
            deviceId: deviceId,
            deviceName: deviceName,
            direction: LogDirection.outgoing,
            type: LogType.write,
            message:
                'Write${withResponse ? " (with response)" : " (no response)"} '
                'to ${characteristic.uuid}',
            bytes: Uint8List.fromList(data),
          ),
        );
      }
      emit(BluetoothDataWritten());
    } catch (e) {
      emit(BluetoothError(e.toString()));
    }
  }

  // ══════════════════════════════════════════════
  // SECTION 6 – SUBSCRIPTIONS
  // ══════════════════════════════════════════════

  StreamSubscription<Uint8List>? _notifySub;

  /// Subscribe to notifications (or indications) on [characteristic].
  Future<void> subscribe(
    BleCharacteristic characteristic, {
    bool useIndications = false,
    String? deviceId,
    String? deviceName,
  }) async {
    try {
      _notifySub?.cancel();
      void handler(Uint8List data) {
        if (deviceId != null) {
          _log(
            BleLogEntry.data(
              deviceId: deviceId,
              deviceName: deviceName,
              direction: LogDirection.incoming,
              type: useIndications ? LogType.indicate : LogType.notify,
              message:
                  '${useIndications ? "Indication" : "Notification"} from ${characteristic.uuid}',
              bytes: data,
            ),
          );
        }
        emit(BluetoothDataReceived(data));
      }

      if (useIndications) {
        _notifySub = await _ble.subscribeIndications(characteristic, handler);
      } else {
        _notifySub = await _ble.subscribeNotifications(characteristic, handler);
      }
      if (deviceId != null) {
        await _log(
          BleLogEntry.system(
            deviceId: deviceId,
            deviceName: deviceName,
            type: LogType.info,
            message:
                'Subscribed to ${useIndications ? "indications" : "notifications"} '
                'on ${characteristic.uuid}',
          ),
        );
      }
      emit(BluetoothSubscribed());
    } catch (e) {
      emit(BluetoothError(e.toString()));
    }
  }

  /// Cancel the active subscription.
  Future<void> unsubscribe(BleCharacteristic characteristic) async {
    try {
      await _ble.unsubscribe(characteristic);
      _notifySub?.cancel();
    } catch (e) {
      emit(BluetoothError(e.toString()));
    }
  }

  // ══════════════════════════════════════════════
  // SECTION 7 – PAIRING
  // ══════════════════════════════════════════════

  /// Pair with [device].
  Future<void> pairDevice(
    BleDevice device, {
    BleCommand? pairingCommand,
  }) async {
    emit(BluetoothPairingInProgress(device.deviceId));
    await _log(
      BleLogEntry.system(
        deviceId: device.deviceId,
        deviceName: device.name,
        type: LogType.pair,
        message: 'Pairing requested with "${device.name ?? device.deviceId}"…',
      ),
    );
    try {
      await _ble.pair(device, pairingCommand: pairingCommand);
      await PairingStorage.savePaired(device.deviceId);
      _pairedDeviceIds = await PairingStorage.loadPairedIds();
      await _log(
        BleLogEntry.system(
          deviceId: device.deviceId,
          deviceName: device.name,
          type: LogType.pair,
          message: 'Paired successfully & saved to storage',
        ),
      );
      await NotificationService.showNotification(
        id: device.deviceId.hashCode ^ 4,
        title: 'Device Paired',
        body: 'Successfully paired with ${device.name ?? device.deviceId}',
      );
      // Start the background service so it watches for this device
      await BackgroundServiceBridge.start();
      emit(
        BluetoothPaired(
          deviceId: device.deviceId,
          isPaired: true,
          pairedDeviceIds: Set.unmodifiable(_pairedDeviceIds),
        ),
      );
    } catch (e) {
      await _log(
        BleLogEntry.system(
          deviceId: device.deviceId,
          deviceName: device.name,
          type: LogType.error,
          message: 'Pair failed: $e',
        ),
      );
      emit(BluetoothError(e.toString()));
    }
  }

  /// Unpair [device].
  Future<void> unpairDevice(BleDevice device) async {
    emit(BluetoothPairingInProgress(device.deviceId));
    await _log(
      BleLogEntry.system(
        deviceId: device.deviceId,
        deviceName: device.name,
        type: LogType.unpair,
        message: 'Unpair requested for "${device.name ?? device.deviceId}"…',
      ),
    );
    try {
      await _ble.unpair(device);
      await PairingStorage.removePaired(device.deviceId);
      _pairedDeviceIds = await PairingStorage.loadPairedIds();
      await _log(
        BleLogEntry.system(
          deviceId: device.deviceId,
          deviceName: device.name,
          type: LogType.unpair,
          message: 'Unpaired & removed from storage',
        ),
      );
      // Stop background service if no paired devices remain
      if (_pairedDeviceIds.isEmpty) {
        await BackgroundServiceBridge.stop();
      }
      emit(
        BluetoothPaired(
          deviceId: device.deviceId,
          isPaired: false,
          pairedDeviceIds: Set.unmodifiable(_pairedDeviceIds),
        ),
      );
    } catch (e) {
      await _log(
        BleLogEntry.system(
          deviceId: device.deviceId,
          deviceName: device.name,
          type: LogType.error,
          message: 'Unpair failed: $e',
        ),
      );
      emit(BluetoothError(e.toString()));
    }
  }

  // ══════════════════════════════════════════════
  // CLEANUP
  // ══════════════════════════════════════════════

  @override
  Future<void> close() async {
    await _availabilitySub?.cancel();
    await _globalConnectionSub?.cancel();
    await _scanSub?.cancel();
    await _connectionSub?.cancel();
    await _notifySub?.cancel();
    return super.close();
  }
}
