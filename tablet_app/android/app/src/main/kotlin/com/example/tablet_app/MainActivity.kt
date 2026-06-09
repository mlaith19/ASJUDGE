package com.example.tablet_app

import android.Manifest
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.View
import android.view.WindowManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

    private val channelName = "com.example.tablet_app/kiosk"
    private val deviceInfoChannelName = "com.example.tablet_app/device_info"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, deviceInfoChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "getBatteryLevel" -> {
                    try {
                        val level = getBatteryLevelPercent()
                        result.success(level?.toDouble())
                    } catch (e: Exception) {
                        result.success(null)
                    }
                }
                "getBatteryCharging" -> {
                    try {
                        result.success(isBatteryCharging())
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "getBatteryTemperature" -> {
                    try {
                        val temp = getBatteryTemperatureCelsius()
                        result.success(if (temp != null) temp.toDouble() else null)
                    } catch (e: Exception) {
                        result.success(null)
                    }
                }
                "getCpuUsage" -> {
                    Executors.newSingleThreadExecutor().execute {
                        val map = computeCpuUsageMap()
                        runOnUiThread { result.success(map) }
                    }
                }
                "getWifiSsid" -> {
                    try {
                        result.success(getWifiSsidMap())
                    } catch (e: Exception) {
                        result.success(
                            mapOf(
                                "ssid" to null,
                                "reason" to "exception:${e.message}"
                            )
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "setImmersiveMode" -> {
                    val enable = call.arguments == true
                    runOnUiThread {
                        if (enable) setImmersiveMode() else leaveImmersive()
                    }
                    result.success(null)
                }
                "startLockTask" -> {
                    runOnUiThread {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                            try {
                                this@MainActivity.startLockTask()
                                result.success(null)
                            } catch (e: Exception) {
                                result.error("LOCK_TASK", e.message, null)
                            }
                        } else {
                            result.success(null)
                        }
                    }
                }
                "stopLockTask" -> {
                    runOnUiThread {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                            try {
                                this@MainActivity.stopLockTask()
                                result.success(null)
                            } catch (e: Exception) {
                                result.error("LOCK_TASK", e.message, null)
                            }
                        } else {
                            result.success(null)
                        }
                    }
                }
                "isLockTaskMode" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                        result.success(am.lockTaskModeState == ActivityManager.LOCK_TASK_MODE_PINNED)
                    } else {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setImmersiveMode()
    }

    private fun setImmersiveMode() {
        window.decorView.systemUiVisibility = (
            View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
            or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
            or View.SYSTEM_UI_FLAG_FULLSCREEN
            or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
        )
    }

    private fun leaveImmersive() {
        window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_VISIBLE
    }

    /** Battery level 0-100 (from BatteryManager). Fallback when battery_plus returns null. */
    private fun getBatteryLevelPercent(): Int? {
        val intent = applicationContext.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) ?: return null
        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        if (level < 0 || scale <= 0) return null
        return (level * 100 / scale).coerceIn(0, 100)
    }

    /** Whether battery is charging or full (from BatteryManager). */
    private fun isBatteryCharging(): Boolean {
        val intent = applicationContext.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) ?: return false
        val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        return status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
    }

    /** Battery temperature in Celsius (from BatteryManager). */
    private fun getBatteryTemperatureCelsius(): Float? {
        val intent = applicationContext.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) ?: return null
        val tempTenths = intent.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE)
        if (tempTenths == Int.MIN_VALUE) return null
        return tempTenths / 10f
    }

    private fun getWifiSsidMap(): Map<String, Any?> {
        val out = HashMap<String, Any?>()
        if (!packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI)) {
            out["ssid"] = null
            out["reason"] = "no_wifi_feature"
            return out
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
                out["ssid"] = null
                out["reason"] = "ACCESS_FINE_LOCATION_not_granted_runtime"
                return out
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val lm = applicationContext.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
            if (lm != null && !lm.isLocationEnabled) {
                out["ssid"] = null
                out["reason"] = "location_services_disabled_gps_off"
                return out
            }
        }
        val wm = applicationContext.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        if (wm == null) {
            out["ssid"] = null
            out["reason"] = "WifiManager_null"
            return out
        }
        val info = try {
            wm.connectionInfo
        } catch (e: SecurityException) {
            out["ssid"] = null
            out["reason"] = "SecurityException:${e.message}"
            return out
        }
        if (info == null) {
            out["ssid"] = null
            out["reason"] = "connectionInfo_null"
            return out
        }
        out["rssi"] = info.rssi
        val raw = info.ssid
        if (raw == null) {
            out["ssid"] = null
            out["reason"] = "ssid_field_null"
            return out
        }
        if (raw == "<unknown ssid>" || raw == "0x") {
            out["ssid"] = null
            out["reason"] = "unknown_ssid_os_masks_ssid_even_with_location_on_some_oems"
            return out
        }
        val ssid = raw.trim('"').trim()
        if (ssid.isEmpty()) {
            out["ssid"] = null
            out["reason"] = "ssid_empty_after_trim"
            return out
        }
        out["ssid"] = ssid
        out["reason"] = "ok_wifi_manager"
        return out
    }

    /** CPU: global /proc/stat; fallback /proc/self process jiffies. */
    private fun computeCpuUsageMap(): Map<String, Any?> {
        val out = HashMap<String, Any?>()
        try {
            val g1 = readProcStatCpu()
            Thread.sleep(360)
            val g2 = readProcStatCpu()
            if (g1 != null && g2 != null) {
                val td = g2.first - g1.first
                val idl = g2.second - g1.second
                if (td > 0) {
                    val pct = ((td - idl) * 100L / td).toInt().coerceIn(0, 100)
                    out["pct"] = pct.toDouble()
                    out["source"] = "proc_stat_global"
                    out["reason"] = "ok"
                    Log.i("TabletCPU", "cpu=$pct source=proc_stat_global")
                    return out
                }
                out["reason"] = "proc_stat_zero_delta"
            } else {
                out["reason"] = "proc_stat_unreadable_or_wrong_format"
            }
            val j1 = readSelfCpuJiffies()
            Thread.sleep(360)
            val j2 = readSelfCpuJiffies()
            if (j1 != null && j2 != null) {
                val dj = j2 - j1
                if (dj >= 0) {
                    val hz = 100L
                    val wall = 0.36
                    val pct = (dj.toDouble() / hz / wall * 100.0).toInt().coerceIn(0, 100)
                    out["pct"] = pct.toDouble()
                    out["source"] = "proc_self_app_process"
                    out["reason"] = "ok_fallback_app_cpu_share"
                    Log.i("TabletCPU", "cpu=$pct source=proc_self_app_process")
                    return out
                }
            }
            out["pct"] = null
            out["source"] = "failed"
            out["reason"] = out["reason"].toString() + "|proc_self_failed"
            Log.w("TabletCPU", "cpu failed ${out["reason"]}")
        } catch (e: Exception) {
            out["pct"] = null
            out["source"] = "exception"
            out["reason"] = e.message ?: "exception"
            Log.e("TabletCPU", "cpu exception", e)
        }
        return out
    }

    private fun readSelfCpuJiffies(): Long? {
        return try {
            val line = File("/proc/self/stat").readText()
            val rparen = line.indexOf(')')
            if (rparen < 0) return null
            val fields = line.substring(rparen + 2).trim().split(Regex("\\s+"))
            if (fields.size < 13) return null
            val ut = fields[11].toLongOrNull() ?: return null
            val st = fields[12].toLongOrNull() ?: return null
            ut + st
        } catch (_: Exception) {
            null
        }
    }

    private fun readProcStatCpu(): Pair<Long, Long>? {
        return try {
            RandomAccessFile("/proc/stat", "r").use { raf ->
                val line = raf.readLine() ?: return null
                if (!line.startsWith("cpu ")) return null
                val parts = line.split(Regex("\\s+"))
                if (parts.size < 5) return null
                val user = parts[1].toLongOrNull() ?: 0L
                val nice = parts[2].toLongOrNull() ?: 0L
                val system = parts[3].toLongOrNull() ?: 0L
                val idle = parts[4].toLongOrNull() ?: 0L
                val total = user + nice + system + idle
                Pair(total, idle)
            }
        } catch (_: Exception) {
            null
        }
    }
}
