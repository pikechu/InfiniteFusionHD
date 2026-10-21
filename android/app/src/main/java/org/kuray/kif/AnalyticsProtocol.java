package org.kuray.kif;

import java.net.URI;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

/** The allowlisted Matomo payload, independent of Android for host verification. */
public final class AnalyticsProtocol {
    private AnalyticsProtocol() {}

    public static boolean validHttpsEndpoint(String value) {
        if (value == null || value.length() > 2048) return false;
        try {
            URI uri = new URI(value);
            return "https".equalsIgnoreCase(uri.getScheme()) && uri.getHost() != null
                && !uri.getHost().isEmpty() && uri.getRawUserInfo() == null
                && uri.getRawQuery() == null && uri.getRawFragment() == null
                && (uri.getPort() == -1 || (uri.getPort() > 0 && uri.getPort() <= 65535));
        } catch (Exception ignored) { return false; }
    }

    public static boolean validVisitorId(String value) {
        return value != null && value.matches("[0-9a-f]{16}");
    }

    private static boolean integer(Object value) {
        return value instanceof Integer || value instanceof Long || value instanceof Short || value instanceof Byte;
    }

    /** Match the desktop configuration contract without JSON's permissive string coercion. */
    public static boolean validConfigValues(Object site, Object channel, Object heartbeat, Map<String, ?> dimensions) {
        if (!integer(site) || ((Number)site).longValue() <= 0 || ((Number)site).longValue() > Integer.MAX_VALUE
            || !integer(heartbeat) || !(channel instanceof String) || dimensions == null) return false;
        String name = (String)channel;
        int length = name.getBytes(StandardCharsets.UTF_8).length;
        if (length < 1 || length > 100 || name.matches("(?s).*[\\x00-\\x1f\\x7f].*")) return false;
        Set<Long> used = new HashSet<>();
        for (String key : new String[]{"platform", "app_version", "device_model", "manufacturer", "channel"}) {
            Object value = dimensions.get(key);
            if (!integer(value)) return false;
            long dimension = ((Number)value).longValue();
            if (dimension < 0 || dimension > 999 || (dimension > 0 && !used.add(dimension))) return false;
        }
        return true;
    }

    public static String event(int site, String appUrl, String visitor, String action,
                               Map<String, Integer> dimensions, Map<String, String> values) {
        if (site <= 0 || !validHttpsEndpoint(appUrl) || !validVisitorId(visitor)
            || !("app_start".equals(action) || "active".equals(action))) {
            throw new IllegalArgumentException("Invalid analytics event");
        }
        Map<String, String> fields = new LinkedHashMap<>();
        fields.put("rec", "1"); fields.put("apiv", "1"); fields.put("idsite", Integer.toString(site));
        fields.put("_id", visitor); fields.put("cookie", "0"); fields.put("send_image", "0");
        fields.put("url", appUrl.replaceAll("/+$", "") + "/android");
        fields.put("e_c", "game"); fields.put("e_a", action); fields.put("ca", "1");
        String[] allowed = {"platform", "app_version", "device_model", "manufacturer", "channel"};
        for (String key : allowed) {
            Integer dimension = dimensions.get(key);
            String value = values.get(key);
            if (dimension != null && dimension > 0 && value != null && !value.isEmpty())
                fields.put("dimension" + dimension, value.substring(0, Math.min(200, value.length())));
        }
        StringBuilder result = new StringBuilder();
        try {
            for (Map.Entry<String, String> entry : fields.entrySet()) {
                if (result.length() > 0) result.append('&');
                result.append(URLEncoder.encode(entry.getKey(), "UTF-8")).append('=')
                    .append(URLEncoder.encode(entry.getValue(), "UTF-8"));
            }
        } catch (java.io.UnsupportedEncodingException impossible) { throw new AssertionError(impossible); }
        return result.toString();
    }
}
