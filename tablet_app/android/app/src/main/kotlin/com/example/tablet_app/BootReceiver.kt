package com.example.tablet_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Optional: starts the app when device boots.
 * User can disable auto-start for this app in system settings on many devices.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        try {
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?: return
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(launch)
        } catch (e: Exception) {
            Log.e(TAG, "Boot start failed", e)
        }
    }

    companion object {
        private const val TAG = "BootReceiver"
    }
}
