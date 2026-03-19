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
      body: BlocBuilder<BluetoothCubit, BluetoothState>(
        builder: (context, state) {
          if (state is BluetoothLoading) {
            return const Center(child: CircularProgressIndicator());
          }

          final devices = cubit.discoveredDevices;
          if (devices.isEmpty) {
            return _EmptyDeviceList(
              isScanning: state is BluetoothScanState && state.isScanning,
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: devices.length,
            separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
            itemBuilder: (_, i) =>
                _DeviceTile(device: devices[i], cubit: cubit),
          );
        },
      ),
      floatingActionButton: BlocBuilder<BluetoothCubit, BluetoothState>(
        builder: (context, state) {
          final isScanning = state is BluetoothScanState && state.isScanning;
          return FloatingActionButton.extended(
            onPressed: () => isScanning ? cubit.stopScan() : cubit.startScan(),
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

// ─────────────────────────────────────────────────────────────────────────────
// Private sub-widgets
// ─────────────────────────────────────────────────────────────────────────────

class _EmptyDeviceList extends StatelessWidget {
  final bool isScanning;

  const _EmptyDeviceList({required this.isScanning});

  @override
  Widget build(BuildContext context) {
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
            isScanning ? 'Looking for devices…' : 'Press ▶ to start scanning',
            style: const TextStyle(fontSize: 16, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final BleDevice device;
  final BluetoothCubit cubit;

  const _DeviceTile({required this.device, required this.cubit});

  void _openDetailSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => BlocProvider.value(
        value: cubit,
        child: DeviceDetailSheet(device: device),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = device.name?.isNotEmpty == true
        ? device.name!
        : 'Unknown Device';
    final isPaired = cubit.pairedDeviceIds.contains(device.deviceId);
    final isConnected = cubit.connectedDevices.containsKey(device.deviceId);

    return InkWell(
      onTap: () => _openDetailSheet(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _DeviceAvatar(isPaired: isPaired, isConnected: isConnected),
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
                      if (device.rssi != null) RssiChip(rssi: device.rssi!),
                      if (isPaired && !isConnected) const _StatusChip.paired(),
                      if (isConnected) const _StatusChip.connected(),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            IconButton(
              icon: Icon(Icons.info_outline, color: Colors.grey.shade400),
              tooltip: 'Device info',
              onPressed: () => _openDetailSheet(context),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceAvatar extends StatelessWidget {
  final bool isPaired;
  final bool isConnected;

  const _DeviceAvatar({required this.isPaired, required this.isConnected});

  @override
  Widget build(BuildContext context) {
    final color = isConnected
        ? Colors.blue
        : isPaired
        ? Colors.green
        : Colors.deepPurple;

    return CircleAvatar(
      radius: 24,
      backgroundColor: color.withOpacity(0.1),
      child: Icon(Icons.bluetooth, color: color),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _StatusChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  const _StatusChip.paired()
    : icon = Icons.check_circle_outline,
      label = 'Paired',
      color = Colors.green;

  const _StatusChip.connected()
    : icon = Icons.bluetooth_connected,
      label = 'Connected',
      color = Colors.blue;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        border: Border.all(color: color.withOpacity(0.5)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
