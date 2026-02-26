import 'package:bluetooth/services/ble_background_service.dart';

/// Thin wrapper so BluetoothCubit doesn't depend
/// directly on flutter_foreground_task's API.
class BackgroundServiceBridge {
  BackgroundServiceBridge._();

  static Future<void> start() => BleBackgroundService.start();
  static Future<void> stop() => BleBackgroundService.stop();
  static Future<bool> isRunning() => BleBackgroundService.isRunning;
}
