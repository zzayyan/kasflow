package com.cashflowapp.cashflow_app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import org.json.JSONObject
import java.text.DecimalFormat
import java.text.DecimalFormatSymbols
import java.util.Locale
import java.util.TimeZone

/**
 * Home screen widget: Beranda's "Jatah hari ini" with a + that opens Catat cepat. lib/home_widget.dart
 * sends the budget's figures whenever they change; the arithmetic is redone here at each update so
 * the figure turns over at midnight while the app stays closed. Spending is only recorded inside
 * the app, so figures from an earlier day are still exact: that day's spending simply moves into
 * "before today". Same rules as todayAllowance in lib/reports.dart.
 */
class AllowanceWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val views = render(context)
        ids.forEach { manager.updateAppWidget(it, views) }
    }

    companion object {
        const val QUICK_INPUT = "com.cashflowapp.cashflow_app.QUICK_INPUT"
        private const val PREFS = "allowance_widget"

        fun save(context: Context, data: Map<*, *>) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString("data", JSONObject(data).toString()).apply()
            refresh(context)
        }

        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, AllowanceWidget::class.java))
            if (ids.isNotEmpty()) manager.updateAppWidget(ids, render(context))
        }

        private fun today(): Long {
            val now = System.currentTimeMillis()
            return (now + TimeZone.getDefault().getOffset(now)) / 86_400_000L
        }

        private val digits = DecimalFormat("#,##0", DecimalFormatSymbols(Locale("in", "ID")))
        private val decimals = DecimalFormat("#,##0.##", DecimalFormatSymbols(Locale("in", "ID")))

        // Amounts are cents, as everywhere in the app. "Rp 85.000"; compact "Rp 25 rb", "Rp 1,25 jt".
        private fun money(cents: Long) = "Rp " + digits.format(cents / 100)
        private fun short(cents: Long): String {
            val rp = cents / 100.0
            return when {
                rp >= 1e9 -> "Rp " + decimals.format(rp / 1e9) + " M"
                rp >= 1e6 -> "Rp " + decimals.format(rp / 1e6) + " jt"
                rp >= 1e3 -> "Rp " + decimals.format(rp / 1e3) + " rb"
                else -> "Rp " + digits.format(rp)
            }
        }

        private fun render(context: Context): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.allowance_widget)
            val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("data", null)
            val d = raw?.let { JSONObject(it) }

            var title = "Jatah hari ini"
            var detail = ""
            var amount = ""
            var over = false
            val day = today()
            when {
                d == null -> detail = "Buka Cashflow sekali untuk memuat jatah"
                !d.has("name") -> {
                    title = "Atur budget untuk melihat jatah harian"
                    detail = "Buka Rencana di Cashflow"
                }
                day >= d.getLong("endDay") -> detail = "${d.getString("name")} · periode baru, buka Cashflow"
                else -> {
                    val name = d.getString("name")
                    val limit = d.getLong("limit")
                    var before = d.getLong("spentBefore")
                    var spentToday = d.getLong("spentToday")
                    if (day != d.getLong("day")) { before += spentToday; spentToday = 0 }
                    val days = d.getLong("endDay") - day
                    val remaining = limit - before
                    if (remaining <= 0) {
                        over = true
                        title = "Budget $name habis"
                        detail = if (before + spentToday > limit) "Terlewat ${money(before + spentToday - limit)}"
                            else "Tidak ada sisa sampai periode berikutnya"
                    } else {
                        val perDay = remaining / days
                        val left = perDay - spentToday
                        over = left < 0
                        amount = if (over) "−" + money(-left) else money(left)
                        if (over) title = "Jatah hari ini terlewat"
                        detail = when {
                            over -> "$name · jatah ${short(perDay)}, terpakai ${short(spentToday)}"
                            spentToday == 0L -> "$name · sisa ${short(remaining)}, $days hari lagi"
                            else -> "$name · terpakai ${short(spentToday)} dari ${short(perDay)}"
                        }
                    }
                }
            }

            views.setTextViewText(R.id.title, title)
            views.setTextViewText(R.id.detail, detail)
            views.setTextViewText(R.id.amount, amount)
            views.setViewVisibility(R.id.amount, if (amount.isEmpty()) android.view.View.GONE else android.view.View.VISIBLE)
            views.setInt(R.id.card, "setBackgroundResource", if (over) R.drawable.widget_card_alert else R.drawable.widget_card)
            views.setInt(R.id.add, "setBackgroundResource", if (over) R.drawable.widget_add_alert else R.drawable.widget_add)
            views.setInt(R.id.add, "setColorFilter", context.getColor(if (over) R.color.widget_on_alert else R.color.widget_hero))
            views.setTextColor(R.id.title, context.getColor(if (over) R.color.widget_alert else R.color.widget_on_hero_chip))
            views.setTextColor(R.id.amount, context.getColor(if (over) R.color.widget_alert else R.color.widget_on_hero))
            views.setTextColor(R.id.detail, context.getColor(if (over) R.color.widget_alert else R.color.widget_on_hero_muted))

            fun open(request: Int, action: String?) = PendingIntent.getActivity(
                context, request,
                Intent(context, MainActivity::class.java).setAction(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            views.setOnClickPendingIntent(R.id.card, open(0, Intent.ACTION_MAIN))
            views.setOnClickPendingIntent(R.id.add, open(1, QUICK_INPUT))
            return views
        }
    }
}
