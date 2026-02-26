import 'package:bluetooth/cubit/bluetooth_cubit.dart';
import 'package:bluetooth/screens/scanner_screen.dart';
import 'package:bluetooth/services/app_permissions.dart';
import 'package:bluetooth/services/ble_background_service.dart';
import 'package:bluetooth/storage/pairing_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Configure flutter_foreground_task (must run before anything BLE)
  BleBackgroundService.initialize();

  // 2. Request BLE + notification permissions
  await AppPermissions.requestAll();

  // 3. If paired devices already exist (e.g. after reboot), start the
  //    background service in case the boot receiver hasn't fired yet.
  final paired = await PairingStorage.loadPairedIds();
  if (paired.isNotEmpty) {
    await BleBackgroundService.start();
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => BluetoothCubit()..initialize(),
      // WithForegroundTask keeps the foreground service alive when the
      // Flutter activity is paused on Android.
      child: WithForegroundTask(
        child: MaterialApp(
          title: 'BLE Scanner',
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
          ),
          home: const ScannerScreen(),
        ),
      ),
    );
  }
}
