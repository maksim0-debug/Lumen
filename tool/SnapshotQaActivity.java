package ua.maksim0.lumen;

import android.appwidget.AppWidgetHost;
import android.appwidget.AppWidgetHostView;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProviderInfo;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import android.os.Bundle;
import android.view.ViewGroup;
import android.widget.TextView;
import android.widget.RemoteViews;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;
import org.json.JSONObject;
import java.io.File;
import java.io.FileWriter;

/** QA-only widget host, using the actual production providers and RemoteViews. */
public class SnapshotQaActivity extends FlutterActivity {
    private AppWidgetHost host;
    private MethodChannel channel;
    private final JSONObject renders = new JSONObject();
    @Override public void configureFlutterEngine(FlutterEngine engine) {
        super.configureFlutterEngine(engine);
        channel = new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), "lumen/snapshot_qa");
        channel.setMethodCallHandler((call, result) -> {
                if (!call.method.equals("bindWidgets")) { result.notImplemented(); return; }
                try {
                    host = new AppWidgetHost(this, 8241) {
                        @Override protected AppWidgetHostView onCreateView(Context context, int id,
                                AppWidgetProviderInfo info) {
                            return new AppWidgetHostView(context) {
                                @Override public void updateAppWidget(RemoteViews views) {
                                    super.updateAppWidget(views);
                                    if (views == null) return;
                                    try {
                                        JSONObject entry = new JSONObject();
                                        entry.put("renderedAt", System.currentTimeMillis());
                                        entry.put("updateLabel", ((TextView) findViewById(R.id.widget_update_time)).getText());
                                        StringBuilder code = new StringBuilder();
                                        ViewGroup grid = findViewById(R.id.widget_grid);
                                        for (int row = 0; row < grid.getChildCount(); row++) {
                                            ViewGroup cells = (ViewGroup) grid.getChildAt(row);
                                            for (int cell = 0; cell < cells.getChildCount(); cell++) {
                                                android.view.View frame = cells.getChildAt(cell);
                                                int left = ((ColorDrawable) frame.findViewById(R.id.cell_left).getBackground()).getColor();
                                                int right = ((ColorDrawable) frame.findViewById(R.id.cell_right).getBackground()).getColor();
                                                int on = Color.parseColor("#66BB6A"), off = Color.parseColor("#EF5350");
                                                code.append(left == on && right == on ? '0' : left == off && right == off ? '1'
                                                    : left == off && right == on ? '2' : left == on && right == off ? '3'
                                                    : left == Color.parseColor("#BDBDBD") ? '4' : '9');
                                            }
                                        }
                                        entry.put("renderedCode", code.toString());
                                        renders.put(info.provider.getClassName(), entry);
                                        try (FileWriter writer = new FileWriter(new File(getFilesDir(),
                                                "snapshot_qa_widget_renders.json"))) {
                                            writer.write(renders.toString());
                                        }
                                    } catch (Exception error) {
                                        android.util.Log.e("SnapshotQA", "Cannot record widget rendering", error);
                                    }
                                }
                            };
                        }
                    };
                    host.deleteHost();
                    final AppWidgetManager manager = AppWidgetManager.getInstance(this);
                    for (int index : new int[] {3, 12}) {
                        final ComponentName provider = new ComponentName(getPackageName(),
                            "ua.maksim0.lumen.LightScheduleWidgetProvider" + index);
                        final int id = host.allocateAppWidgetId();
                        Bundle dimensions = new Bundle();
                        dimensions.putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 300);
                        dimensions.putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 160);
                        if (!manager.bindAppWidgetIdIfAllowed(id, provider, dimensions)) {
                            throw new IllegalStateException("Grant QA widget binding using adb first");
                        }
                        host.createView(this, id, manager.getAppWidgetInfo(id));
                    }
                    host.startListening();
                    result.success(null);
                } catch (Exception error) {
                    result.error("qa_widget_bind", error.getMessage(), null);
                }
            });
    }
    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        final String command = intent.getStringExtra("qa_command");
        if (command != null && channel != null) channel.invokeMethod("qaCommand", command);
    }
    @Override protected void onDestroy() {
        if (host != null) host.stopListening();
        super.onDestroy();
    }
}
