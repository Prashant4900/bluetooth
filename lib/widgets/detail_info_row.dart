import 'package:flutter/material.dart';

/// A labelled icon-value row used inside the device detail sheet.
class DetailInfoRow extends StatelessWidget {
  const DetailInfoRow({
    super.key,
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

/// A bold section header with an icon, used inside the device detail sheet.
class DetailSectionHeader extends StatelessWidget {
  const DetailSectionHeader({
    super.key,
    required this.icon,
    required this.label,
  });

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

/// A subtle empty-state row used when a section has no data.
class DetailEmptyRow extends StatelessWidget {
  const DetailEmptyRow(this.text, {super.key});
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
