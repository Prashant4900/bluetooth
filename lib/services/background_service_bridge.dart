import 'dart:io';

import 'package:flutter/services.dart';

/// Dart bridge to the native [BleBackgroundService] on Android.
///
/// On iOS the `bluetooth-central` background mode in Info.plist lets
/// CoreBluetooth handle reconnection automatically — no extra channel needed.
class BackgroundServiceBridge {
  BackgroundServiceBridge._();

  static const _channel = MethodChannel(
    'com.example.bluetooth/background_service',
  );

  /// Start the Android foreground BLE service.
  /// No-op on iOS (CoreBluetooth via bluetooth-central mode).
  static Future<void> start() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('startService');
    } on PlatformException catch (_) {
      // Service may already be running — safe to ignore.
    }
  }

  /// Stop the Android foreground BLE service. No-op on iOS.
  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('stopService');
    } on PlatformException catch (_) {
      // Ignore.
    }
  }

  /// Returns whether the Android service is currently running.
  /// Always returns false on iOS.
  static Future<bool> isRunning() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isRunning') ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }
}
