package com.example.bluetooth

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * BootReceiver — starts [BleBackgroundService] automatically after:
 *   • Device boot / reboot  (ACTION_BOOT_COMPLETED)
 *   • App update / reinstall (MY_PACKAGE_REPLACED)
 *
 * Requires: RECEIVE_BOOT_COMPLETED permission in AndroidManifest.xml
 */
class BootReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "BleBootReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) return

        Log.i(TAG, "Boot/update detected — starting BleBackgroundService")

        val serviceIntent = Intent(context, BleBackgroundService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(serviceIntent)
        } else {
            context.startService(serviceIntent)
        }
    }
}
