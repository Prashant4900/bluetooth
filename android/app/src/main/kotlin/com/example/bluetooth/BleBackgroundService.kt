package com.example.bluetooth

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import org.json.JSONObject
import java.time.Instant

/**
 * BleBackgroundService — Android foreground service that:
 *  • Survives app kill and device reboot (via BootReceiver)
 *  • Loads paired device IDs from SharedPreferences (key: ble_paired_devices)
 *  • Scans for those devices continuously
 *  • Auto-connects on discovery and logs every event to SharedPreferences
 *    under the same key format as the Dart LogStorage (ble_log_{deviceId})
 */
@SuppressLint("MissingPermission")
class BleBackgroundService : Service() {

    companion object {
        private const val TAG = "BleBackgroundService"
        const val CHANNEL_ID = "ble_monitor_channel"
        const val NOTIFICATION_ID = 7788

        // SharedPreferences file — matches what Flutter's shared_preferences uses.
        const val PREFS_FILE = "FlutterSharedPreferences"
        const val KEY_PAIRED = "flutter.ble_paired_devices"
        const val KEY_LOG_PREFIX = "flutter.ble_log_"

        // Max log entries per device (mirrors Dart LogStorage._hardMax)
        const val MAX_LOG_ENTRIES = 1000

        // Rescan interval when no device found (ms)
        private const val RESCAN_INTERVAL_MS = 30_000L
    }

    private lateinit var prefs: SharedPreferences
    private var bleScanner: BluetoothLeScanner? = null
    private val connectedDevices = mutableSetOf<String>()
    private val connectingDevices = mutableSetOf<String>()
    private val gattMap = mutableMapOf<String, BluetoothGatt>()
    private val handler = Handler(Looper.getMainLooper())
    private var isScanning = false

    // ── Lifecycle ────────────────────────────────────────────────────────────

    override fun onCreate() {
        super.onCreate()
        prefs = getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification("BLE Monitor active — scanning for your devices"))
        Log.i(TAG, "Service created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.i(TAG, "onStartCommand")
        startBleScan()
        return START_STICKY   // OS restarts this service if killed
    }

    override fun onDestroy() {
        stopBleScan()
        gattMap.values.forEach { it.close() }
        gattMap.clear()
        super.onDestroy()
        Log.i(TAG, "Service destroyed — will be restarted by OS (START_STICKY)")
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ── BLE Scanning ─────────────────────────────────────────────────────────

    private fun startBleScan() {
        val btManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val adapter = btManager.adapter
        if (adapter == null || !adapter.isEnabled) {
            Log.w(TAG, "Bluetooth not available — retry in ${RESCAN_INTERVAL_MS}ms")
            scheduleRescan()
            return
        }

        bleScanner = adapter.bluetoothLeScanner
        if (bleScanner == null) {
            Log.w(TAG, "BLE scanner unavailable — retry")
            scheduleRescan()
            return
        }

        val pairedIds = loadPairedIds()
        if (pairedIds.isEmpty()) {
            Log.i(TAG, "No paired devices stored — stopping scan")
            stopSelf()
            return
        }

        Log.i(TAG, "Starting BLE scan for ${pairedIds.size} paired device(s): $pairedIds")

        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_POWER)
            .build()

        // No MAC-address filters here because Android 10+ randomises addresses;
        // we filter by matching address in the callback instead.
        bleScanner?.startScan(emptyList<ScanFilter>(), settings, scanCallback)
        isScanning = true
        updateNotification("Scanning for ${pairedIds.size} paired device(s)…")
    }

    private fun stopBleScan() {
        if (isScanning) {
            bleScanner?.stopScan(scanCallback)
            isScanning = false
        }
    }

    private fun scheduleRescan() {
        handler.postDelayed({
            if (!isScanning) startBleScan()
        }, RESCAN_INTERVAL_MS)
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device
            val address = device.address
            val pairedIds = loadPairedIds()

            if (pairedIds.contains(address) &&
                !connectedDevices.contains(address) &&
                !connectingDevices.contains(address)) {

                Log.i(TAG, "Paired device in range: $address — connecting…")
                connectingDevices.add(address)
                writeLog(address, device.name, "incoming", "scan",
                    "Device in range (RSSI ${result.rssi} dBm) — initiating auto-connect")
                connectToDevice(device)
            }
        }

