import 'package:bluetooth/cubit/bluetooth_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:universal_ble/universal_ble.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => BluetoothCubit()..initialize(),
      child: MaterialApp(
        title: 'BLE Scanner',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        ),
        home: const MyHomePage(),
      ),
    );
  }
}

class MyHomePage extends StatelessWidget {
  const MyHomePage({super.key});

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

      // ── Device list ────────────────────────────────────────
      body: BlocBuilder<BluetoothCubit, BluetoothState>(
        // Only rebuild when scan-related state changes — this prevents
        // the device list from wiping when e.g. availability changes.
        buildWhen: (_, curr) =>
            curr is BluetoothLoading ||
            curr is BluetoothScanning ||
            curr is BluetoothScanResult ||
            curr is BluetoothScanStopped ||
            curr is BluetoothInitialized ||
            curr is BluetoothError,
        builder: (context, state) {
          // Collect devices from the latest scan-result state
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
              final name = (device.name?.isNotEmpty == true)
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
                trailing: rssi != null ? _RssiChip(rssi: rssi) : null,
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
                    child: _DeviceDetailSheet(device: device),
                  ),
                ),
              );
            },
          );
        },
      ),

      // ── Scan FAB ───────────────────────────────────────────
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

/// Small coloured chip that shows RSSI with a signal-strength icon.
class _RssiChip extends StatelessWidget {
  const _RssiChip({required this.rssi});
  final int rssi;

  Color get _color {
    if (rssi >= -60) return Colors.green;
    if (rssi >= -80) return Colors.orange;
    return Colors.red;
  }

  IconData get _icon {
    if (rssi >= -60) return Icons.signal_wifi_4_bar;
    if (rssi >= -80) return Icons.network_wifi_2_bar;
    return Icons.network_wifi_1_bar;
  }

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(_icon, size: 16, color: _color),
      label: Text('$rssi dBm', style: TextStyle(fontSize: 12, color: _color)),
      backgroundColor: _color.withValues(alpha: 0.1),
      side: BorderSide(color: _color.withValues(alpha: 0.3)),
      padding: EdgeInsets.zero,
    );
  }
}

// ─────────────────────────────────────────────────
// Device Detail Bottom Sheet
// ─────────────────────────────────────────────────
class _DeviceDetailSheet extends StatelessWidget {
  const _DeviceDetailSheet({required this.device});
  final BleDevice device;

  @override
  Widget build(BuildContext context) {
    final ts = device.timestampDateTime;
    final mfList = device.manufacturerDataList;

    return BlocConsumer<BluetoothCubit, BluetoothState>(
      listenWhen: (_, curr) =>
          curr is BluetoothPaired || curr is BluetoothError,
      listener: (context, state) {
        if (state is BluetoothPaired && state.deviceId == device.deviceId) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                state.isPaired
                    ? '✓ Paired and saved!'
                    : '✓ Unpaired and removed from storage',
              ),
              behavior: SnackBarBehavior.floating,
              backgroundColor: state.isPaired ? Colors.green : Colors.orange,
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
          curr is BluetoothPairedDevicesLoaded ||
          curr is BluetoothPaired ||
          curr is BluetoothPairingInProgress,
      builder: (context, state) {
        final cubit = context.read<BluetoothCubit>();
        final isStoredPaired = cubit.pairedDeviceIds.contains(device.deviceId);
        final isPairing =
            state is BluetoothPairingInProgress &&
            state.deviceId == device.deviceId;

        return DraggableScrollableSheet(
          initialChildSize: 0.65,
          minChildSize: 0.4,
          maxChildSize: 0.95,
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
                            if (device.rawName != null &&
                                device.rawName != device.name)
                              Text(
                                'Raw: ${device.rawName}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade600,
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
                      if (device.rssi != null) _RssiChip(rssi: device.rssi!),
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
                      _InfoRow(
                        icon: Icons.fingerprint,
                        label: 'Device ID',
                        value: device.deviceId,
                        selectable: true,
                      ),
                      _InfoRow(
                        icon: Icons.signal_cellular_alt,
                        label: 'RSSI',
                        value: device.rssi != null
                            ? '${device.rssi} dBm'
                            : 'Not available',
                      ),
                      _InfoRow(
                        icon: Icons.lock,
                        label: 'OS Paired',
                        value: device.paired == null
                            ? 'Unknown'
                            : device.paired!
                            ? 'Yes ✓'
                            : 'No',
                        valueColor: device.paired == true ? Colors.green : null,
                      ),
                      _InfoRow(
                        icon: Icons.save,
                        label: 'App Paired',
                        value: isStoredPaired ? 'Yes ✓' : 'No',
                        valueColor: isStoredPaired ? Colors.green : null,
                      ),
                      _InfoRow(
                        icon: Icons.settings_bluetooth,
                        label: 'System Device',
                        value: device.isSystemDevice == true ? 'Yes' : 'No',
                      ),
                      _InfoRow(
                        icon: Icons.access_time,
                        label: 'Discovered At',
                        value: ts != null
                            ? '${ts.hour.toString().padLeft(2, "0")}:'
                                  '${ts.minute.toString().padLeft(2, "0")}:'
                                  '${ts.second.toString().padLeft(2, "0")}'
                            : 'Unknown',
                      ),
                      const SizedBox(height: 8),
                      _SectionHeader(
                        icon: Icons.miscellaneous_services,
                        label:
                            'Advertised Services (${device.services.length})',
                      ),
                      if (device.services.isEmpty)
                        _EmptyRow('No services advertised')
                      else
                        ...device.services.map(
                          (s) => _InfoRow(
                            icon: Icons.circle,
                            iconSize: 8,
                            label: '',
                            value: s,
                            selectable: true,
                          ),
                        ),
                      const SizedBox(height: 8),
                      _SectionHeader(
                        icon: Icons.factory,
                        label: 'Manufacturer Data (${mfList.length})',
                      ),
                      if (mfList.isEmpty)
                        _EmptyRow('No manufacturer data')
                      else
                        ...mfList.map((mf) {
                          final hex = mf.payload
                              .map(
                                (b) => b
                                    .toRadixString(16)
                                    .padLeft(2, '0')
                                    .toUpperCase(),
                              )
                              .join(' ');
                          return _InfoRow(
                            icon: Icons.memory,
                            label:
                                'Company 0x${mf.companyId.toRadixString(16).toUpperCase().padLeft(4, "0")}',
                            value: hex.isNotEmpty ? hex : '(empty)',
                            selectable: true,
                          );
                        }),
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

/// A single labelled row in the detail sheet.
class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.iconSize = 20,
    this.selectable = false,
    this.valueColor,
  });
  final IconData icon;
  final double iconSize;
  final String label;
  final String value;
  final bool selectable;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final valueWidget = selectable
        ? SelectableText(
            value,
            style: TextStyle(
              fontSize: 14,
              color: valueColor ?? Colors.black87,
              fontFamily: 'monospace',
            ),
          )
        : Text(
            value,
            style: TextStyle(fontSize: 14, color: valueColor ?? Colors.black87),
          );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: iconSize, color: Colors.deepPurple.shade300),
          const SizedBox(width: 12),
          if (label.isNotEmpty)
            ...([
              SizedBox(
                width: 120,
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ]),
          Expanded(child: valueWidget),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Colors.deepPurple),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Colors.deepPurple,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyRow extends StatelessWidget {
  const _EmptyRow(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        text,
        style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
      ),
    );
  }
}
