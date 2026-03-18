import 'dart:async';

import 'package:bluetooth/bluetooth_service.dart';
import 'package:bluetooth/models/ble_log_entry.dart';
import 'package:bluetooth/repositories/ble_log_repository.dart';
import 'package:bluetooth/services/background_service_bridge.dart';
import 'package:bluetooth/storage/pairing_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

enum RepoConnectionStatus { connecting, connected, disconnected }

class RepoConnectionEvent {
  final BleDevice device;
  final RepoConnectionStatus status;
  RepoConnectionEvent(this.device, this.status);
}

class RepoPairingEvent {
  final String deviceId;
  final bool isLoading;
  final bool? isPaired;
  RepoPairingEvent(this.deviceId, this.isLoading, {this.isPaired});
}

class BleRepository {
  final BluetoothService ble = BluetoothService();
  final BleLogRepository logRepository;

  BleRepository({required this.logRepository});

  // ── STATE EXPOSURE ──────────────────────────────────────────

  Set<String> _pairedDeviceIds = {};
  Set<String> get pairedDeviceIds => Set.unmodifiable(_pairedDeviceIds);
  final _pairedDevicesController = StreamController<Set<String>>.broadcast();
  Stream<Set<String>> get onPairedDevicesChanged =>
      _pairedDevicesController.stream;

  final List<BleDevice> _discoveredDevices = [];
  List<BleDevice> get discoveredDevices =>
      List.unmodifiable(_discoveredDevices);
  bool isScanning = false;
  final _scanStateController = StreamController<void>.broadcast();
  Stream<void> get onScanStateChanged => _scanStateController.stream;

  final Map<String, BleDevice> _connectedDevices = {};
  Map<String, BleDevice> get connectedDevices =>
      Map.unmodifiable(_connectedDevices);
  final Set<String> _connectingDevices = {};

  final _connectionStateController =
      StreamController<RepoConnectionEvent>.broadcast();
  Stream<RepoConnectionEvent> get onConnectionStateChanged =>
      _connectionStateController.stream;

  final _errorController = StreamController<String>.broadcast();
  Stream<String> get onError => _errorController.stream;

  final _pairingEventController =
      StreamController<RepoPairingEvent>.broadcast();
  Stream<RepoPairingEvent> get onPairingEvent => _pairingEventController.stream;

  // ── INTERNAL SUBSCRIPTIONS ──────────────────────────────────
  StreamSubscription<BleConnectionEvent>? _globalConnectionSub;
  StreamSubscription<BleDevice>? _scanSub;
  final Map<String, StreamSubscription<Uint8List>> _notifySubs = {};

  // ── INITIALIZE ──────────────────────────────────────────────
  Future<void> initialize() async {
    try {
      await ble.stopScanIfActive();
      final availState = await ble.initialize();

      await _loadPairedDevices();

      _globalConnectionSub?.cancel();
      _globalConnectionSub = ble.connectionStateStream.listen((event) async {
        final knownName = _discoveredDevices
            .cast<BleDevice?>()
            .firstWhere(
              (d) => d?.deviceId == event.deviceId,
              orElse: () => null,
            )
            ?.name;

        if (knownName?.startsWith('LMNP') != true) return;

        if (event.isConnected) {
          _connectingDevices.remove(event.deviceId);
          final dev = BleDevice(deviceId: event.deviceId, name: knownName);
          _connectedDevices[event.deviceId] = dev;

          if (!_discoveredDevices.any((d) => d.deviceId == event.deviceId)) {
            _discoveredDevices.add(dev);
            _scanStateController.add(null);
          }

          _connectionStateController.add(
            RepoConnectionEvent(dev, RepoConnectionStatus.connected),
          );

          await logRepository.addLog(
            BleLogEntry.system(
              deviceId: event.deviceId,
              deviceName: knownName,
              message:
                  'Connected to "${knownName ?? event.deviceId}"${event.error != null ? " (${event.error})" : ""}',
            ),
          );

          await logRepository.loadDeviceLogs(event.deviceId);
        } else {
          _connectingDevices.remove(event.deviceId);
          final dev = BleDevice(deviceId: event.deviceId, name: knownName);
          _connectedDevices.remove(event.deviceId);
          _connectionStateController.add(
            RepoConnectionEvent(dev, RepoConnectionStatus.disconnected),
          );

          await logRepository.addLog(
            BleLogEntry.system(
              deviceId: event.deviceId,
              deviceName: knownName,
              message: event.error != null
                  ? 'Disconnected from "${knownName ?? event.deviceId}" — ${event.error}'
                  : 'Disconnected from "${knownName ?? event.deviceId}"',
            ),
          );
        }
      });

      if (availState == AvailabilityState.poweredOn) {
        await startScan();
      }
    } catch (e) {
      _errorController.add(e.toString());
    }
  }