        override fun onScanFailed(errorCode: Int) {
            Log.e(TAG, "Scan failed: $errorCode")
            writeLog("unknown", null, "system", "error", "BLE scan failed: $errorCode")
            scheduleRescan()
        }
    }

    // ── GATT Connection ──────────────────────────────────────────────────────

    private fun connectToDevice(device: BluetoothDevice) {
        val gatt = device.connectGatt(
            this,
            /* autoConnect= */ true,  // OS handles reconnect across range drops
            gattCallback,
            BluetoothDevice.TRANSPORT_LE
        )
        gattMap[device.address] = gatt
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            val address = gatt.device.address
            val name = gatt.device.name

            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    Log.i(TAG, "Connected to $address")
                    connectedDevices.add(address)
                    connectingDevices.remove(address)
                    writeLog(address, name, "incoming", "connect",
                        "Auto-connected (background service)")
                    updateNotification("Connected: ${name ?: address}")
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    Log.i(TAG, "Disconnected from $address (status=$status)")
                    connectedDevices.remove(address)
                    connectingDevices.remove(address)
                    writeLog(address, name, "system", "disconnect",
                        "Disconnected (status=$status) — waiting for device to return")
                    updateNotification("Waiting for devices…")
                    // Cleanup gatt; autoConnect=true on next scan result will reconnect
                    gatt.close()
                    gattMap.remove(address)
                }
            }
        }
    }

    // ── SharedPreferences helpers ────────────────────────────────────────────

    private fun loadPairedIds(): Set<String> {
        val raw = prefs.getStringSet(KEY_PAIRED, null)
        if (raw != null) return raw
        // Flutter stores StringList as comma-separated under "flutter.<key>"
        // shared_preferences plugin stores StringList as a JSON array string
        val listJson = prefs.getString(KEY_PAIRED, null) ?: return emptySet()
        return try {
            // Handles both Set<String> and list serialization formats
            listJson.removeSurrounding("[\"", "\"]").split("\",\"").toSet()
        } catch (e: Exception) { emptySet() }
    }

    /**
     * Appends a log entry to SharedPreferences in the same JSON format
     * used by the Dart [LogStorage] class so the Flutter UI can read it.
     *
     * LogType index mapping (mirrors Dart LogType enum):
     *   0=scan 1=connect 2=disconnect 3=pair 4=unpair 5=read 6=write
     *   7=notify 8=indicate 9=serviceDiscovery 10=error 11=info
     *
     * LogDirection index:
     *   0=outgoing 1=incoming 2=system
     */
    private fun writeLog(
        deviceId: String,
        deviceName: String?,
        direction: String,   // "incoming" | "outgoing" | "system"
        type: String,        // "scan" | "connect" | "disconnect" | "error" | "info"
        message: String,
    ) {
        val dirIndex = when (direction) {
            "outgoing" -> 0; "incoming" -> 1; else -> 2
        }
        val typeIndex = when (type) {
            "scan" -> 0; "connect" -> 1; "disconnect" -> 2
            "pair" -> 3; "unpair" -> 4; "read" -> 5; "write" -> 6
            "notify" -> 7; "indicate" -> 8; "serviceDiscovery" -> 9
            "error" -> 10; else -> 11
        }
        val id = System.currentTimeMillis().toString()
        val ts = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            Instant.now().toEpochMilli() else System.currentTimeMillis()

        val entry = JSONObject().apply {
            put("id", id)
            put("ts", ts)
            put("dId", deviceId)
            put("dName", deviceName ?: JSONObject.NULL)
            put("dir", dirIndex)
            put("type", typeIndex)
            put("msg", "[BG] $message")
            put("hex", JSONObject.NULL)
            put("ascii", JSONObject.NULL)
        }

        val key = "flutter.$KEY_LOG_PREFIX$deviceId"
        try {
            val existing: MutableList<String> = (prefs.getStringSet(key, null)
                ?.toMutableList() ?: mutableListOf())
            existing.add(entry.toString())
            // Prune if over limit
            val pruned = if (existing.size > MAX_LOG_ENTRIES)
                existing.takeLast(MAX_LOG_ENTRIES) else existing
            // Write as StringSet (shared_preferences StringList format)
            prefs.edit().putStringSet(key, pruned.toSet()).apply()
        } catch (e: Exception) {
            Log.e(TAG, "writeLog failed: ${e.message}")
        }
    }

    // ── Notification ─────────────────────────────────────────────────────────

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "BLE Auto-Connect Monitor",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Keeps your paired BLE devices connected in the background"
            setShowBadge(false)
        }
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(channel)
    }

    private fun buildNotification(text: String): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pi = PendingIntent.getActivity(
            this, 0, launchIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("BLE Monitor")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .setContentIntent(pi)
            .build()
    }

    private fun updateNotification(text: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, buildNotification(text))
    }
}
