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
  final ScrollController _scrollCtrl = ScrollController();
  LogFilterType _filter = LogFilterType.all;
  bool _autoScroll = true;
  String? _selectedDeviceId;

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
    var filtered = logs;

    // 1. Only show logs for devices starting with LMNP if filter is active
    if (_cubit.showOnlyLmnp) {
      filtered = filtered
          .where((e) => e.deviceName?.startsWith('LMNP') == true)
          .toList();
    }

    // 2. Filter by specific device if selected
    if (_selectedDeviceId != null) {
      filtered = filtered
          .where((e) => e.deviceId == _selectedDeviceId)
          .toList();
    }

    // 2. Filter by log type
    return switch (_filter) {
      LogFilterType.all => filtered,
      LogFilterType.incoming =>
        filtered.where((e) => e.direction == LogDirection.incoming).toList(),
      LogFilterType.outgoing =>
        filtered.where((e) => e.direction == LogDirection.outgoing).toList(),
      LogFilterType.system =>
        filtered.where((e) => e.direction == LogDirection.system).toList(),
      LogFilterType.errors =>
        filtered.where((e) => e.type == LogType.error).toList(),
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        foregroundColor: Colors.white,
        title: const Text(
          'All Global Logs',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        actions: [
          BlocBuilder<BluetoothCubit, BluetoothState>(
            builder: (context, state) {
              final isLmnpOnly = _cubit.showOnlyLmnp;
              return IconButton(
                tooltip: isLmnpOnly ? 'Show All Devices' : 'Show LMNP Only',
                onPressed: () => _cubit.toggleLmnpFilter(),
                icon: Icon(
                  isLmnpOnly ? Icons.filter_alt : Icons.filter_alt_off,
                  color: isLmnpOnly ? Colors.greenAccent : Colors.grey,
                ),
              );
            },
          ),
          IconButton(
            tooltip: _autoScroll ? 'Auto-scroll ON' : 'Auto-scroll OFF',
            onPressed: () => setState(() => _autoScroll = !_autoScroll),
            icon: Icon(
              _autoScroll ? Icons.vertical_align_bottom : Icons.pause,
              color: _autoScroll ? Colors.greenAccent : Colors.grey,
            ),
          ),
          IconButton(
            tooltip: 'Clear view',
            onPressed: () => setState(() {
              // Doing this clear might be confusing globally; a better option
              // might be just visual clearing or redirect to Device Log to clear.
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Global log clear not supported, clear individually via Device info.',
                  ),
                ),
              );
            }),
            icon: const Icon(Icons.delete_outline, color: Colors.grey),
          ),
        ],
      ),

      body: Column(
        children: [
          // ── Device filter dropdown & Filter bar ──
          Container(
            color: const Color(0xFF161B22),
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
                    builder: (context, _) {
                      final logs = _cubit.allLogs;
                      final isLmnpOnly = _cubit.showOnlyLmnp;
                      // Extract unique device IDs & names
                      final deviceMap = <String, String>{};
                      for (final log in logs) {
                        if (!isLmnpOnly ||
                            log.deviceName?.startsWith('LMNP') == true) {
                          deviceMap[log.deviceId] =
                              log.deviceName ??
                              'Unknown (${log.deviceId.substring(0, 5)}...)';
                        }
                      }

                      return DropdownButton<String?>(
                        value: _selectedDeviceId,
                        dropdownColor: const Color(0xFF21262D),
                        isExpanded: true,
                        icon: const Icon(
                          Icons.arrow_drop_down,
                          color: Colors.white70,
                        ),
                        underline: const SizedBox(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                        onChanged: (String? newValue) {
                          setState(() {
                            _selectedDeviceId = newValue;
                          });
                          _scrollToBottom();
                        },
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('All Devices'),
                          ),
                          ...deviceMap.entries.map(
                            (entry) => DropdownMenuItem<String?>(
                              value: entry.key,
                              child: Text(entry.value),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          LogFilterBar(
            current: _filter,
            onChanged: (f) => setState(() => _filter = f),
          ),

          // ── Log list ──
          Expanded(
            child: BlocConsumer<BluetoothCubit, BluetoothState>(
              listenWhen: (_, curr) =>
                  curr is BluetoothLogsUpdated && curr.deviceId == 'all',
              listener: (_, _) => _scrollToBottom(),
              buildWhen: (_, curr) =>
                  curr is BluetoothLogsUpdated && curr.deviceId == 'all',
              builder: (context, _) {
                final logs = _cubit.allLogs;
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
                              ? 'No logs yet.\nInteract with any device to see events.'
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
            curr is BluetoothLogsUpdated && curr.deviceId == 'all',
        builder: (context, _) {
          final count = _applyFilter(_cubit.allLogs).length;
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
}
