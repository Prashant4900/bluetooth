import 'package:bluetooth/models/ble_log_entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Enum for the log list filter state.
enum LogFilterType { all, incoming, outgoing, system, errors }

// ─────────────────────────────────────────────────────────────────────────────
// LogFilterBar
// ─────────────────────────────────────────────────────────────────────────────

/// Horizontal scrollable filter chip bar for the log screen.
class LogFilterBar extends StatelessWidget {
  const LogFilterBar({
    super.key,
    required this.current,
    required this.onChanged,
  });

  final LogFilterType current;
  final ValueChanged<LogFilterType> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF161B22),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _chip('All', LogFilterType.all, Icons.list),
            _chip('In', LogFilterType.incoming, Icons.arrow_downward),
            _chip('Out', LogFilterType.outgoing, Icons.arrow_upward),
            _chip('System', LogFilterType.system, Icons.settings),
            _chip('Errors', LogFilterType.errors, Icons.error_outline),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, LogFilterType type, IconData icon) {
    final selected = current == type;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: selected ? Colors.white : Colors.grey),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: selected ? Colors.white : Colors.grey,
              ),
            ),
          ],
        ),
        selected: selected,
        onSelected: (_) => onChanged(type),
        backgroundColor: const Color(0xFF21262D),
        selectedColor: Colors.deepPurple,
        checkmarkColor: Colors.transparent,
        side: BorderSide(
          color: selected ? Colors.deepPurple : Colors.grey.shade800,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      ),
    );
  }
}

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

    final (dirColor, dirIcon) = switch (e.direction) {
      LogDirection.incoming => (const Color(0xFF00B4D8), Icons.arrow_downward),
      LogDirection.outgoing => (const Color(0xFF2DC653), Icons.arrow_upward),
      LogDirection.system => (const Color(0xFFB0B8C1), Icons.circle),
    };

    final typeColor = switch (e.type) {
      LogType.error => Colors.red.shade400,
      LogType.pair || LogType.unpair => Colors.amber.shade400,
      LogType.connect => Colors.greenAccent,
      LogType.disconnect => Colors.orange,
      _ => Colors.grey.shade500,
    };

    return GestureDetector(
      onLongPress: () {
        final text =
            '[${e.timeLabel}] [${e.directionLabel}] [${e.typeLabel}] ${e.message}'
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
          border: Border.all(
            color: e.type == LogType.error
                ? Colors.red.shade800
                : Colors.transparent,
          ),
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
                  Icon(dirIcon, size: 12, color: dirColor),
                  const SizedBox(width: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: typeColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      e.typeLabel,
                      style: TextStyle(
                        fontSize: 9,
                        color: typeColor,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      e.message,
                      style: TextStyle(
                        fontSize: 12,
                        color: e.type == LogType.error
                            ? Colors.red.shade300
                            : Colors.white70,
                      ),
                      overflow: TextOverflow.ellipsis,
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
                    _dataRow('HEX', e.hexData!, dirColor),
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
