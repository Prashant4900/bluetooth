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

/// Manages all BLE operations: scanning, connecting, pairing, and logging.
class BluetoothCubit extends Cubit<BluetoothState> {
  BluetoothCubit() : super(BluetoothLoading());

  final BluetoothService _ble = BluetoothService();

  /// Paired device IDs cached from storage.
  Set<String> _pairedDeviceIds = {};
  Set<String> get pairedDeviceIds => Set.unmodifiable(_pairedDeviceIds);

  /// Per-device in-memory log buffer.
  final Map<String, List<BleLogEntry>> _deviceLogs = {};

  // ══════════════════════════════════════════════
  // SECTION 1 – INITIALIZE
  // ══════════════════════════════════════════════

  StreamSubscription<BleConnectionEvent>? _globalConnectionSub;

  /// Initialises the BLE stack, loads paired devices, and starts scanning.
  Future<void> initialize() async {
    emit(BluetoothLoading());
    try {
      await _ble.stopScanIfActive();
      final availState = await _ble.initialize();

      await _loadPairedDevices();

      // Listen for connection changes from any device, including background auto-connects.
      _globalConnectionSub?.cancel();
      _globalConnectionSub = _ble.connectionStateStream.listen((event) async {
        final knownName = _discoveredDevices
            .cast<BleDevice?>()
            .firstWhere(
              (d) => d?.deviceId == event.deviceId,
              orElse: () => null,
            )
            ?.name;

        // Only track LMNP devices.
        if (knownName?.startsWith('LMNP') != true) return;

        if (event.isConnected) {
          final dev = BleDevice(deviceId: event.deviceId, name: knownName);
          _connectedDevices[event.deviceId] = dev;

          // Ensure the device appears in the scanner list even if discovered in background.
          if (!_discoveredDevices.any((d) => d.deviceId == event.deviceId)) {
            _discoveredDevices.add(dev);
          }

          // Re-establish per-device disconnect listener so future disconnects
          // are caught even when the connection was made by the background service.
          _connectionSubs[event.deviceId]?.cancel();
          _connectionSubs[event.deviceId] = _ble.connectionStream(dev).listen((
            isConnected,
          ) {
            if (!isConnected) {
              emit(
                BluetoothConnectionState(
                  device: dev,
                  status: BleConnectionStatus.disconnected,
                ),
              );
              _connectedDevices.remove(dev.deviceId);
              _log(
                BleLogEntry.system(
                  deviceId: dev.deviceId,
                  deviceName: dev.name,
                  message: 'Disconnected from "${dev.name ?? dev.deviceId}"',
                ),
              );
              NotificationService.showNotification(
                id: dev.deviceId.hashCode ^ 3,
                title: 'Device Disconnected',
                body: 'Lost connection to ${dev.name ?? dev.deviceId}',
              );
            }
          });

          emit(
            BluetoothConnectionState(
              device: dev,
              status: BleConnectionStatus.connected,
            ),
          );
          emit(
            BluetoothScanState(
              devices: List.unmodifiable(_discoveredDevices),
              isScanning: false,
            ),
          );

          await _log(
            BleLogEntry.system(
              deviceId: event.deviceId,
              deviceName: knownName,
              message:
                  'Connected to "${knownName ?? event.deviceId}"'
                  '${event.error != null ? " (${event.error})" : ""}',
            ),
          );

          // Pull in any logs written by the background service during reconnect.
          await loadDeviceLogs(event.deviceId);
          emit(BluetoothLogsUpdated('all', allLogs));
        } else {
          final dev = BleDevice(deviceId: event.deviceId, name: knownName);
          emit(
            BluetoothConnectionState(
              device: dev,
              status: BleConnectionStatus.disconnected,
            ),
          );

          await _log(
            BleLogEntry.system(
              deviceId: event.deviceId,
              deviceName: knownName,
              message: event.error != null
                  ? 'Disconnected from "${knownName ?? event.deviceId}" — ${event.error}'
                  : 'Disconnected from "${knownName ?? event.deviceId}"',
            ),
          );

          _connectedDevices.remove(event.deviceId);
          emit(
            BluetoothScanState(
              devices: List.unmodifiable(_discoveredDevices),
              isScanning: false,
            ),
          );
          startScan();
        }
      });

      if (availState == AvailabilityState.poweredOn) {
        await startScan();
      }
    } catch (e) {
      emit(BluetoothError(e.toString()));
    }
  }

