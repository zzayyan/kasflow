package com.cashflowapp.cashflow_app

import android.Manifest
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import org.json.JSONArray
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    // Started from the widget's + or the "Catat cepat" shortcut; lib/home_widget.dart takes it once.
    private var quickInput = false

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        quickInput = intent?.action == AllowanceWidget.QUICK_INPUT
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action == AllowanceWidget.QUICK_INPUT) channel?.invokeMethod("quickInput", null)
    }

    // The app's own tap feedback (lib/ui.dart haptic). View.performHapticFeedback obeys the system
    // touch-vibration switch, which many people turn off for the keyboard; a vibration of usage
    // UNKNOWN does not, so Cashflow's own toggle in Pengaturan decides instead.
    private fun haptic(kind: String) {
        val vibrator = if (Build.VERSION.SDK_INT >= 31) {
            (getSystemService(VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(VIBRATOR_SERVICE) as Vibrator
        }
        if (!vibrator.hasVibrator()) return
        if (Build.VERSION.SDK_INT >= 29) {
            val effect = when (kind) {
                "click" -> VibrationEffect.EFFECT_CLICK
                "heavy" -> VibrationEffect.EFFECT_HEAVY_CLICK
                else -> VibrationEffect.EFFECT_TICK
            }
            vibrator.vibrate(VibrationEffect.createPredefined(effect))
        } else {
            val ms = when (kind) { "click" -> 20L; "heavy" -> 35L; else -> 10L }
            vibrator.vibrate(VibrationEffect.createOneShot(ms, VibrationEffect.DEFAULT_AMPLITUDE))
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cashflow/notifications")
        channel!!
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "updateWidget" -> {
                        AllowanceWidget.save(this, call.arguments as Map<*, *>)
                        result.success(null)
                    }
                    "takeQuickInput" -> {
                        result.success(quickInput)
                        quickInput = false
                    }
                    "isEnabled" -> {
                        val me = ComponentName(this, TransactionNotificationListener::class.java).flattenToString()
                        val enabled = Settings.Secure.getString(contentResolver, "enabled_notification_listeners")
                        result.success(enabled?.split(':')?.contains(me) == true)
                    }
                    "openSettings" -> {
                        startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                        result.success(null)
                    }
                    "scheduleReminders" -> {
                        Reminders.schedule(this, JSONArray(call.arguments as List<*>))
                        result.success(null)
                    }
                    "requestPostNotifications" -> {
                        if (Build.VERSION.SDK_INT >= 33 &&
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                        ) {
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
                        }
                        result.success(null)
                    }
                    "haptic" -> {
                        haptic(call.arguments as String)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
