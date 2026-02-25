import 'dart:convert';
import 'dart:typed_data';

// ─────────────────────────────────────────────────
// Enums
// ─────────────────────────────────────────────────

enum LogDirection {
  /// Data sent from this device to the BLE peripheral.
  outgoing,

  /// Data received from the BLE peripheral.
  incoming,

  /// Internal / system event (connect, scan, pair, etc.).
  system,
}

enum LogType {
  scan,
  connect,
  disconnect,
  pair,
  unpair,
  read,
  write,
  notify,
  indicate,
  serviceDiscovery,
  error,
  info,
}

// ─────────────────────────────────────────────────
// BleLogEntry
// ─────────────────────────────────────────────────

class BleLogEntry {
  final String id;
  final DateTime timestamp;
  final String deviceId;
  final String? deviceName;
  final LogDirection direction;
  final LogType type;
  final String message;

  /// Raw bytes as an uppercase hex string, e.g. "0A 1B FF"
  final String? hexData;

  /// Same bytes decoded as ASCII – only populated when all bytes are printable.
  final String? asciiData;

  BleLogEntry({
    required this.id,
    required this.timestamp,
    required this.deviceId,
    this.deviceName,
    required this.direction,
    required this.type,
    required this.message,
    this.hexData,
    this.asciiData,
  });

  // ── Factory helpers ────────────────────────────

  factory BleLogEntry.system({
    required String deviceId,
    String? deviceName,
    required LogType type,
    required String message,
  }) => BleLogEntry(
    id: _id(),
    timestamp: DateTime.now(),
    deviceId: deviceId,
    deviceName: deviceName,
    direction: LogDirection.system,
    type: type,
    message: message,
  );

  factory BleLogEntry.data({
    required String deviceId,
    String? deviceName,
    required LogDirection direction,
    required LogType type,
    required String message,
    required Uint8List bytes,
  }) {
    final hex = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(' ');
    final isPrintable = bytes.every((b) => b >= 32 && b < 127);
    final ascii = isPrintable ? utf8.decode(bytes, allowMalformed: true) : null;
    return BleLogEntry(
      id: _id(),
      timestamp: DateTime.now(),
      deviceId: deviceId,
      deviceName: deviceName,
      direction: direction,
      type: type,
      message: message,
      hexData: hex.isNotEmpty ? hex : null,
      asciiData: ascii,
    );
  }

  static String _id() => DateTime.now().microsecondsSinceEpoch.toString();

  // ── JSON ───────────────────────────────────────

  Map<String, dynamic> toJson() => {
    'id': id,
    'ts': timestamp.millisecondsSinceEpoch,
    'dId': deviceId,
    'dName': deviceName,
    'dir': direction.index,
    'type': type.index,
    'msg': message,
    'hex': hexData,
    'ascii': asciiData,
  };

  factory BleLogEntry.fromJson(Map<String, dynamic> j) => BleLogEntry(
    id: j['id'] as String,
    timestamp: DateTime.fromMillisecondsSinceEpoch(j['ts'] as int),
    deviceId: j['dId'] as String,
    deviceName: j['dName'] as String?,
    direction: LogDirection.values[j['dir'] as int],
    type: LogType.values[j['type'] as int],
    message: j['msg'] as String,
    hexData: j['hex'] as String?,
    asciiData: j['ascii'] as String?,
  );

  // ── Display helpers ────────────────────────────

  String get timeLabel {
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    final s = timestamp.second.toString().padLeft(2, '0');
    final ms = timestamp.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }

  String get directionLabel => switch (direction) {
    LogDirection.outgoing => '↑ OUT',
    LogDirection.incoming => '↓ IN ',
    LogDirection.system => '● SYS',
  };

  String get typeLabel => switch (type) {
    LogType.scan => 'SCAN',
    LogType.connect => 'CONNECT',
    LogType.disconnect => 'DISCONNECT',
    LogType.pair => 'PAIR',
    LogType.unpair => 'UNPAIR',
    LogType.read => 'READ',
    LogType.write => 'WRITE',
    LogType.notify => 'NOTIFY',
    LogType.indicate => 'INDICATE',
    LogType.serviceDiscovery => 'SERVICES',
    LogType.error => 'ERROR',
    LogType.info => 'INFO',
  };
}
