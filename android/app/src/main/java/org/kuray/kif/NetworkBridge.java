package org.kuray.kif;

import android.content.Context;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Base64;
import org.json.JSONObject;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLException;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

/** Uses Android's maintained TLS provider, certificate store and default hostname verifier. */
public final class NetworkBridge {
    private static final int MAX_BODY = 8 * 1024 * 1024;
    private static final int MAX_REQUEST = 65536;
    private static final ExecutorService WORKERS = new ThreadPoolExecutor(0, 2, 30, TimeUnit.SECONDS,
        new SynchronousQueue<>(), runnable -> { Thread thread = new Thread(runnable, "KIF-HTTPS"); thread.setDaemon(true); return thread; },
        new ThreadPoolExecutor.AbortPolicy());
    private static final ExecutorService DISCONNECTORS = new ThreadPoolExecutor(0, 2, 30, TimeUnit.SECONDS,
        new ArrayBlockingQueue<>(2), runnable -> { Thread thread = new Thread(runnable, "KIF-HTTPS-Cancel"); thread.setDaemon(true); return thread; },
        new ThreadPoolExecutor.AbortPolicy());
    private static final AsyncHttpQueue ASYNC = new AsyncHttpQueue(SystemClock::elapsedRealtime, NetworkBridge::failure);
    private static final class Exchange {
        private final AtomicBoolean cancelled = new AtomicBoolean();
        private final AtomicReference<HttpsURLConnection> active = new AtomicReference<>();
        void check(long end) throws IOException {
            if (cancelled.get()) throw new InterruptedIOException("HTTP cancelled");
            deadline(end);
        }
        void publish(HttpsURLConnection connection, long end) throws IOException {
            active.set(connection);
            if (cancelled.get()) {
                active.compareAndSet(connection, null); connection.disconnect();
                throw new InterruptedIOException("HTTP cancelled");
            }
            check(end);
        }
        void clear(HttpsURLConnection connection) { active.compareAndSet(connection, null); }
        void cancel() {
            cancelled.set(true);
            HttpsURLConnection connection = active.getAndSet(null);
            if (connection != null) {
                try { DISCONNECTORS.execute(connection::disconnect); }
                catch (RejectedExecutionException occupied) { /* Worker read/connect deadline remains bounded. */ }
            }
        }
    }
    private NetworkBridge() { }
    public static native void configure();
    /** RGSS virtual buttons use a native queue independent of SDL's Android key callbacks. */
    public static native void setVirtualKey(int rgssCode, boolean down);
    public static native void clearVirtualKeys();
    /** Request a Ruby-thread text-mode restart independently of game buttons. */
    public static native void requestTextInput();
    /** Retained display preference; Ruby applies it on the game thread. */
    public static native void setDisplayStretch(boolean stretch);
    static boolean enabled(Context context) {
        try (InputStream in = context.getAssets().open("network-enabled")) { return in.read() == '1'; }
        catch (IOException unavailable) { return false; }
    }
    private static URL secureUrl(URL url) throws IOException {
        if (!"https".equalsIgnoreCase(url.getProtocol()) || url.getHost().isEmpty() || url.getUserInfo() != null)
            throw new ProtocolException("Only HTTPS URLs without credentials are supported");
        return url;
    }
    private static void deadline(long end) throws IOException {
        if (Thread.currentThread().isInterrupted() || SystemClock.elapsedRealtime() >= end) throw new SocketTimeoutException("HTTP total deadline");
    }
    private static boolean sameOrigin(URL a, URL b) {
        return a.getHost().equalsIgnoreCase(b.getHost()) && a.getPort() == b.getPort();
    }
    private static Map<String,String> headers(JSONObject input) throws Exception {
        Map<String,String> result = new LinkedHashMap<>();
        if (input == null) return result;
        if (input.length() > 64) throw new IOException("Too many request headers");
        for (Iterator<String> keys = input.keys(); keys.hasNext();) {
            String name = keys.next(), value = input.getString(name);
            if (!name.matches("[!#$%&'*+.^_`|~0-9A-Za-z-]+") || value.indexOf('\r') >= 0 || value.indexOf('\n') >= 0 || value.length() > 8192)
                throw new IOException("Invalid HTTP header");
            String folded = name.toLowerCase(Locale.ROOT);
            if (Arrays.asList("host", "content-length", "transfer-encoding", "connection", "proxy-connection", "proxy-authorization").contains(folded)) continue;
            result.put(name, value);
        }
        return result;
    }
    private static JSONObject execute(JSONObject request, long end, Exchange exchange) throws Exception {
        String method = request.optString("method", "GET");
        if (!method.equals("GET") && !method.equals("POST")) throw new ProtocolException("Unsupported HTTP method");
        URL url = secureUrl(new URL(request.getString("url")));
        Map<String,String> headers = headers(request.optJSONObject("headers"));
        byte[] body = request.has("body") ? Base64.decode(request.getString("body"), Base64.NO_WRAP) : new byte[0];
        if (body.length > MAX_REQUEST) throw new IOException("Request body limit");
        boolean follow = method.equals("GET") && request.optBoolean("follow_redirects", true);
        for (int redirects = 0; redirects <= 4; redirects++) {
            exchange.check(end);
            HttpsURLConnection connection = (HttpsURLConnection)url.openConnection();
            try {
                exchange.publish(connection, end);
                // Do not replace the default SSLSocketFactory, HostnameVerifier or TrustManager.
                int remaining = (int)Math.max(1, Math.min(Integer.MAX_VALUE, end - SystemClock.elapsedRealtime()));
                connection.setConnectTimeout(Math.min(5000, remaining));
                connection.setReadTimeout(Math.min(10000, remaining));
                connection.setInstanceFollowRedirects(false);
                connection.setUseCaches(false);
                connection.setRequestMethod(method);
                connection.setRequestProperty("Accept-Encoding", "identity");
                connection.setRequestProperty("User-Agent", "KIF-Android/0.20.7");
                for (Map.Entry<String,String> header : headers.entrySet()) connection.setRequestProperty(header.getKey(), header.getValue());
                if (method.equals("POST")) {
                    exchange.check(end);
                    connection.setDoOutput(true);
                    connection.setRequestProperty("Content-Type", request.optString("content_type", "application/octet-stream"));
                    connection.setFixedLengthStreamingMode(body.length);
                    try (OutputStream out = connection.getOutputStream()) { out.write(body); }
                }
                int status = connection.getResponseCode();
                exchange.check(end);
                boolean redirect = status == 301 || status == 302 || status == 303 || status == 307 || status == 308;
                if (redirect && follow) {
                    if (redirects == 4) throw new ProtocolException("HTTP redirect limit");
                    String location = connection.getHeaderField("Location");
                    if (location == null) throw new ProtocolException("Missing redirect location");
                    URL next = secureUrl(new URL(url, location));
                    if (!sameOrigin(url, next)) headers.entrySet().removeIf(entry -> entry.getKey().equalsIgnoreCase("Authorization") || entry.getKey().equalsIgnoreCase("Cookie"));
                    if (status == 303 || ((status == 301 || status == 302) && method.equals("POST"))) { method = "GET"; body = new byte[0]; }
                    url = next; continue;
                }
                if (connection.getContentLengthLong() > MAX_BODY) throw new IOException("Response body limit");
                JSONObject responseHeaders = new JSONObject();
                int headerBytes = 0, headerCount = 0;
                for (Map.Entry<String,List<String>> header : connection.getHeaderFields().entrySet()) {
                    if (header.getKey() == null) continue;
                    String value = String.join(", ", header.getValue());
                    headerBytes += header.getKey().length() + value.length();
                    if (++headerCount > 256 || headerBytes > 65536) throw new IOException("Response header limit");
                    responseHeaders.put(header.getKey(), value);
                }
                InputStream stream = status >= 400 ? connection.getErrorStream() : connection.getInputStream();
                ByteArrayOutputStream received = new ByteArrayOutputStream();
                if (stream != null) try (InputStream in = stream) {
                    byte[] buffer = new byte[65536]; int n;
                    while ((n = in.read(buffer)) != -1) {
                        exchange.check(end);
                        if (received.size() + n > MAX_BODY) throw new IOException("Response body limit");
                        received.write(buffer, 0, n);
                    }
                }
                return new JSONObject().put("status", status).put("headers", responseHeaders)
                    .put("body", Base64.encodeToString(received.toByteArray(), Base64.NO_WRAP));
            } finally { exchange.clear(connection); connection.disconnect(); }
        }
        throw new ProtocolException("HTTP redirect limit");
    }
    private static JSONObject executeWithRetries(JSONObject request, long end, Exchange exchange) throws Exception {
        for (int attempt = 0; ; attempt++) {
            try { return execute(request, end, exchange); }
            catch (SSLException | ProtocolException fatal) { throw fatal; }
            catch (IOException error) {
                if (attempt > 0 || !request.optString("method", "GET").equals("GET")) throw error;
                exchange.check(end);
                Thread.sleep(250);
            }
        }
    }
    private static byte[] failure(Exception error) {
        try {
            return new JSONObject().put("status", 0).put("headers", new JSONObject()).put("body", "")
                .put("error", error.getClass().getSimpleName()).toString().getBytes(StandardCharsets.UTF_8);
        } catch (Exception unavailable) {
            return "{\"status\":0,\"headers\":{},\"body\":\"\",\"error\":\"IOException\"}".getBytes(StandardCharsets.UTF_8);
        }
    }

