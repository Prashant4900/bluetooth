import 'package:bluetooth/cubit/bluetooth_cubit.dart';
import 'package:bluetooth/screens/scanner_screen.dart';
import 'package:bluetooth/services/app_permissions.dart';
import 'package:bluetooth/services/background_service_bridge.dart';
import 'package:bluetooth/storage/pairing_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Request BLE + notification permissions at startup
  await AppPermissions.requestAll();

  // 2. If the user already has paired devices stored, ensure the
  //    background service is running (covers the case where the app
  //    was opened manually after a reboot and the boot receiver did not
  //    fire yet, or the service was stopped for any reason).
  final paired = await PairingStorage.loadPairedIds();
  if (paired.isNotEmpty) {
    await BackgroundServiceBridge.start();
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => BluetoothCubit()..initialize(),
      child: MaterialApp(
        title: 'BLE Scanner',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        ),
        home: const ScannerScreen(),
      ),
    );
  }
}
