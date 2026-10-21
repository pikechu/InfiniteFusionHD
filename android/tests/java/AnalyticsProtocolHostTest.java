package org.kuray.kif;

import java.net.URLDecoder;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;

/** Host-only contract checks; no collector or real user data is required. */
public final class AnalyticsProtocolHostTest {
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
    public static void main(String[] args) throws Exception {
        check(AnalyticsProtocol.validHttpsEndpoint("https://stats.example.test/matomo.php"), "HTTPS endpoint");
        check(AnalyticsProtocol.validHttpsEndpoint("https://stats.example.test:9443/matomo.php"), "custom HTTPS port");
        for (String endpoint : new String[]{"http://stats.test/matomo.php", "file:///tmp/a", "https:///a", "https://user:password@stats.test/a", "https://stats.test/a?token_auth=secret", "https://stats.test/a#secret", "https://stats.test:0/a", "https://stats.test:65536/a", ""})
            check(!AnalyticsProtocol.validHttpsEndpoint(endpoint), "Reject endpoint " + endpoint);
        check(AnalyticsProtocol.validVisitorId("a0123456789bcdef"), "16 hex visitor");
        check(!AnalyticsProtocol.validVisitorId("ANDROID-ID-123456"), "No device ID");
        Map<String, Integer> dimensions = new HashMap<>();
        dimensions.put("platform", 1); dimensions.put("app_version", 2); dimensions.put("device_model", 3);
        dimensions.put("manufacturer", 4); dimensions.put("channel", 5); dimensions.put("player_name", 6);
        check(AnalyticsProtocol.validConfigValues(1, "direct", 300, dimensions), "strict config accepts integer mapping");
        check(!AnalyticsProtocol.validConfigValues("1", "direct", 300, dimensions), "string site rejected");
        check(!AnalyticsProtocol.validConfigValues(1.0, "direct", 300, dimensions), "floating site rejected");
        check(!AnalyticsProtocol.validConfigValues(1, "direct", "300", dimensions), "string interval rejected");
        check(!AnalyticsProtocol.validConfigValues(1, "bad\nchannel", 300, dimensions), "control channel rejected");
        check(!AnalyticsProtocol.validConfigValues(1, String.join("", java.util.Collections.nCopies(34, "中")), 300, dimensions), "channel byte bound");
        Map<String, Object> invalidMapping = new HashMap<String, Object>(dimensions);
        invalidMapping.put("channel", 1);
        check(!AnalyticsProtocol.validConfigValues(1, "direct", 300, invalidMapping), "duplicate dimension rejected");
        invalidMapping.put("channel", "5");
        check(!AnalyticsProtocol.validConfigValues(1, "direct", 300, invalidMapping), "string dimension rejected");
        invalidMapping.put("channel", 1000);
        check(!AnalyticsProtocol.validConfigValues(1, "direct", 300, invalidMapping), "out of range dimension rejected");
        invalidMapping.remove("channel");
        check(!AnalyticsProtocol.validConfigValues(1, "direct", 300, invalidMapping), "missing dimension rejected");
        invalidMapping.put("channel", 0);
        check(AnalyticsProtocol.validConfigValues(1L, "direct", 300L, invalidMapping), "long integers and disabled dimension accepted");
        Map<String, String> values = new HashMap<>();
        values.put("platform", "android"); values.put("app_version", "0.20.7"); values.put("device_model", "Pixel + 测试");
        values.put("manufacturer", "Google"); values.put("channel", "direct"); values.put("player_name", "PRIVATE");
        String body = AnalyticsProtocol.event(2, "https://kif.invalid/game/", "a0123456789bcdef", "app_start", dimensions, values);
        Map<String, String> fields = new LinkedHashMap<>();
        for (String entry : body.split("&")) {
            String[] pair = entry.split("=", 2);
            fields.put(URLDecoder.decode(pair[0], "UTF-8"), URLDecoder.decode(pair[1], "UTF-8"));
        }
        check("2".equals(fields.get("idsite")), "game Matomo site");
        check("0".equals(fields.get("cookie")), "cookies disabled");
        check("0".equals(fields.get("send_image")), "no response image");
        check("1".equals(fields.get("ca")), "custom action retained");
        check("https://kif.invalid/game/android".equals(fields.get("url")), "synthetic page URL");
        check("Pixel + 测试".equals(fields.get("dimension3")), "UTF-8 form encoding");
        check(!body.contains("PRIVATE") && !fields.containsKey("dimension6"), "dimension allowlist");
        check(!body.contains("token_auth") && !fields.containsKey("uid") && !fields.containsKey("cip"), "no secrets, user names, explicit IP");
        String active = AnalyticsProtocol.event(2, "https://kif.invalid/game", "a0123456789bcdef", "active", dimensions, values);
        check(active.contains("e_a=active") && active.contains("_id=a0123456789bcdef"), "daily heartbeats retain random install identity");
        dimensions.put("device_model", 0);
        check(!AnalyticsProtocol.event(2, "https://kif.invalid/game", "a0123456789bcdef", "active", dimensions, values).contains("dimension0"), "disabled dimension omitted");
        boolean rejected = false;
        try { AnalyticsProtocol.event(0, "https://kif.invalid/game", "bad", "download", dimensions, values); }
        catch (IllegalArgumentException expected) { rejected = true; }
        check(rejected, "invalid events fail closed");
        System.out.println("PASS: Android analytics HTTPS validation, Matomo event encoding, identifier and data allowlist");
    }
}
