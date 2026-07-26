package com.zarz.spotiflac

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews

/**
 * Home-screen widget showing the active download. Updated only on discrete
 * events (track transition, status change, coarse progress steps) from
 * DownloadService — never per progress byte — to respect battery discipline.
 * The last pushed state is persisted so launcher-driven refreshes (reboot,
 * resize) render without the service running.
 */
class DownloadQueueWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        render(context, appWidgetManager, appWidgetIds)
    }

    companion object {
        private const val PREFS = "download_widget_state"
        private const val KEY_RUNNING = "running"
        private const val KEY_TITLE = "title"
        private const val KEY_SUBTITLE = "subtitle"
        private const val KEY_PERCENT = "percent" // -1 = indeterminate

        /** Persists the state and re-renders all widget instances. */
        fun push(
            context: Context,
            running: Boolean,
            title: String = "",
            subtitle: String = "",
            percent: Int = -1,
        ) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(
                ComponentName(context, DownloadQueueWidgetProvider::class.java)
            )
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(KEY_RUNNING, running)
                .putString(KEY_TITLE, title)
                .putString(KEY_SUBTITLE, subtitle)
                .putInt(KEY_PERCENT, percent)
                .apply()
            if (ids.isEmpty()) return
            render(context, manager, ids)
        }

        private fun render(
            context: Context,
            manager: AppWidgetManager,
            ids: IntArray,
        ) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val running = prefs.getBoolean(KEY_RUNNING, false)
            val views = RemoteViews(context.packageName, R.layout.widget_download_queue)

            if (running) {
                views.setTextViewText(
                    R.id.widget_title,
                    prefs.getString(KEY_TITLE, "").orEmpty().ifEmpty { "Downloading..." }
                )
                views.setTextViewText(
                    R.id.widget_subtitle,
                    prefs.getString(KEY_SUBTITLE, "").orEmpty()
                )
                views.setViewVisibility(R.id.widget_progress, View.VISIBLE)
                val percent = prefs.getInt(KEY_PERCENT, -1)
                if (percent in 0..100) {
                    views.setProgressBar(R.id.widget_progress, 100, percent, false)
                } else {
                    views.setProgressBar(R.id.widget_progress, 100, 0, true)
                }
            } else {
                views.setTextViewText(R.id.widget_title, "SpotiFLAC")
                views.setTextViewText(R.id.widget_subtitle, "No active downloads")
                views.setViewVisibility(R.id.widget_progress, View.GONE)
            }

            val launchIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            views.setOnClickPendingIntent(
                R.id.widget_root,
                PendingIntent.getActivity(
                    context,
                    0,
                    launchIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
            )

            for (id in ids) {
                manager.updateAppWidget(id, views)
            }
        }
    }
}