  Future<void> _loadPairedDevices() async {
    _pairedDeviceIds = await PairingStorage.loadPairedIds();
    _pairedDevicesController.add(Set.unmodifiable(_pairedDeviceIds));
  }

  // ── SCANNING ────────────────────────────────────────────────
  Future<void> startScan({List<String> withServices = const []}) async {
    _discoveredDevices.removeWhere(
      (d) => !_pairedDeviceIds.contains(d.deviceId),
    );
    isScanning = true;
    _scanStateController.add(null);

    try {
      _scanSub?.cancel();
      _scanSub = ble.scanStream.listen((device) {
        if (device.name?.startsWith('LMNP') != true) return;

        final exists = _discoveredDevices.any(
          (d) => d.deviceId == device.deviceId,
        );
        if (!exists) {
          _discoveredDevices.add(device);
          _scanStateController.add(null);
          logRepository.addLog(
            BleLogEntry.system(
              deviceId: device.deviceId,
              deviceName: device.name,
              message:
                  'Discovered: "${device.name ?? "Unknown"}"${device.rssi != null ? " — RSSI ${device.rssi} dBm" : ""}',
            ),
          );
        }

        if (_pairedDeviceIds.contains(device.deviceId) &&
            !_connectedDevices.containsKey(device.deviceId) &&
            !_connectingDevices.contains(device.deviceId)) {
          // Check the real OS-level connection state first.
          // If the OS already has an active connection (e.g., reconnected in
          // background before app opened), sync our state without sending a
          // redundant connect request to the device.
          UniversalBle.getConnectionState(device.deviceId).then((state) {
            if (state == BleConnectionState.connected) {
              debugPrint(
                '[BLE] ${device.name ?? device.deviceId} already connected '
                'at OS level — skipping connect request',
              );
              _connectingDevices.remove(device.deviceId);
              _connectedDevices[device.deviceId] = device;
              _connectionStateController.add(
                RepoConnectionEvent(device, RepoConnectionStatus.connected),
              );
              logRepository.addLog(
                BleLogEntry.system(
                  deviceId: device.deviceId,
                  deviceName: device.name,
                  message:
                      'Already connected to "${device.name ?? device.deviceId}" — synced state',
                ),
              );
            } else {
              connect(device, delay: const Duration(milliseconds: 800));
            }
          }).catchError((_) {
            // If we can't determine state, fall back to connecting normally.
            connect(device, delay: const Duration(milliseconds: 800));
          });
        }
      });

      await ble.startScan(withServices: withServices);
    } catch (e) {
      _errorController.add(e.toString());
    }
  }

  Future<void> stopScan() async {
    try {
      await ble.stopScan();
      _scanSub?.cancel();
      isScanning = false;
      _scanStateController.add(null);
    } catch (e) {
      _errorController.add(e.toString());
    }
  }

