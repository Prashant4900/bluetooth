import 'package:bluetooth/models/ble_log_entry.dart';
import 'package:bluetooth/services/ble_logger.dart';
import 'package:universal_ble/universal_ble.dart';

enum LogEvent {
  connecting,
  connected,
  disconnected,
  pairingRequested,
  paired,
  pairFailed,
  unpairingRequested,
  unpaired,
  unpairFailed,
  connectionFailed,
}

extension on LogEvent {
  String message(BleDevice device, [String? error]) {
    final d = device.name ?? device.deviceId;
    switch (this) {
      case LogEvent.connecting:
        return 'Connecting to "$d"…';
      case LogEvent.connected:
        return 'Connected to "$d"${error != null ? " ($error)" : ""}';
      case LogEvent.disconnected:
        return error != null
            ? 'Disconnected from "$d" — $error'
            : 'Disconnected from "$d"';
      case LogEvent.pairingRequested:
        return 'Pairing requested with "$d"…';
      case LogEvent.paired:
        return 'Paired successfully & saved to storage';
      case LogEvent.pairFailed:
        return 'Pair failed: $error';
      case LogEvent.unpairingRequested:
        return 'Unpair requested for "$d"…';
      case LogEvent.unpaired:
        return 'Unpaired & removed from storage';
      case LogEvent.unpairFailed:
        return 'Unpair failed: $error';
      case LogEvent.connectionFailed:
        return 'Connection failed: $error';
    }
  }
}

extension BleDeviceLogger on BleDevice {
  Future<void> log(LogEvent event, [String? error]) {
    return BleLogger.addLog(
      BleLogEntry.system(
        deviceId: deviceId,
        deviceName: name,
        message: event.message(this, error),
      ),
    );
  }

  Future<void> logCustom(String message) {
    return BleLogger.addLog(
      BleLogEntry.system(
        deviceId: deviceId,
        deviceName: name,
        message: message,
      ),
    );
  }
}