  /// Loads paired device IDs from storage and emits the updated pairing state.
  Future<void> _loadPairedDevices() async {
    _pairedDeviceIds = await PairingStorage.loadPairedIds();
    emit(
      BluetoothPairingState(
        pairedDeviceIds: Set.unmodifiable(_pairedDeviceIds),
      ),
    );
    debugPrint('[BLE] Loaded ${_pairedDeviceIds.length} paired device(s)');
  }

  // ══════════════════════════════════════════════
  // SECTION 2 – LOGGING
  // ══════════════════════════════════════════════

  /// Adds [entry] to the in-memory buffer, persists it, and emits state updates.
  Future<void> _log(BleLogEntry entry) async {
    final list = _deviceLogs.putIfAbsent(entry.deviceId, () => []);
    list.add(entry);
    emit(BluetoothLogsUpdated(entry.deviceId, List.unmodifiable(list)));
    emit(BluetoothLogsUpdated('all', allLogs));
    LogStorage.appendLog(entry).ignore();
  }

  /// Loads persisted logs for [deviceId], merges with in-memory entries, and emits state.
  Future<void> loadDeviceLogs(String deviceId) async {
    final stored = await LogStorage.loadLogs(deviceId);
    final inMem = _deviceLogs[deviceId] ?? [];
    final merged = <BleLogEntry>[...stored];
    for (final e in inMem) {
      if (!merged.any((s) => s.id == e.id)) merged.add(e);
    }
    merged.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    _deviceLogs[deviceId] = merged;
    emit(BluetoothLogsUpdated(deviceId, List.unmodifiable(merged)));
  }

  /// Loads persisted logs for all known devices and emits a combined update.
  Future<void> loadAllLogs() async {
    final deviceIds = await LogStorage.getDevicesWithLogs();
    await Future.wait(deviceIds.map((id) => loadDeviceLogs(id)));
    emit(BluetoothLogsUpdated('all', allLogs));
  }

  /// Returns all logs across every device, sorted by timestamp.
  List<BleLogEntry> get allLogs {
    final all = <BleLogEntry>[];
    for (final logs in _deviceLogs.values) {
      all.addAll(logs);
    }
    all.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return List.unmodifiable(all);
  }

  // ══════════════════════════════════════════════
  // SECTION 3 – SCANNING
  // ══════════════════════════════════════════════

  StreamSubscription<BleDevice>? _scanSub;
  final List<BleDevice> _discoveredDevices = [];
  List<BleDevice> get discoveredDevices =>
      List.unmodifiable(_discoveredDevices);

  /// Starts a BLE scan. Paired devices remain in the list while unpaired ones are cleared.
  /// Auto-connects to any paired device found during scan.
  Future<void> startScan({List<String> withServices = const []}) async {
    _discoveredDevices.removeWhere(
      (d) => !_pairedDeviceIds.contains(d.deviceId),
    );
    emit(
      BluetoothScanState(
        devices: List.unmodifiable(_discoveredDevices),
        isScanning: true,
      ),
    );

    try {
      _scanSub?.cancel();
      _scanSub = _ble.scanStream.listen((device) {
        // Ignore non-LMNP devices.
        if (device.name?.startsWith('LMNP') != true) return;

        final exists = _discoveredDevices.any(
          (d) => d.deviceId == device.deviceId,
        );
        if (!exists) {
          _discoveredDevices.add(device);
          emit(
            BluetoothScanState(
              devices: List.unmodifiable(_discoveredDevices),
              isScanning: true,
            ),
          );
          _log(
            BleLogEntry.system(
              deviceId: device.deviceId,
              deviceName: device.name,
              message:
                  'Discovered: "${device.name ?? "Unknown"}"'
                  '${device.rssi != null ? " — RSSI ${device.rssi} dBm" : ""}',
            ),
          );
        }

        // Auto-connect if paired and not already connected or connecting.
        // This check runs whether the device is newly discovered OR already
        // in the list — covering the re-scan-after-background-reconnect case.
        final currentState = state;
        if (_pairedDeviceIds.contains(device.deviceId) &&
            !_connectedDevices.containsKey(device.deviceId) &&
            !(currentState is BluetoothConnectionState &&
                currentState.device.deviceId == device.deviceId &&
                currentState.status == BleConnectionStatus.connecting)) {
          debugPrint(
            '[BLE] Auto-connecting to paired device: ${device.deviceId}',
          );
          connect(device);
        }
      });

      await _ble.startScan(withServices: withServices);
    } catch (e) {
      emit(BluetoothError(e.toString()));
    }
  }

