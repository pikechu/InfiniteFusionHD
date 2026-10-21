package org.kuray.kif;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import javax.net.ssl.HttpsURLConnection;
import org.json.JSONObject;

/** Optional, best-effort foreground statistics. Never reads saves or stable device identifiers. */
public final class Analytics {
    private static Analytics instance;
    private final Context context;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final ThreadPoolExecutor worker = new ThreadPoolExecutor(1, 1, 30, TimeUnit.SECONDS,
        new ArrayBlockingQueue<Runnable>(1), task -> {
            Thread thread = new Thread(task, "KIF-Analytics"); thread.setDaemon(true); return thread;
        }, new ThreadPoolExecutor.DiscardPolicy());
    private final Object gate = new Object();
    private final Map<String, Integer> dimensions = new HashMap<>();
    private final Map<String, String> values = new HashMap<>();
    private boolean configured;
    private String endpoint;
    private String appUrl;
    private int site;
    private long heartbeatMillis = 300000L;
    private boolean foreground;
    private boolean started;
    private long generation;
    private final Runnable heartbeat = new Runnable() {
        @Override public void run() {
            try {
                if (!foreground || !usageEnabled()) return;
                enqueue("active"); handler.postDelayed(this, heartbeatMillis);
            } catch (Exception ignored) { /* Telemetry must never interrupt the game. */ }
        }
    };

    private Analytics(Context source) {
        context = source.getApplicationContext();
        worker.allowCoreThreadTimeOut(true);
        try (InputStream in = context.getAssets().open("analytics.json")) {
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            byte[] buffer = new byte[1024];
            for (int count; (count = in.read(buffer)) >= 0;) {
                if (bytes.size() + count > 8192) return;
                bytes.write(buffer, 0, count);
            }
            JSONObject json = new JSONObject(new String(bytes.toByteArray(), StandardCharsets.UTF_8));
            if (!Boolean.TRUE.equals(json.opt("enabled"))) return;
            JSONObject mapping = json.optJSONObject("dimensions");
            Map<String, Object> rawDimensions = new HashMap<>();
            String[] keys = {"platform", "app_version", "device_model", "manufacturer", "channel"};
            if (mapping != null) for (String key : keys) rawDimensions.put(key, mapping.opt(key));
            if (!AnalyticsProtocol.validConfigValues(json.opt("site_id"), json.opt("channel"),
                json.opt("heartbeat_seconds"), rawDimensions)) return;
            endpoint = json.optString("endpoint", "");
            appUrl = json.optString("app_url", "");
            site = json.optInt("site_id", 0);
            heartbeatMillis = Math.max(60, Math.min(3600, json.optLong("heartbeat_seconds", 300))) * 1000L;
            configured = AnalyticsProtocol.validHttpsEndpoint(endpoint) && AnalyticsProtocol.validHttpsEndpoint(appUrl);
            for (String key : keys) dimensions.put(key, mapping.optInt(key, 0));
            values.put("platform", "android");
            values.put("app_version", context.getPackageManager().getPackageInfo(context.getPackageName(), 0).versionName);
            values.put("device_model", Build.MODEL); values.put("manufacturer", Build.MANUFACTURER);
            values.put("channel", json.optString("channel", "direct"));
        } catch (Exception ignored) { configured = false; }
    }

    private static synchronized Analytics get(Context context) {
        if (instance == null) instance = new Analytics(context);
        return instance;
    }

    // The launcher and SDL live in different processes. Re-open preferences to refresh their cache.
    @SuppressWarnings("deprecation") private SharedPreferences preferences() {
        return context.getSharedPreferences("kif-analytics", Context.MODE_MULTI_PROCESS);
    }
    private boolean usageEnabled() { return configured && preferences().getBoolean("usage_enabled", true); }
    public static boolean isConfigured(Context context) {
        try { return get(context).configured; } catch (Exception ignored) { return false; }
    }
    public static boolean isUsageEnabled(Context context) {
        try { return get(context).usageEnabled(); } catch (Exception ignored) { return false; }
    }
    public static void setUsageEnabled(Context context, boolean enabled) {
        try {
            Analytics analytics = get(context);
            synchronized (analytics.gate) {
                SharedPreferences.Editor editor = analytics.preferences().edit().putBoolean("usage_enabled", enabled);
                if (!enabled) editor.remove("visitor_id");
                editor.commit();
                if (!enabled) analytics.stopLocked();
            }
        } catch (Exception ignored) { /* A settings failure must not affect save management. */ }
    }

    /** Called only after the actual game activity successfully resumes; installers and probes do not call it. */
    public static void onGameResume(Context context) {
        try {
            Analytics analytics = get(context);
            synchronized (analytics.gate) {
                if (!analytics.usageEnabled() || analytics.foreground) return;
                analytics.foreground = true;
                analytics.enqueue(analytics.started ? "active" : "app_start");
                analytics.started = true;
                analytics.handler.postDelayed(analytics.heartbeat, analytics.heartbeatMillis);
            }
        } catch (Exception ignored) { /* Optional analytics cannot prevent gameplay. */ }
    }
    public static void onGamePause() {
        try {
            Analytics analytics = instance;
            if (analytics != null) synchronized (analytics.gate) { analytics.stopLocked(); }
        } catch (Exception ignored) { }
    }
    private void stopLocked() {
        foreground = false; generation++;
        handler.removeCallbacks(heartbeat); worker.getQueue().clear();
        // A request already in flight may finish within its short timeout. Never disconnect
        // network streams here: Android can block in disconnect(), and this runs on the UI thread.
    }
    private void enqueue(String action) {
        final long expected = generation;
        worker.execute(() -> send(action, expected));
    }
    private boolean eligible(long expected) {
        return generation == expected && foreground && usageEnabled();
    }
    private void send(String action, long expected) {
        HttpsURLConnection request = null;
        try {
            String visitor;
            synchronized (gate) {
                if (!eligible(expected)) return;
                SharedPreferences prefs = preferences();
                visitor = prefs.getString("visitor_id", "");
                if (!AnalyticsProtocol.validVisitorId(visitor)) {
                    byte[] random = new byte[8]; new SecureRandom().nextBytes(random);
                    StringBuilder hex = new StringBuilder(16);
                    for (byte value : random) hex.append(String.format(java.util.Locale.ROOT, "%02x", value & 0xff));
                    visitor = hex.toString();
                    // Failed persistence would inflate unique players, so skip this event instead.
                    if (!prefs.edit().putString("visitor_id", visitor).commit()) return;
                }
            }
            byte[] body = AnalyticsProtocol.event(site, appUrl, visitor, action, dimensions, values).getBytes(StandardCharsets.UTF_8);
            request = (HttpsURLConnection)new URL(endpoint).openConnection();
            request.setInstanceFollowRedirects(false);
            request.setConnectTimeout(2000); request.setReadTimeout(2000);
            request.setUseCaches(false); request.setRequestMethod("POST"); request.setDoOutput(true);
            request.setFixedLengthStreamingMode(body.length);
            request.setRequestProperty("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8");
            request.setRequestProperty("User-Agent", "KIF-Analytics/1");
            // Keep the platform's certificate and hostname verification intact. No auth token is shipped.
            synchronized (gate) { if (!eligible(expected)) return; }
            try (OutputStream out = request.getOutputStream()) { out.write(body); }
            request.getResponseCode(); // No retry, redirect, response download, or durable offline queue.
        } catch (Exception ignored) { /* Offline, invalid TLS, server errors, and malformed config are non-fatal. */ }
        finally {
            if (request != null) request.disconnect();
        }
    }
}
