package ua.maksim0.lumen;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;
import android.content.Intent;
import android.os.Bundle;
import androidx.annotation.NonNull;
import ua.maksim0.lumen.widgets.WidgetSnapshotPlugin;

public class MainActivity extends FlutterActivity {
    public static final String ACTION_WIDGET_REFRESH = "ua.maksim0.lumen.WIDGET_REFRESH";
    private static final String PENDING_REFRESH = "lumen.widget_refresh_pending";
    private MethodChannel widgetRefreshChannel;
    private boolean widgetRefreshPending;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        widgetRefreshPending = ACTION_WIDGET_REFRESH.equals(getIntent().getAction()) ||
                (savedInstanceState != null && savedInstanceState.getBoolean(PENDING_REFRESH));
        super.onCreate(savedInstanceState);
        WidgetSnapshotPlugin.refreshWidgets(this);
    }

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        widgetRefreshChannel = new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(),
                "lumen/widget_refresh");
        widgetRefreshChannel.setMethodCallHandler((call, result) -> {
            if (!"consumePendingRefresh".equals(call.method)) {
                result.notImplemented();
                return;
            }
            final boolean pending = widgetRefreshPending;
            widgetRefreshPending = false;
            // A recreated activity must not replay an already consumed launch.
            if (ACTION_WIDGET_REFRESH.equals(getIntent().getAction())) {
                getIntent().setAction(Intent.ACTION_MAIN);
            }
            result.success(pending);
        });
    }

    @Override
    protected void onNewIntent(@NonNull Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        if (ACTION_WIDGET_REFRESH.equals(intent.getAction())) {
            widgetRefreshPending = true;
            if (widgetRefreshChannel != null) {
                widgetRefreshChannel.invokeMethod("refreshRequested", null);
            }
        }
    }

    @Override
    protected void onSaveInstanceState(@NonNull Bundle outState) {
        outState.putBoolean(PENDING_REFRESH, widgetRefreshPending);
        super.onSaveInstanceState(outState);
    }

    @Override
    public void cleanUpFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        if (widgetRefreshChannel != null) {
            widgetRefreshChannel.setMethodCallHandler(null);
            widgetRefreshChannel = null;
        }
        super.cleanUpFlutterEngine(flutterEngine);
    }
}
