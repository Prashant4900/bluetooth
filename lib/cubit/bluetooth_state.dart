part of 'bluetooth_cubit.dart';

// ─────────────────────────────────────────────────
// BluetoothState hierarchy
// Each state maps to one of the service sections.
// ─────────────────────────────────────────────────

sealed class BluetoothState extends Equatable {
  const BluetoothState();

  @override
  List<Object?> get props => [];
}

// ── SECTION 1: INITIALIZE ──────────────────────
final class BluetoothInitial extends BluetoothState {}

final class BluetoothLoading extends BluetoothState {}

/// BLE stack is ready; carries the current availability state.
final class BluetoothInitialized extends BluetoothState {
  final AvailabilityState availabilityState;
  const BluetoothInitialized(this.availabilityState);

  @override
  List<Object?> get props => [availabilityState];
}

/// Bluetooth availability changed after initialization.
final class BluetoothAvailabilityChanged extends BluetoothState {
  final AvailabilityState availabilityState;
  const BluetoothAvailabilityChanged(this.availabilityState);

  @override
  List<Object?> get props => [availabilityState];
}

// ── SECTION 2: SCANNING ────────────────────────
final class BluetoothScanning extends BluetoothState {}

final class BluetoothScanResult extends BluetoothState {
  final List<BleDevice> devices;
  const BluetoothScanResult(this.devices);

  @override
  List<Object?> get props => [devices];
}

final class BluetoothScanStopped extends BluetoothState {}

// ── SECTION 3: CONNECTION ──────────────────────
final class BluetoothConnecting extends BluetoothState {
  final BleDevice device;
  const BluetoothConnecting(this.device);

  @override
  List<Object?> get props => [device.deviceId];
}

final class BluetoothConnected extends BluetoothState {
  final BleDevice device;
  const BluetoothConnected(this.device);

  @override
  List<Object?> get props => [device.deviceId];
}

final class BluetoothDisconnected extends BluetoothState {
  final BleDevice device;
  const BluetoothDisconnected(this.device);

  @override
  List<Object?> get props => [device.deviceId];
}

// ── SECTION 4: SERVICE DISCOVERY ──────────────
final class BluetoothServicesDiscovered extends BluetoothState {
  final BleDevice device;
  final List<BleService> services;
  const BluetoothServicesDiscovered(this.device, this.services);

  @override
  List<Object?> get props => [device.deviceId, services.length];
}

// ── SECTION 5: READ / WRITE ────────────────────
final class BluetoothDataRead extends BluetoothState {
  final Uint8List data;
  const BluetoothDataRead(this.data);

  @override
  List<Object?> get props => [data];
}

final class BluetoothDataWritten extends BluetoothState {}

// ── SECTION 6: SUBSCRIPTIONS ──────────────────
final class BluetoothSubscribed extends BluetoothState {}

final class BluetoothDataReceived extends BluetoothState {
  final Uint8List data;
  const BluetoothDataReceived(this.data);

  @override
  List<Object?> get props => [data];
}

// ── SECTION 7: PAIRING ────────────────────────

/// Emitted once on startup with all stored paired device IDs.
final class BluetoothPairedDevicesLoaded extends BluetoothState {
  final Set<String> pairedDeviceIds;
  const BluetoothPairedDevicesLoaded(this.pairedDeviceIds);

  @override
  List<Object?> get props => [pairedDeviceIds];
}

/// Pairing operation in progress for [deviceId].
final class BluetoothPairingInProgress extends BluetoothState {
  final String deviceId;
  const BluetoothPairingInProgress(this.deviceId);

  @override
  List<Object?> get props => [deviceId];
}

/// Pairing result for [deviceId].
final class BluetoothPaired extends BluetoothState {
  final String deviceId;
  final bool isPaired;

  /// Updated full set of IDs now stored in SharedPreferences.
  final Set<String> pairedDeviceIds;
  const BluetoothPaired({
    required this.deviceId,
    required this.isPaired,
    required this.pairedDeviceIds,
  });

  @override
  List<Object?> get props => [deviceId, isPaired, pairedDeviceIds];
}

// ── GLOBAL ERROR ──────────────────────────────
final class BluetoothError extends BluetoothState {
  final String message;
  const BluetoothError(this.message);

  @override
  List<Object?> get props => [message];
}