    /** JNI only copies the bounded envelope here; all parsing, DNS and TLS runs in Java workers. */
    public static long startHttp(byte[] bytes, int timeoutMillis) {
        if (bytes == null || bytes.length > MAX_REQUEST) throw new IllegalArgumentException("Request limit");
        final byte[] request = Arrays.copyOf(bytes, bytes.length);
        final Exchange exchange = new Exchange();
        return ASYNC.start(new AsyncHttpQueue.Operation() {
            @Override public byte[] execute(long end) throws Exception {
                JSONObject parsed = new JSONObject(new String(request, StandardCharsets.UTF_8));
                return executeWithRetries(parsed, end, exchange).toString().getBytes(StandardCharsets.UTF_8);
            }
            @Override public void cancel() { exchange.cancel(); }
        }, timeoutMillis);
    }
    /** Null means pending. A completed response is consumed once and immediately released. */
    public static byte[] pollHttp(long id) {
        try { return ASYNC.poll(id); }
        catch (IllegalStateException expired) { return failure(expired); }
    }
    public static void cancelHttp(long id) { ASYNC.cancel(id); }
    public static void cancelPendingRequests() { ASYNC.cancelAll(); }

    public static byte[] performHttp(byte[] bytes) {
        JSONObject result = new JSONObject();
        Future<JSONObject> job = null;
        Exchange exchange = new Exchange();
        try {
            if (Looper.myLooper() == Looper.getMainLooper()) throw new IOException("HTTP must run off the UI thread");
            if (bytes.length > MAX_REQUEST) throw new IOException("Request limit");
            JSONObject request = new JSONObject(new String(bytes, StandardCharsets.UTF_8));
            long end = SystemClock.elapsedRealtime() + 20000;
            job = WORKERS.submit(() -> executeWithRetries(request, end, exchange));
            result = job.get(20, TimeUnit.SECONDS);
        } catch (Exception failure) {
            exchange.cancel();
            if (job != null) job.cancel(true);
            if (failure instanceof ExecutionException && failure.getCause() instanceof Exception) failure = (Exception)failure.getCause();
            // Do not expose request headers, tokens or URL queries in logs/errors.
            try { result = new JSONObject().put("status", 0).put("headers", new JSONObject()).put("body", "").put("error", failure.getClass().getSimpleName()); }
            catch (Exception ignored) { }
        }
        return result.toString().getBytes(StandardCharsets.UTF_8);
    }
}
