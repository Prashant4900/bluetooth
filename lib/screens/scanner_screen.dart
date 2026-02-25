import 'package:bluetooth/cubit/bluetooth_cubit.dart';
import 'package:bluetooth/screens/device_log_screen.dart';
import 'package:bluetooth/widgets/device_detail_sheet.dart';
import 'package:bluetooth/widgets/rssi_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:universal_ble/universal_ble.dart';

/// Main screen: lists discovered BLE devices with scan controls.
class ScannerScreen extends StatelessWidget {
  const ScannerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<BluetoothCubit>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('BLE Scanner'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: BlocBuilder<BluetoothCubit, BluetoothState>(
            builder: (context, state) {
              final (label, color) = switch (state) {
                BluetoothInitialized(:final availabilityState) => (
                  'BLE: ${availabilityState.name}',
                  Colors.green,
                ),
                BluetoothAvailabilityChanged(:final availabilityState) => (
                  'BLE: ${availabilityState.name}',
                  Colors.orange,
                ),
                BluetoothScanning() => ('Scanning…', Colors.blue),
                BluetoothScanStopped() => ('Scan stopped', Colors.grey),
                BluetoothError(:final message) => (
                  'Error: $message',
                  Colors.red,
                ),
                _ => ('Initialising…', Colors.grey),
              };
              return Container(
                width: double.infinity,
                color: color.withValues(alpha: 0.15),
                padding: const EdgeInsets.symmetric(
                  vertical: 4,
                  horizontal: 16,
                ),
                child: Text(
                  label,
                  style: TextStyle(color: color, fontWeight: FontWeight.w600),
                ),
              );
            },
          ),
        ),
      ),

      // ── Device list ──────────────────────────────────────────
      body: BlocBuilder<BluetoothCubit, BluetoothState>(
        buildWhen: (_, curr) =>
            curr is BluetoothLoading ||
            curr is BluetoothScanning ||
            curr is BluetoothScanResult ||
            curr is BluetoothScanStopped ||
            curr is BluetoothInitialized ||
            curr is BluetoothError,
        builder: (context, state) {
          final List<BleDevice> devices = switch (state) {
            BluetoothScanResult(:final devices) => devices,
            _ => const [],
          };

          if (state is BluetoothLoading) {
            return const Center(child: CircularProgressIndicator());
          }

          if (devices.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.bluetooth_searching,
                    size: 72,
                    color: Colors.deepPurple.shade200,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    state is BluetoothScanning
                        ? 'Looking for devices…'
                        : 'Press ▶ to start scanning',
                    style: const TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                ],
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: devices.length,
            separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
            itemBuilder: (_, index) {
              final device = devices[index];
              final name = device.name?.isNotEmpty == true
                  ? device.name!
                  : 'Unknown Device';
              final rssi = device.rssi;
              final isPaired = cubit.pairedDeviceIds.contains(device.deviceId);

              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: isPaired
                      ? Colors.green.shade50
                      : Colors.deepPurple.shade50,
                  child: Icon(
                    Icons.bluetooth,
                    color: isPaired ? Colors.green : Colors.deepPurple,
                  ),
                ),
                title: Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (isPaired)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.green.shade50,
                          border: Border.all(color: Colors.green.shade300),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          'Paired ✓',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.green.shade700,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
                subtitle: Text(
                  device.deviceId,
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (rssi != null) RssiChip(rssi: rssi),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: Icon(
                        Icons.info_outline,
                        size: 20,
                        color: Colors.grey.shade400,
                      ),
                      tooltip: 'Device info',
                      onPressed: () => showModalBottomSheet(
                        context: context,
                        isScrollControlled: true,
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.vertical(
                            top: Radius.circular(20),
                          ),
                        ),
                        builder: (_) => BlocProvider.value(
                          value: cubit,
                          child: DeviceDetailSheet(device: device),
                        ),
                      ),
                    ),
                  ],
                ),
                // Tap → full log screen
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => BlocProvider.value(
                      value: cubit,
                      child: DeviceLogScreen(device: device),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),

      // ── Scan FAB ─────────────────────────────────────────────
      floatingActionButton: BlocBuilder<BluetoothCubit, BluetoothState>(
        builder: (context, state) {
          final isScanning = state is BluetoothScanning;
          return FloatingActionButton.extended(
            onPressed: () {
              if (isScanning) {
                cubit.stopScan();
              } else {
                cubit.startScan();
              }
            },
            icon: Icon(isScanning ? Icons.stop : Icons.play_arrow),
            label: Text(isScanning ? 'Stop' : 'Scan'),
            backgroundColor: isScanning
                ? Colors.red.shade400
                : Colors.deepPurple,
            foregroundColor: Colors.white,
          );
        },
      ),
    );
  }
}
