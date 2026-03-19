import 'package:bluetooth/cubit/bluetooth_cubit.dart';
import 'package:bluetooth/models/ble_log_entry.dart';
import 'package:bluetooth/widgets/log_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class AllLogsScreen extends StatefulWidget {
  const AllLogsScreen({super.key});

  @override
  State<AllLogsScreen> createState() => _AllLogsScreenState();
}

class _AllLogsScreenState extends State<AllLogsScreen> {
  late final BluetoothCubit _cubit;
  final _scrollCtrl = ScrollController();
  String? _selectedDeviceId;

  // ── Theme colours ────────────────────────────────────────────────────────
  static const _bgDark = Color(0xFF0D1117);
  static const _bgBar = Color(0xFF161B22);
  static const _bgDrop = Color(0xFF21262D);

  @override
  void initState() {
    super.initState();
    _cubit = context.read<BluetoothCubit>();
    _cubit.loadAllLogs();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
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

  List<BleLogEntry> _applyFilter(List<BleLogEntry> logs) {
    return logs
        .where((e) => e.deviceName?.startsWith('LMNP') == true)
        .where(
          (e) => _selectedDeviceId == null || e.deviceId == _selectedDeviceId,
        )
        .toList();
  }

  // Builds a map of deviceId → displayName for devices that appear in the logs.
  Map<String, String> _buildDeviceMap(List<BleLogEntry> logs) {
    return {
      for (final log in logs)
        if (log.deviceName?.startsWith('LMNP') == true)
          log.deviceId:
              log.deviceName ?? 'Unknown (${log.deviceId.substring(0, 5)}…)',
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgDark,
      appBar: AppBar(
        backgroundColor: _bgBar,
        foregroundColor: Colors.white,
        title: const Text(
          'All Global Logs',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ),
      body: Column(
        children: [
          _DeviceFilterBar(
            bgColor: _bgBar,
            dropdownColor: _bgDrop,
            selectedDeviceId: _selectedDeviceId,
            deviceMap: _buildDeviceMap(_cubit.allLogs),
            cubit: _cubit,
            onChanged: (id) {
              setState(() => _selectedDeviceId = id);
              _scrollToBottom();
            },
          ),
          Expanded(
            child: BlocConsumer<BluetoothCubit, BluetoothState>(
              listenWhen: (_, curr) =>
                  curr is BluetoothLogsUpdated && curr.deviceId == 'all',
              listener: (_, _) => _scrollToBottom(),
              buildWhen: (_, curr) =>
                  curr is BluetoothLogsUpdated && curr.deviceId == 'all',
              builder: (_, _) {
                final logs = _cubit.allLogs;
                final filtered = _applyFilter(logs);

                if (filtered.isEmpty)
                  return _EmptyLogsPlaceholder(hasLogs: logs.isNotEmpty);

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
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Private sub-widgets
// ─────────────────────────────────────────────────────────────────────────────

class _DeviceFilterBar extends StatelessWidget {
  final Color bgColor;
  final Color dropdownColor;
  final String? selectedDeviceId;
  final Map<String, String> deviceMap;
  final BluetoothCubit cubit;
  final ValueChanged<String?> onChanged;

  const _DeviceFilterBar({
    required this.bgColor,
    required this.dropdownColor,
    required this.selectedDeviceId,
    required this.deviceMap,
    required this.cubit,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: bgColor,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Text(
            'Device:',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: BlocBuilder<BluetoothCubit, BluetoothState>(
              buildWhen: (_, curr) => curr is BluetoothLogsUpdated,
              builder: (_, _) {
                final map = _buildDeviceMap(cubit.allLogs);
                return DropdownButton<String?>(
                  value: selectedDeviceId,
                  dropdownColor: dropdownColor,
                  isExpanded: true,
                  icon: const Icon(
                    Icons.arrow_drop_down,
                    color: Colors.white70,
                  ),
                  underline: const SizedBox(),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  onChanged: onChanged,
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('All Devices'),
                    ),
                    ...map.entries.map(
                      (e) => DropdownMenuItem<String?>(
                        value: e.key,
                        child: Text(e.value),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Map<String, String> _buildDeviceMap(List<BleLogEntry> logs) => {
    for (final log in logs)
      if (log.deviceName?.startsWith('LMNP') == true)
        log.deviceId:
            log.deviceName ?? 'Unknown (${log.deviceId.substring(0, 5)}…)',
  };
}

class _EmptyLogsPlaceholder extends StatelessWidget {
  final bool hasLogs;

  const _EmptyLogsPlaceholder({required this.hasLogs});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.terminal, size: 48, color: Colors.grey.shade700),
          const SizedBox(height: 12),
          Text(
            hasLogs
                ? 'No logs matching filter.'
                : 'No logs yet.\nInteract with any device to see events.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
          ),
        ],
      ),
    );
  }
}
