part of 'bluetooth_cubit.dart';

sealed class BluetoothState extends Equatable {
  const BluetoothState();

  @override
  List<Object?> get props => [];
}

// ── Loading ────────────────────────────────────────────────────────────────

final class BluetoothLoading extends BluetoothState {}

// ── Scanning ───────────────────────────────────────────────────────────────

/// Emitted whenever the device list or scan status changes.
final class BluetoothScanState extends BluetoothState {
  final List<BleDevice> devices;
  final bool isScanning;

  const BluetoothScanState({required this.devices, required this.isScanning});

  @override
  List<Object?> get props => [devices, isScanning];
}

// ── Connection ─────────────────────────────────────────────────────────────

enum BleConnectionStatus { connecting, connected, disconnected }

/// Emitted on every connection status change (connecting → connected → disconnected).
final class BluetoothConnectionState extends BluetoothState {
  final BleDevice device;
  final BleConnectionStatus status;

  const BluetoothConnectionState({required this.device, required this.status});

  @override
  List<Object?> get props => [device.deviceId, status];
}

// ── Pairing ────────────────────────────────────────────────────────────────

/// Emitted on initial paired-device load, and after each pair/unpair operation.
///
/// - [isLoading] is true while an operation is in progress.
/// - [changedDeviceId] and [isPaired] are non-null only after an operation completes.
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

// ── Logs ───────────────────────────────────────────────────────────────────

/// Emitted whenever logs change. [deviceId] is `'all'` for cross-device updates.
final class BluetoothLogsUpdated extends BluetoothState {
  final String deviceId;
  final List<BleLogEntry> logs;

  const BluetoothLogsUpdated(this.deviceId, this.logs);

  @override
  List<Object?> get props => [deviceId, logs.length];
}

// ── Error ──────────────────────────────────────────────────────────────────

final class BluetoothError extends BluetoothState {
  final String message;

  const BluetoothError(this.message);

  @override
  List<Object?> get props => [message];
}
