import 'package:bluetooth/cubit/bluetooth_cubit.dart';
import 'package:bluetooth/widgets/detail_info_row.dart';
import 'package:bluetooth/widgets/rssi_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:universal_ble/universal_ble.dart';

/// Modal bottom sheet showing key details and Pair/Unpair action for a BLE device.
class DeviceDetailSheet extends StatelessWidget {
  const DeviceDetailSheet({super.key, required this.device});
  final BleDevice device;

  @override
  Widget build(BuildContext context) {
    final ts = device.timestampDateTime;

    return BlocConsumer<BluetoothCubit, BluetoothState>(
      listenWhen: (_, curr) =>
          curr is BluetoothPairingState || curr is BluetoothError,
      listener: (context, state) {
        if (state is BluetoothPairingState &&
            !state.isLoading &&
            state.changedDeviceId == device.deviceId) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                state.isPaired == true
                    ? '✓ Paired and saved!'
                    : '✓ Unpaired and removed from storage',
              ),
              behavior: SnackBarBehavior.floating,
              backgroundColor: state.isPaired == true
                  ? Colors.green
                  : Colors.orange,
            ),
          );
        } else if (state is BluetoothError) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error: ${state.message}'),
              backgroundColor: Colors.red,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      },
      buildWhen: (_, curr) =>
          curr is BluetoothPairingState || curr is BluetoothError,
      builder: (context, state) {
        final cubit = context.read<BluetoothCubit>();
        final isStoredPaired = cubit.pairedDeviceIds.contains(device.deviceId);
        final isPairing =
            state is BluetoothPairingState &&
            state.isLoading &&
            state.changedDeviceId == device.deviceId;

        return DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.35,
          maxChildSize: 0.75,
          expand: false,
          builder: (_, controller) {
            return Column(
              children: [
                // ── Handle ──
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),

                // ── Header ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 24,
                        backgroundColor: isStoredPaired
                            ? Colors.green.shade50
                            : Colors.deepPurple.shade50,
                        child: Icon(
                          Icons.bluetooth,
                          color: isStoredPaired
                              ? Colors.green
                              : Colors.deepPurple,
                          size: 28,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              device.name?.isNotEmpty == true
                                  ? device.name!
                                  : 'Unknown Device',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            if (isStoredPaired)
                              Text(
                                'Saved as Paired ✓',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.green.shade600,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (device.rssi != null) RssiChip(rssi: device.rssi!),
                    ],
                  ),
                ),

                // ── Pair / Unpair button ──
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 4,
                  ),
                  child: isPairing
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 10),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              SizedBox(width: 10),
                              Text('Working…'),
                            ],
                          ),
                        )
                      : isStoredPaired
                      ? OutlinedButton.icon(
                          onPressed: () => cubit.unpairDevice(device),
                          icon: const Icon(Icons.link_off, color: Colors.red),
                          label: const Text(
                            'Unpair',
                            style: TextStyle(color: Colors.red),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Colors.red),
                            minimumSize: const Size(double.infinity, 44),
                          ),
                        )
                      : FilledButton.icon(
                          onPressed: () => cubit.pairDevice(device),
                          icon: const Icon(Icons.link),
                          label: const Text('Pair this device'),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.deepPurple,
                            minimumSize: const Size(double.infinity, 44),
                          ),
                        ),
                ),

                const Divider(height: 1),

                // ── Detail rows ──
                Expanded(
                  child: ListView(
                    controller: controller,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 8,
                    ),
                    children: [
                      DetailInfoRow(
                        icon: Icons.fingerprint,
                        label: 'Device ID',
                        value: device.deviceId,
                        selectable: true,
                      ),
                      DetailInfoRow(
                        icon: Icons.signal_cellular_alt,
                        label: 'RSSI',
                        value: device.rssi != null
                            ? '${device.rssi} dBm'
                            : 'Not available',
                      ),
                      DetailInfoRow(
                        icon: Icons.save,
                        label: 'App Paired',
                        value: isStoredPaired ? 'Yes ✓' : 'No',
                        valueColor: isStoredPaired ? Colors.green : null,
                      ),
                      DetailInfoRow(
                        icon: Icons.access_time,
                        label: 'Discovered At',
                        value: ts != null
                            ? '${ts.hour.toString().padLeft(2, "0")}:'
                                  '${ts.minute.toString().padLeft(2, "0")}:'
                                  '${ts.second.toString().padLeft(2, "0")}'
                            : 'Unknown',
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
