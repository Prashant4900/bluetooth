import 'package:bluetooth/screens/all_logs_screen.dart';
import 'package:bluetooth/screens/scanner_screen.dart';
import 'package:flutter/material.dart';

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: const [ScannerScreen(), AllLogsScreen()],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.bluetooth_searching),
            label: 'Scanner',
          ),
          BottomNavigationBarItem(icon: Icon(Icons.list_alt), label: 'Logs'),
        ],
      ),
    );
  }
}
