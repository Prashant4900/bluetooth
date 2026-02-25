import 'package:bluetooth/cubit/bluetooth_cubit.dart';
import 'package:bluetooth/models/ble_log_entry.dart';
import 'package:bluetooth/widgets/log_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:universal_ble/universal_ble.dart';

// ─────────────────────────────────────────────────────────────────────────────
// DeviceLogScreen
// ─────────────────────────────────────────────────────────────────────────────

class DeviceLogScreen extends StatefulWidget {
  const DeviceLogScreen({super.key, required this.device});
  final BleDevice device;

  @override
  State<DeviceLogScreen> createState() => _DeviceLogScreenState();
}

class _DeviceLogScreenState extends State<DeviceLogScreen> {
  late final BluetoothCubit _cubit;
  final ScrollController _scrollCtrl = ScrollController();
  LogFilterType _filter = LogFilterType.all;
  bool _autoScroll = true;

  @override
  void initState() {
    super.initState();
    _cubit = context.read<BluetoothCubit>();
    _cubit.loadDeviceLogs(widget.device.deviceId);
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_autoScroll && _scrollCtrl.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollCtrl.hasClients) {
          _scrollCtrl.animateTo(
            _scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  List<BleLogEntry> _applyFilter(List<BleLogEntry> logs) {
    return switch (_filter) {
      LogFilterType.all => logs,
      LogFilterType.incoming =>
        logs.where((e) => e.direction == LogDirection.incoming).toList(),
      LogFilterType.outgoing =>
        logs.where((e) => e.direction == LogDirection.outgoing).toList(),
      LogFilterType.system =>
        logs.where((e) => e.direction == LogDirection.system).toList(),
      LogFilterType.errors =>
        logs.where((e) => e.type == LogType.error).toList(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final deviceName = widget.device.name?.isNotEmpty == true
        ? widget.device.name!
        : 'Unknown Device';

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              deviceName,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            Text(
              widget.device.deviceId,
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _autoScroll ? 'Auto-scroll ON' : 'Auto-scroll OFF',
            onPressed: () => setState(() => _autoScroll = !_autoScroll),
            icon: Icon(
              _autoScroll ? Icons.vertical_align_bottom : Icons.pause,
              color: _autoScroll ? Colors.greenAccent : Colors.grey,
            ),
          ),
          IconButton(
            tooltip: 'Clear logs',
            onPressed: () => _showClearConfirm(context),
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
          ),
        ],
      ),

      body: Column(
        children: [
          // ── Filter bar ──
          LogFilterBar(
            current: _filter,
            onChanged: (f) => setState(() => _filter = f),
          ),

          // ── Log list ──
          Expanded(
            child: BlocConsumer<BluetoothCubit, BluetoothState>(
              listenWhen: (_, curr) =>
                  curr is BluetoothLogsUpdated &&
                  (curr).deviceId == widget.device.deviceId,
              listener: (_, _) => _scrollToBottom(),
              buildWhen: (_, curr) =>
                  curr is BluetoothLogsUpdated &&
                  (curr).deviceId == widget.device.deviceId,
              builder: (context, _) {
                final logs = _cubit.logsFor(widget.device.deviceId);
                final filtered = _applyFilter(logs);

                if (filtered.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.terminal,
                          size: 48,
                          color: Colors.grey.shade700,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          logs.isEmpty
                              ? 'No logs yet.\nInteract with the device to see events.'
                              : 'No logs matching filter.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.only(
                    left: 8,
                    right: 8,
                    top: 4,
                    bottom: 80,
                  ),
                  itemCount: filtered.length,
                  itemBuilder: (_, i) => LogTile(entry: filtered[i]),
                );
              },
            ),
          ),
        ],
      ),

      floatingActionButton: BlocBuilder<BluetoothCubit, BluetoothState>(
        buildWhen: (_, curr) =>
            curr is BluetoothLogsUpdated &&
            (curr).deviceId == widget.device.deviceId,
        builder: (context, _) {
          final count = _cubit.logsFor(widget.device.deviceId).length;
          return FloatingActionButton.small(
            onPressed: () {
              setState(() => _autoScroll = true);
              _scrollToBottom();
            },
            backgroundColor: Colors.deepPurple,
            tooltip: 'Jump to latest',
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.arrow_downward, size: 14, color: Colors.white),
                Text(
                  '$count',
                  style: const TextStyle(fontSize: 9, color: Colors.white70),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showClearConfirm(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear logs?'),
        content: const Text(
          'This will delete all stored logs for this device. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _cubit.clearDeviceLogs(widget.device.deviceId);
            },
            child: const Text('Clear', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
