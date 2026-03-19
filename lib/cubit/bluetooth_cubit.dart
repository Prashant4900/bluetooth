import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:bluetooth/models/ble_log_entry.dart';
import 'package:bluetooth/repositories/ble_log_repository.dart';
import 'package:bluetooth/repositories/ble_repository.dart';
import 'package:equatable/equatable.dart';
import 'package:universal_ble/universal_ble.dart';

part 'bluetooth_state.dart';

/// Thin proxy between the UI and the BLE repositories.
/// Translates repository streams into [BluetoothState] emissions.
class BluetoothCubit extends Cubit<BluetoothState> {
  final BleRepository bleRepository;
  final BleLogRepository logRepository;

  late final List<StreamSubscription> _subscriptions;

  BluetoothCubit({required this.bleRepository, required this.logRepository})
    : super(BluetoothLoading()) {
    _subscriptions = [
      bleRepository.onPairedDevicesChanged.listen((pairedIds) {
        emit(BluetoothPairingState(pairedDeviceIds: pairedIds));
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
        emit(
          BluetoothConnectionState(
            device: event.device,
            status: _toConnectionStatus(event.status),
          ),
        );
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

      bleRepository.onError.listen((error) => emit(BluetoothError(error))),

      logRepository.onLogsUpdated.listen((deviceId) {
        final logs = deviceId == 'all'
            ? logRepository.allLogs
            : logRepository.deviceLogs(deviceId);
        emit(BluetoothLogsUpdated(deviceId, logs));
      }),
    ];
  }

  // ── Delegated getters (UI convenience) ──────────────────────────────────

  Set<String> get pairedDeviceIds => bleRepository.pairedDeviceIds;
  List<BleDevice> get discoveredDevices => bleRepository.discoveredDevices;
  Map<String, BleDevice> get connectedDevices => bleRepository.connectedDevices;
  List<BleLogEntry> get allLogs => logRepository.allLogs;

  // ── Operations ───────────────────────────────────────────────────────────

  Future<void> initialize() async {
    emit(BluetoothLoading());
    await bleRepository.initialize();
  }

  Future<void> startScan({List<String> withServices = const []}) =>
      bleRepository.startScan(withServices: withServices);

  Future<void> stopScan() => bleRepository.stopScan();

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

  Future<void> loadDeviceLogs(String deviceId) =>
      logRepository.loadDeviceLogs(deviceId);

  Future<void> loadAllLogs() => logRepository.loadAllLogs();

  // ── Helpers ──────────────────────────────────────────────────────────────

  BleConnectionStatus _toConnectionStatus(RepoConnectionStatus status) =>
      switch (status) {
        RepoConnectionStatus.connecting => BleConnectionStatus.connecting,
        RepoConnectionStatus.connected => BleConnectionStatus.connected,
        RepoConnectionStatus.disconnected => BleConnectionStatus.disconnected,
      };

  @override
  Future<void> close() {
    for (final sub in _subscriptions) sub.cancel();
    // Repositories are injected from above — dispose them there, not here.
    return super.close();
  }
}
