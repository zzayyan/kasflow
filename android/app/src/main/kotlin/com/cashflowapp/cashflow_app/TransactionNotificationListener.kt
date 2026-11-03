package com.cashflowapp.cashflow_app

import android.app.Notification
import android.content.pm.ApplicationInfo
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONObject
import java.io.File

/**
 * Runs even while the app is closed. Appends notifications from finance apps to
 * filesDir/notification_inbox.jsonl; lib/notifications.dart imports and clears that file.
 * Only allowlisted packages are written, so chats and other notifications never touch disk.
 */
class TransactionNotificationListener : NotificationListenerService() {
    override fun onNotificationPosted(sbn: StatusBarNotification) {
        // Debug builds also accept `adb shell cmd notification post ...` (package com.android.shell) for testing.
        val debuggable = applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
        if (sbn.packageName !in FINANCE_PACKAGES && !(debuggable && sbn.packageName == "com.android.shell")) return
        val n = sbn.notification
        if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        val extras = n.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
            ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString().orEmpty()
        if (text.isBlank()) return
        val line = JSONObject()
            .put("ref", "${sbn.packageName}|${sbn.key}|${sbn.postTime}")
            .put("package", sbn.packageName)
            .put("title", title)
            .put("text", text)
            .put("posted_at", sbn.postTime)
            .toString()
        synchronized(LOCK) { File(filesDir, INBOX_FILE).appendText(line + "\n") }
    }

    companion object {
        const val INBOX_FILE = "notification_inbox.jsonl"
        private val LOCK = Any()

        // Keep in sync with providerByPackage in lib/notifications.dart.
        // Package names verified on a real device with `adb shell pm list packages`.
        val FINANCE_PACKAGES = setOf(
            "com.gojek.app", "com.gojek.gopay",
            "id.dana",
            "ovo.id",
            "com.shopee.id", "com.shopeepay.id",
            "id.co.bri.brimo",
            "id.bmri.livin",
            "com.jago.digitalBanking",
            "id.co.bankbkemobile.digitalbank",
        )
    }
}
