import 'package:bluetooth/cubit/bluetooth_cubit.dart';
import 'package:bluetooth/repositories/ble_log_repository.dart';
import 'package:bluetooth/repositories/ble_repository.dart';
import 'package:bluetooth/screens/main_navigation_screen.dart';
import 'package:bluetooth/services/app_permissions.dart';
import 'package:bluetooth/services/ble_background_service.dart';
import 'package:bluetooth/storage/pairing_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 2. Configure flutter_foreground_task (must run before anything BLE)
  BleBackgroundService.initialize();

  // 3. Request BLE + notification permissions
  await AppPermissions.requestAll();

  // 4. If paired devices already exist (e.g. after reboot), start the
  //    background service in case the boot receiver hasn't fired yet.
  final paired = await PairingStorage.loadPairedIds();
  if (paired.isNotEmpty) {
    await BleBackgroundService.start();
  }

  // 5. Initialize Repositories
  final logRepository = BleLogRepository();
  final bleRepository = BleRepository(logRepository: logRepository);

  runApp(MyApp(logRepository: logRepository, bleRepository: bleRepository));
}

class MyApp extends StatelessWidget {
  final BleLogRepository logRepository;
  final BleRepository bleRepository;

  const MyApp({
    super.key,
    required this.logRepository,
    required this.bleRepository,
  });

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => BluetoothCubit(
        bleRepository: bleRepository,
        logRepository: logRepository,
      )..initialize(),
      // WithForegroundTask keeps the foreground service alive when the
      // Flutter activity is paused on Android.
      child: WithForegroundTask(
        child: MaterialApp(
          title: 'BLE Scanner',
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
          ),
          home: const MainNavigationScreen(),
        ),
      ),
    );
  }
}
