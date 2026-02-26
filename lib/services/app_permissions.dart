import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

/// Requests all runtime permissions needed for BLE + background service.
///
/// Call once at app start before initialising BluetoothCubit.
class AppPermissions {
  AppPermissions._();

  /// Request all required permissions and return true if all
  /// critical permissions (BLE SCAN + CONNECT) are granted.
  static Future<bool> requestAll() async {
    if (Platform.isIOS) {
      // On iOS permissions are declared in Info.plist — no runtime prompt needed.
      return true;
    }

    final permissions = <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      // Android 13+: needed to show the foreground-service notification
      Permission.notification,
    ];

    final statuses = await permissions.request();

    final scanOk = statuses[Permission.bluetoothScan]?.isGranted ?? false;
    final connectOk = statuses[Permission.bluetoothConnect]?.isGranted ?? false;

    return scanOk && connectOk;
  }

  /// Returns true if BLE permissions are already granted (no prompt).
  static Future<bool> bleGranted() async {
    if (Platform.isIOS) return true;
    return await Permission.bluetoothScan.isGranted &&
        await Permission.bluetoothConnect.isGranted;
  }
}
