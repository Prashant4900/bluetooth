import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

/// Handles all runtime permissions required for BLE + background service.
/// Call [requestAll] once at app start, before initialising BluetoothCubit.
class AppPermissions {
  AppPermissions._();

  /// Requests BLE permissions and returns true if both SCAN and CONNECT
  /// are granted. On iOS, permissions come from Info.plist so we skip this.
  static Future<bool> requestAll() async {
    if (Platform.isIOS) return true;

    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();

    return statuses[Permission.bluetoothScan]?.isGranted == true &&
        statuses[Permission.bluetoothConnect]?.isGranted == true;
  }

  /// Returns true if BLE permissions are already granted (no prompt shown).
  static Future<bool> bleGranted() async {
    if (Platform.isIOS) return true;
    return await Permission.bluetoothScan.isGranted &&
        await Permission.bluetoothConnect.isGranted;
  }
}
