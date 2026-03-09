import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:bluetooth/models/ble_log_entry.dart';
import 'package:bluetooth/repositories/ble_log_repository.dart';
import 'package:bluetooth/repositories/ble_repository.dart';
import 'package:equatable/equatable.dart';
import 'package:universal_ble/universal_ble.dart';

part 'bluetooth_state.dart';

/// A lightweight proxy that manages BLE states for the UI
/// by consuming BleRepository and BleLogRepository.
class BluetoothCubit extends Cubit<BluetoothState> {
  final BleRepository bleRepository;
  final BleLogRepository logRepository;

  late final List<StreamSubscription> _subscriptions;

  BluetoothCubit({required this.bleRepository, required this.logRepository})
    : super(BluetoothLoading()) {
    _subscriptions = [
      bleRepository.onPairedDevicesChanged.listen((pairedIds) {
        emit(
          BluetoothPairingState(
            pairedDeviceIds: pairedIds,
            // Assuming changedDeviceId isn't strictly necessary here, or we get it from pairing events.
          ),
        );
      }),
      bleRepository.onScanStateChanged.listen((_) {
        emit(
          BluetoothScanState(
            devices: bleRepository.discoveredDevices,
            isScanning: bleRepository.isScanning,
          ),
        );
      }),
      bleRepository.onConnectionStateChanged.listen((event) {
        final status = _mapRepoConnectionStatus(event.status);
        emit(BluetoothConnectionState(device: event.device, status: status));
        // Also fire scan state to ensure UI updates if device moved from discovered to connected?
        // Let's rely on standard UI rebuilding.
      }),
      bleRepository.onError.listen((error) {
        emit(BluetoothError(error));
      }),
      bleRepository.onPairingEvent.listen((event) {
        emit(
          BluetoothPairingState(
            pairedDeviceIds: bleRepository.pairedDeviceIds,
            isLoading: event.isLoading,
            changedDeviceId: event.deviceId,
            isPaired: event.isPaired,
          ),
        );
      }),
      logRepository.onLogsUpdated.listen((deviceId) {
        if (deviceId == 'all') {
          emit(BluetoothLogsUpdated('all', logRepository.allLogs));
        } else {
          emit(
            BluetoothLogsUpdated(deviceId, logRepository.deviceLogs(deviceId)),
          );
        }
      }),
    ];
  }

  // ── DELEGATED PROPERTIES (For UI backward compatibility) ─────

  Set<String> get pairedDeviceIds => bleRepository.pairedDeviceIds;
  List<BleDevice> get discoveredDevices => bleRepository.discoveredDevices;
  Map<String, BleDevice> get connectedDevices => bleRepository.connectedDevices;
  List<BleLogEntry> get allLogs => logRepository.allLogs;

  // ── OPERATIONS ──────────────────────────────────────────────

  Future<void> initialize() async {
    emit(BluetoothLoading());
    await bleRepository.initialize();
  }

  Future<void> loadDeviceLogs(String deviceId) =>
      logRepository.loadDeviceLogs(deviceId);

  Future<void> loadAllLogs() => logRepository.loadAllLogs();

  Future<void> startScan({List<String> withServices = const []}) async {
    await bleRepository.startScan(withServices: withServices);
  }

  Future<void> stopScan() async {
    await bleRepository.stopScan();
  }

  Future<void> connect(BleDevice device) => bleRepository.connect(device);

  Future<void> disconnect(BleDevice device) => bleRepository.disconnect(device);

  Future<void> discoverServices(BleDevice device) =>
      bleRepository.discoverServices(device);

  Future<void> read(
    BleCharacteristic characteristic, {
    String? deviceId,
    String? deviceName,
  }) => bleRepository.read(
    characteristic,
    deviceId: deviceId,
    deviceName: deviceName,
  );

  Future<void> write(
    BleCharacteristic characteristic,
    List<int> data, {
    bool withResponse = true,
    String? deviceId,
    String? deviceName,
  }) => bleRepository.write(
    characteristic,
    data,
    withResponse: withResponse,
    deviceId: deviceId,
    deviceName: deviceName,
  );

  Future<void> subscribe(
    BleCharacteristic characteristic, {
    bool useIndications = false,
    String? deviceId,
    String? deviceName,
  }) => bleRepository.subscribe(
    characteristic,
    useIndications: useIndications,
    deviceId: deviceId,
    deviceName: deviceName,
  );

  Future<void> unsubscribe(BleCharacteristic characteristic) =>
      bleRepository.unsubscribe(characteristic);

  Future<void> pairDevice(BleDevice device, {BleCommand? pairingCommand}) =>
      bleRepository.pairDevice(device, pairingCommand: pairingCommand);

  Future<void> unpairDevice(BleDevice device) =>
      bleRepository.unpairDevice(device);

  BleConnectionStatus _mapRepoConnectionStatus(RepoConnectionStatus status) {
    switch (status) {
      case RepoConnectionStatus.connecting:
        return BleConnectionStatus.connecting;
      case RepoConnectionStatus.connected:
        return BleConnectionStatus.connected;
      case RepoConnectionStatus.disconnected:
        return BleConnectionStatus.disconnected;
    }
  }

  @override
  Future<void> close() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    // We do NOT dispose repositories here if they are singletons injected from above.
    return super.close();
  }
}
