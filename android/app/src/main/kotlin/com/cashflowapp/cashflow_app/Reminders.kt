package com.cashflowapp.cashflow_app

import android.Manifest
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject

/**
 * Bill reminders (A7). lib/bills.dart always sends the complete list; it replaces the previous
 * alarms, is kept in SharedPreferences, and is scheduled again after a reboot or an app update.
 * Inexact alarms (setAndAllowWhileIdle) need no exact-alarm permission; a few minutes late is fine.
 */
object Reminders {
    private const val PREFS = "bill_reminders"
    private const val CHANNEL = "bill_reminders"

    fun schedule(context: Context, reminders: JSONArray) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        JSONArray(prefs.getString("list", "[]")).forEachObject { r ->
            existing(context, r.getInt("id"))?.let { context.getSystemService(AlarmManager::class.java).cancel(it) }
        }
        prefs.edit().putString("list", reminders.toString()).apply()
        restore(context)
    }

    fun restore(context: Context) {
        val alarms = context.getSystemService(AlarmManager::class.java)
        val now = System.currentTimeMillis()
        JSONArray(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("list", "[]")).forEachObject { r ->
            val at = r.getLong("at")
            if (at > now) {
                val intent = Intent(context, ReminderReceiver::class.java)
                    .putExtra("id", r.getInt("id"))
                    .putExtra("title", r.getString("title"))
                    .putExtra("text", r.getString("text"))
                val pending = PendingIntent.getBroadcast(
                    context, r.getInt("id"), intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
            }
        }
    }

    fun show(context: Context, id: Int, title: String, text: String) {
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return
        val manager = context.getSystemService(NotificationManager::class.java)
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "Pengingat tagihan", NotificationManager.IMPORTANCE_DEFAULT),
            )
            Notification.Builder(context, CHANNEL)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(context)
        }
        val open = PendingIntent.getActivity(
            context, 0, context.packageManager.getLaunchIntentForPackage(context.packageName),
            PendingIntent.FLAG_IMMUTABLE,
        )
        manager.notify(
            "bill", id,
            builder.setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(title)
                .setContentText(text)
                .setContentIntent(open)
                .setAutoCancel(true)
                .build(),
        )
    }

    private fun existing(context: Context, id: Int): PendingIntent? = PendingIntent.getBroadcast(
        context, id, Intent(context, ReminderReceiver::class.java),
        PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE,
    )

    private inline fun JSONArray.forEachObject(action: (JSONObject) -> Unit) {
        for (i in 0 until length()) action(getJSONObject(i))
    }
}

class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> Reminders.restore(context)
            else -> Reminders.show(
                context,
                intent.getIntExtra("id", 0),
                intent.getStringExtra("title").orEmpty(),
                intent.getStringExtra("text").orEmpty(),
            )
        }
    }
}