  // ── CONNECTION ──────────────────────────────────────────────
  Future<void> connect(
    BleDevice device, {
    Duration delay = Duration.zero,
  }) async {
    if (_connectingDevices.contains(device.deviceId) ||
        _connectedDevices.containsKey(device.deviceId)) {
      return;
    }

    _connectingDevices.add(device.deviceId);

    if (delay > Duration.zero) {
      await Future.delayed(delay);
      // Double check state hasn't changed during the delay
      if (_connectedDevices.containsKey(device.deviceId)) {
        _connectingDevices.remove(device.deviceId);
        return;
      }
    }
    _connectionStateController.add(
      RepoConnectionEvent(device, RepoConnectionStatus.connecting),
    );
    await logRepository.addLog(
      BleLogEntry.system(
        deviceId: device.deviceId,
        deviceName: device.name,
        message: 'Connecting to "${device.name ?? device.deviceId}"…',
      ),
    );
    try {
      await ble.connect(device);
      // Wait for _globalConnectionSub to handle the confirmation and logs
    } catch (e) {
      _connectingDevices.remove(device.deviceId);
      await logRepository.addLog(
        BleLogEntry.system(
          deviceId: device.deviceId,
          deviceName: device.name,
          message: 'Connection failed: $e',
        ),
      );
      _errorController.add(e.toString());
    }
  }

  Future<void> disconnect(BleDevice device) async {
    if (!_connectedDevices.containsKey(device.deviceId)) return;
    try {
      await ble.disconnect(device);
      // Wait for _globalConnectionSub to handle the confirmation and logs
    } catch (e) {
      _errorController.add(e.toString());
    }
  }

  // ── READ / WRITE / DISCOVER ─────────────────────────────────
  Future<void> discoverServices(BleDevice device) async {
    try {
      final services = await ble.discoverServices(device);
      await logRepository.addLog(
        BleLogEntry.system(
          deviceId: device.deviceId,
          deviceName: device.name,
          message:
              'Discovered ${services.length} service(s): ${services.map((s) => s.uuid).join(", ")}',
        ),
      );
    } catch (e) {
      _errorController.add(e.toString());
    }
  }

  Future<void> read(
    BleCharacteristic characteristic, {
    String? deviceId,
    String? deviceName,
  }) async {
    try {
      await ble.read(characteristic);
      if (deviceId != null) {
        await logRepository.addLog(
          BleLogEntry.system(
            deviceId: deviceId,
            deviceName: deviceName,
            message: 'Read from ${characteristic.uuid}',
          ),
        );
      }
    } catch (e) {
      _errorController.add(e.toString());
    }
  }

  Future<void> write(
    BleCharacteristic characteristic,
    List<int> data, {
    bool withResponse = true,
    String? deviceId,
    String? deviceName,
  }) async {
    try {
      await ble.write(characteristic, data, withResponse: withResponse);
      if (deviceId != null) {
        await logRepository.addLog(
          BleLogEntry.system(
            deviceId: deviceId,
            deviceName: deviceName,
            message:
                'Write${withResponse ? " (with response)" : " (no response)"} to ${characteristic.uuid}',
          ),
        );
      }
    } catch (e) {
      _errorController.add(e.toString());
    }
  }

  Future<void> subscribe(
    BleCharacteristic characteristic, {
    bool useIndications = false,
    String? deviceId,
    String? deviceName,
  }) async {
    try {
      _notifySubs[characteristic.uuid.toString()]?.cancel();
      void handler(Uint8List data) {
        debugPrint('[BLE] Data received: ${data.length} byte(s)');
      }

      final subKey = characteristic.uuid.toString();
      if (useIndications) {
        _notifySubs[subKey] = await ble.subscribeIndications(
          characteristic,
          handler,
        );
      } else {
        _notifySubs[subKey] = await ble.subscribeNotifications(
          characteristic,
          handler,
        );
      }
      if (deviceId != null) {
        await logRepository.addLog(
          BleLogEntry.system(
            deviceId: deviceId,
            deviceName: deviceName,
            message:
                'Subscribed to ${useIndications ? "indications" : "notifications"} on ${characteristic.uuid}',
          ),
        );
      }
    } catch (e) {
      _errorController.add(e.toString());
    }
  }

