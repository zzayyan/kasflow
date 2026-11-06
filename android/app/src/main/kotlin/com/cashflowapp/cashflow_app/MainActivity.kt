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
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import org.json.JSONArray
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterView
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

    // Flutter keeps the keyboard's height as a bottom inset when the app is left while the keyboard
    // is still animating in, so every screen stops short of the bottom (flutter/flutter#191156,
    // open at Flutter 3.47). Back in focus, once the keyboard is really gone, hand the window's
    // current insets to the FlutterView again. ponytail: drop this once Flutter fixes #191156.
    private val resyncClosedKeyboard = Runnable {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return@Runnable
        val insets = window.decorView.rootWindowInsets ?: return@Runnable
        if (insets.isVisible(WindowInsets.Type.ime())) return@Runnable
        flutterViewIn(window.decorView)?.onApplyWindowInsets(insets)
    }

    private fun flutterViewIn(view: View): FlutterView? {
        if (view is FlutterView) return view
        if (view !is ViewGroup) return null
        for (i in 0 until view.childCount) flutterViewIn(view.getChildAt(i))?.let { return it }
        return null
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus) return
        window.decorView.removeCallbacks(resyncClosedKeyboard)
        window.decorView.postDelayed(resyncClosedKeyboard, 300) // after the keyboard has settled
    }

    override fun onDestroy() {
        window.decorView.removeCallbacks(resyncClosedKeyboard)
        super.onDestroy()
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
