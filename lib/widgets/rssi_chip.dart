import 'package:flutter/material.dart';

/// Small coloured chip showing RSSI signal strength.
class RssiChip extends StatelessWidget {
  const RssiChip({super.key, required this.rssi});
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