  /// Stops the active BLE scan.
  Future<void> stopScan() async {
    try {
      await _ble.stopScan();
      _scanSub?.cancel();
      emit(
        BluetoothScanState(
          devices: List.unmodifiable(_discoveredDevices),
          isScanning: false,
        ),
      );
    } catch (e) {
      emit(BluetoothError(e.toString()));
    }
  }

  // ══════════════════════════════════════════════
  // SECTION 4 – CONNECTION
  // ══════════════════════════════════════════════

  final Map<String, BleDevice> _connectedDevices = {};
  Map<String, BleDevice> get connectedDevices =>
      Map.unmodifiable(_connectedDevices);
  final Map<String, StreamSubscription<bool>> _connectionSubs = {};

  /// Connects to [device] and monitors for disconnection events.
  Future<void> connect(BleDevice device) async {
    emit(
      BluetoothConnectionState(
        device: device,
        status: BleConnectionStatus.connecting,
      ),
    );
    await _log(
      BleLogEntry.system(
        deviceId: device.deviceId,
        deviceName: device.name,
        message: 'Connecting to "${device.name ?? device.deviceId}"…',
      ),
    );
    try {
      await _ble.connect(device);
      _connectedDevices[device.deviceId] = device;

      _connectionSubs[device.deviceId]?.cancel();
      _connectionSubs[device.deviceId] = _ble.connectionStream(device).listen((
        isConnected,
      ) {
        if (!isConnected) {
          emit(
            BluetoothConnectionState(
              device: device,
              status: BleConnectionStatus.disconnected,
            ),
          );
          _connectedDevices.remove(device.deviceId);
          _log(
            BleLogEntry.system(
              deviceId: device.deviceId,
              deviceName: device.name,
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

      emit(
        BluetoothConnectionState(
          device: device,
          status: BleConnectionStatus.connected,
        ),
      );
    } catch (e) {
      await _log(
        BleLogEntry.system(
          deviceId: device.deviceId,
          deviceName: device.name,
          message: 'Connection failed: $e',
        ),
      );
      emit(BluetoothError(e.toString()));
    }
  }

  /// Disconnects from [device] (user-initiated).
  Future<void> disconnect(BleDevice device) async {
    if (!_connectedDevices.containsKey(device.deviceId)) return;
    try {
      await _ble.disconnect(device);
      _connectionSubs[device.deviceId]?.cancel();
      _connectionSubs.remove(device.deviceId);
      emit(
        BluetoothConnectionState(
          device: device,
          status: BleConnectionStatus.disconnected,
        ),
      );
      _connectedDevices.remove(device.deviceId);
      await _log(
        BleLogEntry.system(
          deviceId: device.deviceId,
          deviceName: device.name,
          message: 'Disconnected (user initiated)',
        ),
      );
    } catch (e) {
      emit(BluetoothError(e.toString()));
    }
  }

  // ══════════════════════════════════════════════
  // SECTION 5 – SERVICE DISCOVERY
  // ══════════════════════════════════════════════

  /// Discovers GATT services on [device] and logs the result.
  Future<void> discoverServices(BleDevice device) async {
    try {
      final services = await _ble.discoverServices(device);
      await _log(
        BleLogEntry.system(
          deviceId: device.deviceId,
          deviceName: device.name,
          message:
              'Discovered ${services.length} service(s): '
              '${services.map((s) => s.uuid).join(", ")}',
        ),
      );
    } catch (e) {
      emit(BluetoothError(e.toString()));
    }
  }

  // ══════════════════════════════════════════════
  // SECTION 6 – READ / WRITE DATA
  // ══════════════════════════════════════════════

  /// Reads data from [characteristic] and logs it.
  Future<void> read(
    BleCharacteristic characteristic, {
    String? deviceId,
    String? deviceName,
  }) async {
    try {
      await _ble.read(characteristic);
      if (deviceId != null) {
        await _log(
          BleLogEntry.system(
            deviceId: deviceId,
            deviceName: deviceName,
            message: 'Read from ${characteristic.uuid}',
          ),
        );
      }
    } catch (e) {
      emit(BluetoothError(e.toString()));
    }
  }

  /// Writes [data] to [characteristic] and logs it.
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
          BleLogEntry.system(
            deviceId: deviceId,
            deviceName: deviceName,
            message:
                'Write${withResponse ? " (with response)" : " (no response)"} '
                'to ${characteristic.uuid}',
          ),
        );
      }
    } catch (e) {
      emit(BluetoothError(e.toString()));
    }
  }

  // ══════════════════════════════════════════════
  // SECTION 7 – SUBSCRIPTIONS
  // ══════════════════════════════════════════════

  final Map<String, StreamSubscription<Uint8List>> _notifySubs = {};

  /// Subscribes to notifications or indications on [characteristic].
  Future<void> subscribe(
    BleCharacteristic characteristic, {
    bool useIndications = false,
    String? deviceId,
    String? deviceName,
  }) async {
    try {
      _notifySubs[characteristic.uuid.toString()]?.cancel();

      void handler(Uint8List data) {
        debugPrint('[BLE] Data received: ${data.length} byte(s)');
      }

      final subKey = characteristic.uuid.toString();
      if (useIndications) {
        _notifySubs[subKey] = await _ble.subscribeIndications(
          characteristic,
          handler,
        );
      } else {
        _notifySubs[subKey] = await _ble.subscribeNotifications(
          characteristic,
          handler,
        );
      }

      if (deviceId != null) {
        await _log(
          BleLogEntry.system(
            deviceId: deviceId,
            deviceName: deviceName,
            message:
                'Subscribed to ${useIndications ? "indications" : "notifications"} '
                'on ${characteristic.uuid}',
          ),
        );
      }
    } catch (e) {
      emit(BluetoothError(e.toString()));
    }
  }

  /// Cancels the active subscription on [characteristic].
  Future<void> unsubscribe(BleCharacteristic characteristic) async {
    try {
      await _ble.unsubscribe(characteristic);
      final subKey = characteristic.uuid.toString();
      _notifySubs[subKey]?.cancel();
      _notifySubs.remove(subKey);
    } catch (e) {
      emit(BluetoothError(e.toString()));
    }
  }

  // ══════════════════════════════════════════════
  // SECTION 8 – PAIRING
  // ══════════════════════════════════════════════

  /// Pairs with [device], saves it to storage, and auto-connects.
  Future<void> pairDevice(
    BleDevice device, {
    BleCommand? pairingCommand,
  }) async {
    emit(
      BluetoothPairingState(
        pairedDeviceIds: Set.unmodifiable(_pairedDeviceIds),
        isLoading: true,
        changedDeviceId: device.deviceId,
      ),
    );
    await _log(
      BleLogEntry.system(
        deviceId: device.deviceId,
        deviceName: device.name,
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
          message: 'Paired successfully & saved to storage',
        ),
      );
      await NotificationService.showNotification(
        id: device.deviceId.hashCode ^ 4,
        title: 'Device Paired',
        body: 'Successfully paired with ${device.name ?? device.deviceId}',
      );
      await BackgroundServiceBridge.start();
      emit(
        BluetoothPairingState(
          pairedDeviceIds: Set.unmodifiable(_pairedDeviceIds),
          changedDeviceId: device.deviceId,
          isPaired: true,
        ),
      );
      connect(device);
    } catch (e) {
      await _log(
        BleLogEntry.system(
          deviceId: device.deviceId,
          deviceName: device.name,
          message: 'Pair failed: $e',
        ),
      );
      emit(BluetoothError(e.toString()));
    }
  }

  /// Removes [device] from paired storage and stops background monitoring if no devices remain.
  Future<void> unpairDevice(BleDevice device) async {
    emit(
      BluetoothPairingState(
        pairedDeviceIds: Set.unmodifiable(_pairedDeviceIds),
        isLoading: true,
        changedDeviceId: device.deviceId,
      ),
    );
    await _log(
      BleLogEntry.system(
        deviceId: device.deviceId,
        deviceName: device.name,
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
          message: 'Unpaired & removed from storage',
        ),
      );
      if (_pairedDeviceIds.isEmpty) {
        await BackgroundServiceBridge.stop();
      }
      emit(
        BluetoothPairingState(
          pairedDeviceIds: Set.unmodifiable(_pairedDeviceIds),
          changedDeviceId: device.deviceId,
          isPaired: false,
        ),
      );
    } catch (e) {
      await _log(
        BleLogEntry.system(
          deviceId: device.deviceId,
          deviceName: device.name,
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
    await _globalConnectionSub?.cancel();
    await _scanSub?.cancel();
    for (final sub in _connectionSubs.values) {
      await sub.cancel();
    }
    for (final sub in _notifySubs.values) {
      await sub.cancel();
    }
    return super.close();
  }
}
