import 'package:bluetooth/cubit/bluetooth_cubit.dart';
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
      appBar: AppBar(title: const Text('BLE Scanner')),

      // ── Device list ──────────────────────────────────────────
      body: BlocBuilder<BluetoothCubit, BluetoothState>(
        builder: (context, state) {
          final List<BleDevice> devices = cubit.discoveredDevices;

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
                    state is BluetoothScanState && state.isScanning
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
              final isConnected = cubit.connectedDevices.containsKey(
                device.deviceId,
              );

              return InkWell(
                onTap: () => showModalBottomSheet(
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
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16.0,
                    vertical: 12.0,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CircleAvatar(
                        radius: 24,
                        backgroundColor: isConnected
                            ? Colors.blue.shade50
                            : isPaired
                            ? Colors.green.shade50
                            : Colors.deepPurple.shade50,
                        child: Icon(
                          Icons.bluetooth,
                          color: isConnected
                              ? Colors.blue
                              : isPaired
                              ? Colors.green
                              : Colors.deepPurple,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              device.deviceId,
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey.shade600,
                                fontFamily: 'monospace',
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                if (rssi != null) RssiChip(rssi: rssi),
                                if (isPaired && !isConnected)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.green.shade50,
                                      border: Border.all(
                                        color: Colors.green.shade300,
                                      ),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.check_circle_outline,
                                          size: 14,
                                          color: Colors.green.shade700,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          'Paired',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.green.shade700,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                if (isConnected)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.blue.shade50,
                                      border: Border.all(
                                        color: Colors.blue.shade300,
                                      ),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.bluetooth_connected,
                                          size: 14,
                                          color: Colors.blue.shade700,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          'Connected',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.blue.shade700,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            icon: Icon(
                              Icons.info_outline,
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
                    ],
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
          final isScanning = state is BluetoothScanState && state.isScanning;
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
