package com.cashflowapp.cashflow_app

import android.Manifest
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import org.json.JSONArray
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cashflow/notifications")
            .setMethodCallHandler { call, result ->
                when (call.method) {
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
                    else -> result.notImplemented()
                }
            }
    }
}
