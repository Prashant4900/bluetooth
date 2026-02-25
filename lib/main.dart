import 'package:bluetooth/cubit/bluetooth_cubit.dart';
import 'package:bluetooth/screens/scanner_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

void main() {
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
