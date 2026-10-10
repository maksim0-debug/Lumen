package ua.maksim0.lumen.widgets;

import android.appwidget.AppWidgetManager;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Handler;
import android.os.Looper;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.json.JSONArray;
import org.json.JSONObject;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/** Shared writer across all Flutter engines; disk commits run off the main thread. */
public final class WidgetSnapshotPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
    private static final ExecutorService WRITER = Executors.newSingleThreadExecutor();
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private MethodChannel channel;
    private Context context;

    @Override public void onAttachedToEngine(FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), "lumen/schedule_widgets");
        channel.setMethodCallHandler(this);
    }

    @Override public void onDetachedFromEngine(FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
        context = null;
    }

    @Override public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        if (!call.method.equals("applySnapshot")) { result.notImplemented(); return; }
        final Context application = context;
        final Object argument = call.arguments;
        if (application == null || !(argument instanceof String)) {
            result.error("invalid_snapshot", "Missing widget snapshot", null);
            return;
        }
        WRITER.execute(() -> {
            try {
                apply(application, (String) argument);
                MAIN.post(() -> result.success(null));
            } catch (Exception error) {
                // Do not send raw JSON or exception messages back to logs.
                MAIN.post(() -> result.error("widget_update_failed", error.getClass().getSimpleName(), null));
            }
        });
    }

    private static void apply(Context context, String raw) throws Exception {
        if (raw.length() > 8192) throw new IllegalArgumentException();
        final JSONObject snapshot = new JSONObject(raw);
        final String today = snapshot.getString("todayDate");
        final String tomorrow = snapshot.getString("tomorrowDate");
        final long version = snapshot.getLong("sourceVersion");
        final JSONObject groups = snapshot.getJSONObject("groups");
        if (!today.matches("[0-9]{4}-[0-9]{2}-[0-9]{2}") ||
            !tomorrow.matches("[0-9]{4}-[0-9]{2}-[0-9]{2}") || version < 0 || groups.length() > 12) {
            throw new IllegalArgumentException();
        }
        final SharedPreferences prefs = context.getSharedPreferences("HomeWidgetPreferences", Context.MODE_PRIVATE);
        final String previous = prefs.getString("schedule_snapshot", null);
        long watermark = version;
        if (previous != null) {
            final JSONObject old = new JSONObject(previous);
            final long oldWatermark = old.optLong("sourceWatermark", old.getLong("sourceVersion"));
            if (today.compareTo(old.getString("todayDate")) < 0 ||
                (today.equals(old.getString("todayDate")) && version > 0 &&
                 oldWatermark > version)) return;
            if (today.equals(old.getString("todayDate"))) watermark = Math.max(watermark, oldWatermark);
        }
        snapshot.put("sourceWatermark", watermark);
        final SharedPreferences.Editor editor = prefs.edit();
        for (int i = 0; i < 12; i++) {
            final String group = "GPV" + (i / 2 + 1) + "." + (i % 2 + 1);
            if (!groups.has(group)) continue;
            final JSONArray pair = groups.getJSONArray(group);
            if (pair.length() != 2 || !pair.getString(0).matches("[0-49]{24}") ||
                !pair.getString(1).matches("[0-49]{24}")) throw new IllegalArgumentException();
            editor.putString("schedule_" + group, pair.getString(0));
            editor.putString("schedule_tomorrow_" + group, pair.getString(1));
            editor.putBoolean("is_loading_" + (i + 1), false);
        }
        editor.putString("schedule_snapshot", snapshot.toString());
        final String update = snapshot.getString("sourceUpdatedAt");
        editor.putString("last_update_time", update.substring(update.lastIndexOf(' ') + 1));
        editor.putString("last_update_date", today);
        if (!editor.commit()) throw new IllegalStateException("Widget commit failed");
        final AppWidgetManager manager = AppWidgetManager.getInstance(context);
        for (int i = 1; i <= 12; i++) {
            final ComponentName provider = new ComponentName(context.getPackageName(),
                "ua.maksim0.lumen.LightScheduleWidgetProvider" + (i == 1 ? "" : i));
            final int[] ids = manager.getAppWidgetIds(provider);
            if (ids.length == 0) continue;
            final Intent intent = new Intent(AppWidgetManager.ACTION_APPWIDGET_UPDATE).setComponent(provider);
            intent.putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids);
            context.sendBroadcast(intent);
        }
    }
}