  Future<void> unsubscribe(BleCharacteristic characteristic) async {
    try {
      await ble.unsubscribe(characteristic);
      final subKey = characteristic.uuid.toString();
      _notifySubs[subKey]?.cancel();
      _notifySubs.remove(subKey);
    } catch (e) {
      _errorController.add(e.toString());
    }
  }

  // ── PAIRING ─────────────────────────────────────────────────
  Future<void> pairDevice(
    BleDevice device, {
    BleCommand? pairingCommand,
  }) async {
    _pairingEventController.add(RepoPairingEvent(device.deviceId, true));
    await logRepository.addLog(
      BleLogEntry.system(
        deviceId: device.deviceId,
        deviceName: device.name,
        message: 'Pairing requested with "${device.name ?? device.deviceId}"…',
      ),
    );
    try {
      await ble.pair(device, pairingCommand: pairingCommand);
      await PairingStorage.savePaired(device.deviceId);
      _pairedDeviceIds = await PairingStorage.loadPairedIds();
      await logRepository.addLog(
        BleLogEntry.system(
          deviceId: device.deviceId,
          deviceName: device.name,
          message: 'Paired successfully & saved to storage',
        ),
      );
      await BackgroundServiceBridge.start();
      _pairedDevicesController.add(Set.unmodifiable(_pairedDeviceIds));
      _pairingEventController.add(
        RepoPairingEvent(device.deviceId, false, isPaired: true),
      );
      connect(device);
    } catch (e) {
      await logRepository.addLog(
        BleLogEntry.system(
          deviceId: device.deviceId,
          deviceName: device.name,
          message: 'Pair failed: $e',
        ),
      );
      _errorController.add(e.toString());
    }
  }

  Future<void> unpairDevice(BleDevice device) async {
    _pairingEventController.add(RepoPairingEvent(device.deviceId, true));
    await logRepository.addLog(
      BleLogEntry.system(
        deviceId: device.deviceId,
        deviceName: device.name,
        message: 'Unpair requested for "${device.name ?? device.deviceId}"…',
      ),
    );
    try {
      // Explicitly disconnect if currently connected so the OS-level BLE
      // connection is terminated. Without this, unpairing only removes the
      // device from app state while the GATT connection stays alive,
      // preventing the physical device from auto-powering off.
      if (_connectedDevices.containsKey(device.deviceId)) {
        await ble.disconnect(device);
        _connectedDevices.remove(device.deviceId);
        debugPrint('[BLE] Disconnected before unpairing ${device.name ?? device.deviceId}');
      }
      await ble.unpair(device);
      await PairingStorage.removePaired(device.deviceId);
      _pairedDeviceIds = await PairingStorage.loadPairedIds();
      await logRepository.addLog(
        BleLogEntry.system(
          deviceId: device.deviceId,
          deviceName: device.name,
          message: 'Unpaired & removed from storage',
        ),
      );
      if (_pairedDeviceIds.isEmpty) {
        await BackgroundServiceBridge.stop();
      }
      _pairedDevicesController.add(Set.unmodifiable(_pairedDeviceIds));
      _pairingEventController.add(
        RepoPairingEvent(device.deviceId, false, isPaired: false),
      );
    } catch (e) {
      await logRepository.addLog(
        BleLogEntry.system(
          deviceId: device.deviceId,
          deviceName: device.name,
          message: 'Unpair failed: $e',
        ),
      );
      _errorController.add(e.toString());
    }
  }

  void dispose() {
    _globalConnectionSub?.cancel();
    _scanSub?.cancel();

    for (final sub in _notifySubs.values) {
      sub.cancel();
    }
    _pairedDevicesController.close();
    _scanStateController.close();
    _connectionStateController.close();
    _errorController.close();
    _pairingEventController.close();
  }
}
