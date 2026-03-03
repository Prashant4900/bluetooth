import 'package:bluetooth/models/ble_log_entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ─────────────────────────────────────────────────────────────────────────────
// LogTile — a single log entry row
// ─────────────────────────────────────────────────────────────────────────────

class LogTile extends StatefulWidget {
  const LogTile({super.key, required this.entry});
  final BleLogEntry entry;

  @override
  State<LogTile> createState() => _LogTileState();
}

class _LogTileState extends State<LogTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final hasData = e.hexData != null;

    return GestureDetector(
      onLongPress: () {
        final text =
            '[${e.timeLabel}] ${e.message}'
            '${e.hexData != null ? '\nHEX: ${e.hexData}' : ''}'
            '${e.asciiData != null ? '\nASCII: ${e.asciiData}' : ''}';
        Clipboard.setData(ClipboardData(text: text));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Copied to clipboard'),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 1),
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xFF161B22),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.transparent),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header row ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  Text(
                    e.timeLabel,
                    style: const TextStyle(
                      fontSize: 10,
                      color: Color(0xFF8B949E),
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.grey.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: const Text(
                      'LOG',
                      style: TextStyle(
                        fontSize: 9,
                        color: Colors.grey,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      e.message,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white70,
                      ),
                    ),
                  ),
                  if (hasData)
                    GestureDetector(
                      onTap: () => setState(() => _expanded = !_expanded),
                      child: Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        size: 16,
                        color: Colors.grey.shade500,
                      ),
                    ),
                ],
              ),
            ),

            // ── Data block (expanded) ──
            if (hasData && _expanded)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Divider(color: Color(0xFF30363D), height: 8),
                    _dataRow('HEX', e.hexData!, Colors.grey),
                    if (e.asciiData != null)
                      _dataRow('ASCII', e.asciiData!, Colors.grey.shade400),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _dataRow(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 44,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: Colors.grey.shade600,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                fontSize: 11,
                color: color,
                fontFamily: 'monospace',
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
