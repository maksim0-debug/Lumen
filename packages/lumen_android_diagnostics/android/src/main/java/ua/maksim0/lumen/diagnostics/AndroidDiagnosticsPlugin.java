package ua.maksim0.lumen.diagnostics;

import android.app.Activity;
import android.app.ActivityManager;
import android.app.Application;
import android.app.ApplicationExitInfo;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.usage.UsageStatsManager;
import android.content.Context;
import android.content.pm.PackageInfo;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.os.Process;
import android.os.SystemClock;
import android.webkit.WebView;

import androidx.work.WorkInfo;
import androidx.work.WorkManager;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/** Read-only observations. Registration also runs in FCM/Workmanager engines. */
public final class AndroidDiagnosticsPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
    private static final Visibility visibility = new Visibility();
    private static final NetworkObserver networks = new NetworkObserver();
    private static Map<String, Object> metadata;
    private MethodChannel channel;
    private Context context;
    private ExecutorService executor;
    private final Handler main = new Handler(Looper.getMainLooper());
    private volatile boolean attached;

    @Override public void onAttachedToEngine(FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        visibility.install((Application) context);
        networks.attach(context);
        executor = Executors.newSingleThreadExecutor();
        channel = new MethodChannel(binding.getBinaryMessenger(), "ua.maksim0.lumen/android_diagnostics");
        channel.setMethodCallHandler(this);
        attached = true;
    }

    @Override public void onDetachedFromEngine(FlutterPluginBinding binding) {
        attached = false;
        channel.setMethodCallHandler(null);
        executor.shutdownNow();
        networks.detach();
        context = null;
    }

    @Override public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        if (!call.method.equals("snapshot") && !call.method.equals("networkState")) {
            result.notImplemented(); return;
        }
        final boolean networkOnly = call.method.equals("networkState");
        final Context app = context;
        final boolean includeHistory = Boolean.TRUE.equals(call.argument("includeHistory"));
        executor.execute(() -> {
            Map<String, Object> state;
            try { state = networkOnly ? networks.read(app) : snapshot(app, includeHistory); }
            catch (RuntimeException error) {
                state = new HashMap<>();
                state.put("nativeError", error.getClass().getSimpleName());
            }
            final Map<String, Object> reply = state;
            main.post(() -> { if (attached) result.success(reply); });
        });
    }

    private static Map<String, Object> snapshot(Context app, boolean includeHistory) {
        Map<String, Object> state = new HashMap<>();
        state.put("sampledAtMs", System.currentTimeMillis());
        state.put("uptimeMs", SystemClock.elapsedRealtime());
        state.put("pid", Process.myPid());
        state.putAll(metadata(app));
        state.put("visibleActivities", visibility.count());
        try {
            PowerManager power = (PowerManager) app.getSystemService(Context.POWER_SERVICE);
            state.put("interactive", power.isInteractive());
            state.put("deviceIdle", power.isDeviceIdleMode());
            state.put("powerSave", power.isPowerSaveMode());
            state.put("ignoringBatteryOptimizations", power.isIgnoringBatteryOptimizations(app.getPackageName()));
        } catch (RuntimeException error) { state.put("powerError", error.getClass().getSimpleName()); }
        state.putAll(networks.read(app));
        try {
            NotificationManager notifications = (NotificationManager) app.getSystemService(Context.NOTIFICATION_SERVICE);
            state.put("notificationsEnabled", notifications.areNotificationsEnabled());
            if (Build.VERSION.SDK_INT >= 26) {
                List<String> blocked = new ArrayList<>();
                for (NotificationChannel notification : notifications.getNotificationChannels()) {
                    if (notification.getImportance() == NotificationManager.IMPORTANCE_NONE && blocked.size() < 24) {
                        blocked.add(notification.getId());
                    }
                }
                state.put("blockedNotificationChannels", blocked);
            }
        } catch (RuntimeException error) { state.put("notificationError", error.getClass().getSimpleName()); }
        try {
            ActivityManager manager = (ActivityManager) app.getSystemService(Context.ACTIVITY_SERVICE);
            ActivityManager.RunningAppProcessInfo process = new ActivityManager.RunningAppProcessInfo();
            ActivityManager.getMyMemoryState(process);
            state.put("processImportance", process.importance);
            ActivityManager.MemoryInfo memory = new ActivityManager.MemoryInfo();
            manager.getMemoryInfo(memory);
            state.put("lowMemory", memory.lowMemory);
            if (Build.VERSION.SDK_INT >= 28) {
                state.put("backgroundRestricted", manager.isBackgroundRestricted());
                UsageStatsManager usage = (UsageStatsManager) app.getSystemService(Context.USAGE_STATS_SERVICE);
                state.put("standbyBucket", usage.getAppStandbyBucket());
            }
            if (includeHistory && Build.VERSION.SDK_INT >= 30) {
                List<Map<String, Object>> exits = new ArrayList<>();
                for (ApplicationExitInfo exit : manager.getHistoricalProcessExitReasons(app.getPackageName(), 0, 3)) {
                    Map<String, Object> entry = new HashMap<>();
                    entry.put("pid", exit.getPid());
                    entry.put("atMs", exit.getTimestamp());
                    entry.put("reason", exit.getReason());
                    entry.put("status", exit.getStatus());
                    entry.put("importance", exit.getImportance());
                    exits.add(entry);
                }
                state.put("recentProcessExits", exits);
            }
        } catch (RuntimeException error) { state.put("processError", error.getClass().getSimpleName()); }
        if (includeHistory) {
            List<Map<String, Object>> work = new ArrayList<>();
            for (String name : new String[]{"periodic_update_task", "fcm_schedule_refresh"}) {
                if (work.size() >= 6) break;
                try {
                    List<WorkInfo> entries = new ArrayList<>(WorkManager.getInstance(app).getWorkInfosForUniqueWork(name).get(150, TimeUnit.MILLISECONDS));
                    // Completed FCM history must not hide the currently queued/running job.
                    entries.sort((left, right) -> Boolean.compare(left.getState().isFinished(), right.getState().isFinished()));
                    int count = 0;
                    for (WorkInfo info : entries) {
                        Map<String, Object> entry = new HashMap<>();
                        entry.put("name", name);
                        entry.put("id", info.getId().toString());
                        entry.put("state", info.getState().name());
                        entry.put("runAttemptCount", info.getRunAttemptCount());
                        entry.put("stopReason", info.getStopReason());
                        entry.put("nextScheduleAtMs", info.getNextScheduleTimeMillis());
                        work.add(entry);
                        if (++count >= 3) break;
                    }
                } catch (Exception error) {
                    Map<String, Object> entry = new HashMap<>();
                    entry.put("name", name);
                    entry.put("queryError", error.getClass().getSimpleName());
                    work.add(entry);
                    if (error instanceof InterruptedException) Thread.currentThread().interrupt();
                }
            }
            state.put("work", work);
        }
        return state;
    }

    private static synchronized Map<String, Object> metadata(Context app) {
        if (metadata != null) return metadata;
        Map<String, Object> state = new HashMap<>();
        state.put("sdk", Build.VERSION.SDK_INT);
        state.put("androidRelease", Build.VERSION.RELEASE);
        state.put("manufacturer", Build.MANUFACTURER);
        state.put("model", Build.MODEL);
        try {
            PackageInfo info = app.getPackageManager().getPackageInfo(app.getPackageName(), 0);
            state.put("appVersion", info.versionName);
            state.put("appBuild", Build.VERSION.SDK_INT >= 28 ? info.getLongVersionCode() : (long) info.versionCode);
            if (Build.VERSION.SDK_INT >= 26) {
                PackageInfo webview = WebView.getCurrentWebViewPackage();
                state.put("webViewVersion", webview == null ? null : webview.versionName);
            }
        } catch (Exception error) { state.put("versionError", error.getClass().getSimpleName()); }
        metadata = state;
        return metadata;
    }

    /** Events are retained in memory; no polling, probes, wake locks or Dart stream. */
    private static final class NetworkObserver extends ConnectivityManager.NetworkCallback {
        private ConnectivityManager manager;
        private int clients;
        private Network current;
        private Boolean blocked;
        private String registrationError;
        private final List<Map<String, Object>> events = new ArrayList<>();

        synchronized void attach(Context app) {
            if (++clients != 1) return;
            manager = (ConnectivityManager) app.getSystemService(Context.CONNECTIVITY_SERVICE);
            try { manager.registerDefaultNetworkCallback(this); }
            catch (RuntimeException error) { registrationError = error.getClass().getSimpleName(); }
        }
        synchronized void detach() {
            if (--clients != 0) return;
            if (manager != null && registrationError == null) {
                try { manager.unregisterNetworkCallback(this); }
                catch (RuntimeException error) { registrationError = error.getClass().getSimpleName(); }
            }
            manager = null;
            current = null;
            blocked = null;
            registrationError = null;
            events.clear();
        }
        private void event(String name, Boolean value) {
            Map<String, Object> entry = new HashMap<>();
            entry.put("event", name);
            entry.put("atMs", System.currentTimeMillis());
            if (value != null) entry.put("blocked", value);
            if (events.size() == 8) events.remove(0);
            events.add(entry);
        }
        @Override public synchronized void onAvailable(Network network) {
            current = network;
            blocked = null;
            event("available", null);
        }
        @Override public synchronized void onLost(Network network) {
            if (network.equals(current)) { current = null; blocked = null; }
            event("lost", null);
        }
        @Override public synchronized void onBlockedStatusChanged(Network network, boolean value) {
            if (network.equals(current)) blocked = value;
            event("blocked_status", value);
        }
        synchronized Map<String, Object> read(Context app) {
            Map<String, Object> state = new HashMap<>();
            state.put("networkEvents", new ArrayList<>(events));
            state.put("visibleActivities", visibility.count());
            try {
                PowerManager power = (PowerManager) app.getSystemService(Context.POWER_SERVICE);
                state.put("interactive", power.isInteractive());
                state.put("deviceIdle", power.isDeviceIdleMode());
            } catch (RuntimeException error) { state.put("powerError", error.getClass().getSimpleName()); }
            if (registrationError != null) state.put("networkObserverError", registrationError);
            try {
                // Synchronous reads are outside callbacks. Unknown capability != offline.
                ConnectivityManager connectivity = (ConnectivityManager) app.getSystemService(Context.CONNECTIVITY_SERVICE);
                Network network = connectivity.getActiveNetwork();
                NetworkCapabilities caps = network == null ? null : connectivity.getNetworkCapabilities(network);
                state.put("networkPresent", network != null);
                state.put("networkBlocked", network != null && network.equals(current) ? blocked : null);
                state.put("networkValidated", caps == null ? null : caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED));
                state.put("internetCapability", caps == null ? null : caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET));
                state.put("captivePortal", caps == null ? null : caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_CAPTIVE_PORTAL));
                state.put("metered", network == null ? null : connectivity.isActiveNetworkMetered());
                state.put("restrictBackgroundStatus", connectivity.getRestrictBackgroundStatus());
                List<String> transports = new ArrayList<>();
                if (caps != null) {
                    if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) transports.add("wifi");
                    if (caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) transports.add("cellular");
                    if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) transports.add("vpn");
                    if (caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) transports.add("ethernet");
                }
                state.put("transports", transports);
            } catch (RuntimeException error) { state.put("networkError", error.getClass().getSimpleName()); }
            return state;
        }
    }

    /** Process-wide counter; a headless engine must not claim to be a visible UI. */
    private static final class Visibility implements Application.ActivityLifecycleCallbacks {
        private boolean installed;
        private int started;
        synchronized void install(Application app) {
            if (!installed) { app.registerActivityLifecycleCallbacks(this); installed = true; }
        }
        synchronized int count() { return started; }
        @Override public synchronized void onActivityStarted(Activity activity) { started++; }
        @Override public synchronized void onActivityStopped(Activity activity) { started = Math.max(0, started - 1); }
        @Override public void onActivityCreated(Activity activity, Bundle state) {}
        @Override public void onActivityResumed(Activity activity) {}
        @Override public void onActivityPaused(Activity activity) {}
        @Override public void onActivitySaveInstanceState(Activity activity, Bundle state) {}
        @Override public void onActivityDestroyed(Activity activity) {}
    }
}
