import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:bluetooth/bluetooth_service.dart';
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

  // ══════════════════════════════════════════════
  // SECTION 1 – INITIALIZE
  // ══════════════════════════════════════════════

  StreamSubscription<AvailabilityState>? _availabilitySub;

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

      emit(BluetoothInitialized(availState));

      // Auto-start scanning if BLE is already on
      if (availState == AvailabilityState.poweredOn) {
        await startScan();
      }
    } catch (e) {
      emit(BluetoothError(e.toString()));
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
  // SECTION 2 – SCANNING
  // ══════════════════════════════════════════════

  StreamSubscription<BleDevice>? _scanSub;
  final List<BleDevice> _discoveredDevices = [];

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
  StreamSubscription<bool>? _connectionSub;

  /// Connect to [device] and start monitoring its connection state.
  Future<void> connect(BleDevice device) async {
    emit(BluetoothConnecting(device));
    try {
      await _ble.connect(device);
      _connectedDevice = device;

      _connectionSub?.cancel();
      _connectionSub = _ble.connectionStream(device).listen((isConnected) {
        if (isConnected) {
          emit(BluetoothConnected(device));
        } else {
          emit(BluetoothDisconnected(device));
          _connectedDevice = null;
        }
      });

      emit(BluetoothConnected(device));
    } catch (e) {
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
      emit(BluetoothServicesDiscovered(device, _services));
    } catch (e) {
      emit(BluetoothError(e.toString()));
    }
  }

  // ══════════════════════════════════════════════
  // SECTION 5 – READ / WRITE DATA
  // ══════════════════════════════════════════════

  /// Read from [characteristic] and emit [BluetoothDataRead].
  Future<void> read(BleCharacteristic characteristic) async {
    try {
      final data = await _ble.read(characteristic);
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
  }) async {
    try {
      await _ble.write(characteristic, data, withResponse: withResponse);
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
  }) async {
    try {
      _notifySub?.cancel();
      if (useIndications) {
        _notifySub = await _ble.subscribeIndications(
          characteristic,
          (data) => emit(BluetoothDataReceived(data)),
        );
      } else {
        _notifySub = await _ble.subscribeNotifications(
          characteristic,
          (data) => emit(BluetoothDataReceived(data)),
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
  /// Saves the device ID to SharedPreferences on success.
  Future<void> pairDevice(
    BleDevice device, {
    BleCommand? pairingCommand,
  }) async {
    emit(BluetoothPairingInProgress(device.deviceId));
    try {
      await _ble.pair(device, pairingCommand: pairingCommand);

      // Persist pairing
      await PairingStorage.savePaired(device.deviceId);
      _pairedDeviceIds = await PairingStorage.loadPairedIds();

      debugPrint('[BLE] Paired & saved: ${device.deviceId}');
      emit(
        BluetoothPaired(
          deviceId: device.deviceId,
          isPaired: true,
          pairedDeviceIds: Set.unmodifiable(_pairedDeviceIds),
        ),
      );
    } catch (e) {
      emit(BluetoothError(e.toString()));
    }
  }

  /// Unpair [device].
  /// Removes the device ID from SharedPreferences.
  Future<void> unpairDevice(BleDevice device) async {
    emit(BluetoothPairingInProgress(device.deviceId));
    try {
      await _ble.unpair(device);

      // Remove from persistence
      await PairingStorage.removePaired(device.deviceId);
      _pairedDeviceIds = await PairingStorage.loadPairedIds();

      debugPrint('[BLE] Unpaired & removed: ${device.deviceId}');
      emit(
        BluetoothPaired(
          deviceId: device.deviceId,
          isPaired: false,
          pairedDeviceIds: Set.unmodifiable(_pairedDeviceIds),
        ),
      );
    } catch (e) {
      emit(BluetoothError(e.toString()));
    }
  }

  // ══════════════════════════════════════════════
  // CLEANUP
  // ══════════════════════════════════════════════

  @override
  Future<void> close() async {
    await _availabilitySub?.cancel();
    await _scanSub?.cancel();
    await _connectionSub?.cancel();
    await _notifySub?.cancel();
    return super.close();
  }
}
