package com.example.vikl

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetPlugin
import java.util.Calendar

abstract class BaseLightScheduleWidgetProvider : AppWidgetProvider() {

    abstract val groupName: String

    companion object {
        private const val ACTION_REFRESH = "ACTION_REFRESH"
        private const val ACTION_MIDNIGHT_UPDATE = "ACTION_MIDNIGHT_UPDATE"
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        scheduleMidnightUpdate(context)
        for (appWidgetId in appWidgetIds) {
            updateAppWidget(context, appWidgetManager, appWidgetId)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        
        if (intent.action == ACTION_REFRESH) {
            val widgetId = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
            if (widgetId != AppWidgetManager.INVALID_APPWIDGET_ID) {
                // 1. Set loading state
                val widgetData = HomeWidgetPlugin.getData(context)
                
                val groupIndexMap = mapOf(
                    "GPV1.1" to 1, "GPV1.2" to 2,
                    "GPV2.1" to 3, "GPV2.2" to 4,
                    "GPV3.1" to 5, "GPV3.2" to 6,
                    "GPV4.1" to 7, "GPV4.2" to 8,
                    "GPV5.1" to 9, "GPV5.2" to 10,
                    "GPV6.1" to 11, "GPV6.2" to 12
                )
                val index = groupIndexMap[groupName] ?: 1
                
                widgetData.edit().putBoolean("is_loading_$index", true).apply()
                
                // 2. Update widget to show spinner
                val appWidgetManager = AppWidgetManager.getInstance(context)
                updateAppWidget(context, appWidgetManager, widgetId)

                // 3. Trigger background refresh in Dart
                val backgroundIntent = Intent(context, es.antonborri.home_widget.HomeWidgetBackgroundReceiver::class.java)
                backgroundIntent.action = "es.antonborri.home_widget.action.BACKGROUND"
                backgroundIntent.data = Uri.parse("homeWidget://refresh")
                context.sendBroadcast(backgroundIntent)
            }
        } else if (intent.action == ACTION_MIDNIGHT_UPDATE) {
             val appWidgetManager = AppWidgetManager.getInstance(context)
             val ids = appWidgetManager.getAppWidgetIds(android.content.ComponentName(context, this::class.java))
             for (id in ids) {
                 updateAppWidget(context, appWidgetManager, id)
             }
             // Reschedule for next day
             scheduleMidnightUpdate(context)
        }
    }

    private fun scheduleMidnightUpdate(context: Context) {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val intent = Intent(context, this::class.java).apply { action = ACTION_MIDNIGHT_UPDATE }
        val pendingIntent = PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        val calendar = Calendar.getInstance().apply {
            timeInMillis = System.currentTimeMillis()
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 1) // 00:01 to be safe
            set(Calendar.SECOND, 0)
            add(Calendar.DAY_OF_YEAR, 1)
        }

        try {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
                if (alarmManager.canScheduleExactAlarms()) {
                    alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, calendar.timeInMillis, pendingIntent)
                } else {
                    alarmManager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, calendar.timeInMillis, pendingIntent)
                }
            } else {
                alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, calendar.timeInMillis, pendingIntent)
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun updateAppWidget(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int
    ) {
        try {
            val widgetData = HomeWidgetPlugin.getData(context)
            
            val groupIndexMap = mapOf(
                "GPV1.1" to 1, "GPV1.2" to 2,
                "GPV2.1" to 3, "GPV2.2" to 4,
                "GPV3.1" to 5, "GPV3.2" to 6,
                "GPV4.1" to 7, "GPV4.2" to 8,
                "GPV5.1" to 9, "GPV5.2" to 10,
                "GPV6.1" to 11, "GPV6.2" to 12
            )
            val index = groupIndexMap[groupName] ?: 1
            val isLoading = widgetData.getBoolean("is_loading_$index", false)

            val selectedGroup = groupName
            var scheduleKey = "schedule_$selectedGroup"
            
            // Date Check
            val lastUpdateDateStr = widgetData.getString("last_update_date", "")
            val calendar = Calendar.getInstance()
            val todayStr = "${calendar.get(Calendar.YEAR)}-${calendar.get(Calendar.MONTH) + 1}-${calendar.get(Calendar.DAY_OF_MONTH)}"
            
            if (lastUpdateDateStr != todayStr && lastUpdateDateStr != "") {
                // It's a new day! Try to use tomorrow's schedule
                val tomorrowKey = "schedule_tomorrow_$selectedGroup"
                val tomorrowSchedule = widgetData.getString(tomorrowKey, "")
                if (!tomorrowSchedule.isNullOrEmpty()) {
                    scheduleKey = tomorrowKey
                }
            }

            val scheduleString = widgetData.getString(scheduleKey, "") ?: ""
            val lastUpdate = widgetData.getString("last_update_time", "--:--")

            val views = RemoteViews(context.packageName, R.layout.widget_schedule)

            val displayGroup = selectedGroup.replace("GPV", "")
            views.setTextViewText(R.id.widget_group_name, "Група $displayGroup")
            views.setTextViewText(R.id.widget_update_time, lastUpdate)

            // Loading State
            if (isLoading) {
                views.setViewVisibility(R.id.widget_refresh_button, View.GONE)
                views.setViewVisibility(R.id.widget_loading_bar, View.VISIBLE)
            } else {
                views.setViewVisibility(R.id.widget_refresh_button, View.VISIBLE)
                views.setViewVisibility(R.id.widget_loading_bar, View.GONE)
            }

            // Refresh Click
            val refreshIntent = Intent(context, this::class.java).apply {
                action = ACTION_REFRESH
                putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
                data = Uri.parse("customScheme://widget/id/$appWidgetId")
            }
            val refreshPendingIntent = PendingIntent.getBroadcast(
                context,
                appWidgetId,
                refreshIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_refresh_button, refreshPendingIntent)


            views.removeAllViews(R.id.widget_grid)

            if (scheduleString.isNotEmpty() && scheduleString.length >= 24) {
                var charIndex = 0
                for (row in 0 until 4) {
                    val rowView = RemoteViews(context.packageName, R.layout.widget_row)
                    
                    for (col in 0 until 6) {
                        if (charIndex >= 24) break
                        val charCode = scheduleString[charIndex]
                        val hour = charIndex
                        charIndex++

                        val cell = RemoteViews(context.packageName, R.layout.widget_cell)
                        cell.setTextViewText(R.id.cell_text, "$hour")

                        val colorOn = Color.parseColor("#66BB6A")   // Green
                        val colorOff = Color.parseColor("#EF5350")  // Red
                        val colorMaybe = Color.parseColor("#BDBDBD") // Grey
                        
                        var leftColor = Color.GRAY
                        var rightColor = Color.GRAY

                        when (charCode) {
                            '0' -> { leftColor = colorOn; rightColor = colorOn }
                            '1' -> { leftColor = colorOff; rightColor = colorOff }
                            '2' -> { leftColor = colorOff; rightColor = colorOn } // SemiOn (Off -> On)
                            '3' -> { leftColor = colorOn; rightColor = colorOff } // SemiOff (On -> Off)
                            '4' -> { leftColor = colorMaybe; rightColor = colorMaybe }
                            '9' -> { leftColor = Color.GRAY; rightColor = Color.GRAY }
                        }

                        cell.setInt(R.id.cell_left, "setBackgroundColor", leftColor)
                        cell.setInt(R.id.cell_right, "setBackgroundColor", rightColor)

                        rowView.addView(R.id.row_container, cell)
                    }
                    views.addView(R.id.widget_grid, rowView)
                }
            } else {
                views.setTextViewText(R.id.widget_group_name, "Гр. $displayGroup (Немає даних)")
            }

            // Open App Intent
            val launchIntent = Intent(context, MainActivity::class.java)
            launchIntent.action = Intent.ACTION_MAIN
            launchIntent.addCategory(Intent.CATEGORY_LAUNCHER)
            launchIntent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            
            val pendingIntent = PendingIntent.getActivity(
                context,
                appWidgetId,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            
            views.setOnClickPendingIntent(R.id.widget_root, pendingIntent)
            views.setOnClickPendingIntent(R.id.widget_group_name, pendingIntent)
            views.setOnClickPendingIntent(R.id.widget_grid, pendingIntent)

            appWidgetManager.updateAppWidget(appWidgetId, views)
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
}

class LightScheduleWidgetProvider : BaseLightScheduleWidgetProvider() { override val groupName = "GPV1.1" }
class LightScheduleWidgetProvider2 : BaseLightScheduleWidgetProvider() { override val groupName = "GPV1.2" }
class LightScheduleWidgetProvider3 : BaseLightScheduleWidgetProvider() { override val groupName = "GPV2.1" }
class LightScheduleWidgetProvider4 : BaseLightScheduleWidgetProvider() { override val groupName = "GPV2.2" }
class LightScheduleWidgetProvider5 : BaseLightScheduleWidgetProvider() { override val groupName = "GPV3.1" }
class LightScheduleWidgetProvider6 : BaseLightScheduleWidgetProvider() { override val groupName = "GPV3.2" }
class LightScheduleWidgetProvider7 : BaseLightScheduleWidgetProvider() { override val groupName = "GPV4.1" }
class LightScheduleWidgetProvider8 : BaseLightScheduleWidgetProvider() { override val groupName = "GPV4.2" }
class LightScheduleWidgetProvider9 : BaseLightScheduleWidgetProvider() { override val groupName = "GPV5.1" }
class LightScheduleWidgetProvider10 : BaseLightScheduleWidgetProvider() { override val groupName = "GPV5.2" }
class LightScheduleWidgetProvider11 : BaseLightScheduleWidgetProvider() { override val groupName = "GPV6.1" }
class LightScheduleWidgetProvider12 : BaseLightScheduleWidgetProvider() { override val groupName = "GPV6.2" }