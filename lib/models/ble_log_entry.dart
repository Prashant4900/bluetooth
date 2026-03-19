import 'dart:convert';
import 'dart:typed_data';

class BleLogEntry {
  final String id;
  final DateTime timestamp;
  final String deviceId;
  final String? deviceName;
  final String message;

  /// Raw bytes as an uppercase hex string, e.g. "0A 1B FF".
  final String? hexData;

  /// Bytes decoded as ASCII — only set when every byte is a printable character.
  final String? asciiData;

  BleLogEntry({
    required this.id,
    required this.timestamp,
    required this.deviceId,
    this.deviceName,
    required this.message,
    this.hexData,
    this.asciiData,
  });

  // ── Factories ────────────────────────────────────────────────────────────

  /// Creates a plain text (non-data) log entry for system events.
  factory BleLogEntry.system({
    required String deviceId,
    String? deviceName,
    required String message,
  }) => BleLogEntry(
    id: DateTime.now().microsecondsSinceEpoch.toString(),
    timestamp: DateTime.now(),
    deviceId: deviceId,
    deviceName: deviceName,
    message: message,
  );

  /// Creates a log entry that also carries raw BLE bytes.
  factory BleLogEntry.data({
    required String deviceId,
    String? deviceName,
    required String message,
    required Uint8List bytes,
  }) {
    final hex = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(' ');

    // Only decode to ASCII when every byte is a printable character (32–126).
    final isPrintable = bytes.every((b) => b >= 32 && b < 127);

    return BleLogEntry(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      timestamp: DateTime.now(),
      deviceId: deviceId,
      deviceName: deviceName,
      message: message,
      hexData: hex.isNotEmpty ? hex : null,
      asciiData: isPrintable ? utf8.decode(bytes, allowMalformed: true) : null,
    );
  }

  // ── JSON ─────────────────────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
    'id': id,
    'ts': timestamp.millisecondsSinceEpoch,
    'dId': deviceId,
    'dName': deviceName,
    'msg': message,
    'hex': hexData,
    'ascii': asciiData,
  };

  factory BleLogEntry.fromJson(Map<String, dynamic> j) => BleLogEntry(
    id: j['id'] as String,
    timestamp: DateTime.fromMillisecondsSinceEpoch(j['ts'] as int),
    deviceId: j['dId'] as String,
    deviceName: j['dName'] as String?,
    message: j['msg'] as String,
    hexData: j['hex'] as String?,
    asciiData: j['ascii'] as String?,
  );

  // ── Display helpers ──────────────────────────────────────────────────────

  /// Human-readable timestamp: HH:MM:SS.mmm
  String get timeLabel {
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    final s = timestamp.second.toString().padLeft(2, '0');
    final ms = timestamp.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }
}
