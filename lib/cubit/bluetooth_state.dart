part of 'bluetooth_cubit.dart';

sealed class BluetoothState extends Equatable {
  const BluetoothState();

  @override
  List<Object?> get props => [];
}

// ── INITIALIZE ─────────────────────────────────
final class BluetoothLoading extends BluetoothState {}

// ── SCANNING ───────────────────────────────────
/// Covers both "scanning in progress" and "scan results" in one state.
final class BluetoothScanState extends BluetoothState {
  final List<BleDevice> devices;
  final bool isScanning;
  const BluetoothScanState({required this.devices, required this.isScanning});

  @override
  List<Object?> get props => [devices, isScanning];
}

// ── CONNECTION ─────────────────────────────────
enum BleConnectionStatus { connecting, connected, disconnected }

/// Covers connecting, connected, and disconnected in one state.
final class BluetoothConnectionState extends BluetoothState {
  final BleDevice device;
  final BleConnectionStatus status;
  const BluetoothConnectionState({required this.device, required this.status});

  @override
  List<Object?> get props => [device.deviceId, status];
}

// ── PAIRING ────────────────────────────────────
/// Covers initial load, in-progress, and pair/unpair result in one state.
/// - [isLoading] true while an operation is in progress.
/// - [changedDeviceId] and [isPaired] are set after completion (null on initial load).
final class BluetoothPairingState extends BluetoothState {
  final Set<String> pairedDeviceIds;
  final bool isLoading;
  final String? changedDeviceId;
  final bool? isPaired;

  const BluetoothPairingState({
    required this.pairedDeviceIds,
    this.isLoading = false,
    this.changedDeviceId,
    this.isPaired,
  });

  @override
  List<Object?> get props => [
    pairedDeviceIds,
    isLoading,
    changedDeviceId,
    isPaired,
  ];
}

// ── LOGS ───────────────────────────────────────
final class BluetoothLogsUpdated extends BluetoothState {
  final String deviceId;
  final List<BleLogEntry> logs;
  const BluetoothLogsUpdated(this.deviceId, this.logs);

  @override
  List<Object?> get props => [deviceId, logs.length];
}

// ── ERROR ──────────────────────────────────────
final class BluetoothError extends BluetoothState {
  final String message;
  const BluetoothError(this.message);

  @override
  List<Object?> get props => [message];
}
