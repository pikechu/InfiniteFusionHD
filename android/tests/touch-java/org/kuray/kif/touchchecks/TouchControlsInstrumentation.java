package org.kuray.kif.touchchecks;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Context;
import android.graphics.RectF;
import android.os.Build;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.InputDevice;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import java.lang.reflect.Proxy;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import org.json.JSONArray;
import org.json.JSONObject;

/** Runs the installed target view with real Android MotionEvents, without starting the game. */
public final class TouchControlsInstrumentation extends Instrumentation {
    private interface Check { void run() throws Exception; }
    private static final int C = KeyEvent.KEYCODE_C;
    private static final int X = KeyEvent.KEYCODE_X;
    private static final int U = KeyEvent.KEYCODE_DPAD_UP;
    private static final int D = KeyEvent.KEYCODE_DPAD_DOWN;
    private static final int L = KeyEvent.KEYCODE_DPAD_LEFT;
    private static final int R = KeyEvent.KEYCODE_DPAD_RIGHT;
    private final JSONArray results = new JSONArray();
    private final List<Integer> events = new ArrayList<>();
    private final Set<Integer> held = new LinkedHashSet<>();
    private View view;
    private Class<?> viewClass;
    private int menuCalls;
    private int assertions;
    private int passed;
    private int failed;
    private long downTime;
    private long eventTime;

    @Override public void onCreate(Bundle arguments) { super.onCreate(arguments); start(); }

    @Override public void onStart() {
        Bundle output = new Bundle();
        try {
            // Class loading comes from the installed target. The test APK contains no copy of it.
            viewClass = Class.forName("org.kuray.kif.TouchControlsView", true, getTargetContext().getClassLoader());
            runOnMainSync(() -> {
                runCase("short_confirm_tap", () -> {
                    RectF c = bounds("Confirm");
                    require(touch(MotionEvent.ACTION_DOWN, ids(3), points(c)), "confirm consumes DOWN");
                    touch(MotionEvent.ACTION_UP, ids(3), points(c));
                    trace(C, -C);
                });
                runCase("back_tap", () -> {
                    RectF b = bounds("Back");
                    touch(MotionEvent.ACTION_DOWN, ids(2), points(b));
                    touch(MotionEvent.ACTION_UP, ids(2), points(b));
                    trace(X, -X);
                });
                runCase("game_area_touch_passes_through", () -> {
                    require(!touch(MotionEvent.ACTION_DOWN, ids(0), points(background())), "background DOWN passes through");
                    trace();
                });
                runCase("direction_hold_releases_once", () -> {
                    float[] up = direction(U);
                    touch(MotionEvent.ACTION_DOWN, ids(7), points(up));
                    touch(MotionEvent.ACTION_MOVE, ids(7), points(up));
                    touch(MotionEvent.ACTION_MOVE, ids(7), points(up));
                    trace(U);
                    touch(MotionEvent.ACTION_UP, ids(7), points(up));
                    trace(U, -U);
                });
                runCase("direction_slide_and_neutral", () -> {
                    touch(MotionEvent.ACTION_DOWN, ids(4), points(direction(L)));
                    touch(MotionEvent.ACTION_MOVE, ids(4), points(direction(R)));
                    RectF pad = bounds("Dpad");
                    touch(MotionEvent.ACTION_MOVE, ids(4), points(pad));
                    require(held.isEmpty(), "neutral center releases direction");
                    touch(MotionEvent.ACTION_MOVE, ids(4), points(direction(D)));
                    touch(MotionEvent.ACTION_UP, ids(4), points(direction(D)));
                    trace(L, -L, R, -R, D, -D);
                });
                runCase("direction_and_confirm_two_fingers", () -> {
                    float[] up = direction(U), c = center(bounds("Confirm"));
                    touch(MotionEvent.ACTION_DOWN, ids(3), points(up));
                    touch(pointerDown(1), ids(3, 9), points(up, c));
                    require(held.contains(U) && held.contains(C) && held.size() == 2, "both controls held together");
                    touch(pointerUp(0), ids(3, 9), points(up, c));
                    require(held.size() == 1 && held.contains(C), "releasing first finger preserves confirm");
                    touch(MotionEvent.ACTION_UP, ids(9), points(c));
                    trace(U, C, -U, -C);
                });
                runCase("same_key_reference_count", () -> {
                    float[] c = center(bounds("Confirm"));
                    touch(MotionEvent.ACTION_DOWN, ids(2), points(c));
                    touch(pointerDown(1), ids(2, 8), points(c, c));
                    trace(C);
                    touch(pointerUp(0), ids(2, 8), points(c, c));
                    trace(C);
                    require(held.contains(C), "first release does not release the second finger");
                    touch(MotionEvent.ACTION_UP, ids(8), points(c));
                    trace(C, -C);
                });
                runCase("button_slide_out_and_reenter", () -> {
                    RectF c = bounds("Confirm");
                    touch(MotionEvent.ACTION_DOWN, ids(5), points(c));
                    touch(MotionEvent.ACTION_MOVE, ids(5), points(background()));
                    require(held.isEmpty(), "sliding out releases confirm");
                    touch(MotionEvent.ACTION_MOVE, ids(5), points(c));
                    touch(MotionEvent.ACTION_UP, ids(5), points(c));
                    trace(C, -C, C, -C);
                });
                runCase("cancel_releases_all_fingers", () -> {
                    float[] right = direction(R), c = center(bounds("Confirm"));
                    touch(MotionEvent.ACTION_DOWN, ids(1), points(right));
                    touch(pointerDown(1), ids(1, 6), points(right, c));
                    touch(MotionEvent.ACTION_CANCEL, ids(1, 6), points(right, c));
                    require(held.isEmpty() && events.size() == 4, "CANCEL releases both controls exactly once");
                    require(events.contains(-R) && events.contains(-C), "both CANCEL releases observed");
                });
                runCase("size_change_releases_held_key", () -> {
                    touch(MotionEvent.ACTION_DOWN, ids(0), points(bounds("Confirm")));
                    setScale(1.25f);
                    trace(C, -C);
                    require(held.isEmpty(), "resize leaves no held key");
                });
                runCase("focus_loss_releases_held_key", () -> {
                    touch(MotionEvent.ACTION_DOWN, ids(0), points(direction(D)));
                    view.onWindowFocusChanged(false);
                    trace(D, -D);
                });
                runCase("layout_change_releases_held_key", () -> {
                    touch(MotionEvent.ACTION_DOWN, ids(0), points(direction(L)));
                    layout(1920, 1080);
                    trace(L, -L);
                });
                runCase("explicit_reset_releases_held_key", () -> {
                    touch(MotionEvent.ACTION_DOWN, ids(0), points(bounds("Back")));
                    invoke("resetTouches");
                    trace(X, -X);
                    invoke("resetTouches");
                    trace(X, -X);
                });
                runCase("menu_fires_only_on_inside_release", () -> {
                    RectF m = bounds("Menu");
                    touch(MotionEvent.ACTION_DOWN, ids(0), points(m));
                    require(menuCalls == 0, "menu does not open on DOWN");
                    touch(MotionEvent.ACTION_MOVE, ids(0), points(background()));
                    touch(MotionEvent.ACTION_UP, ids(0), points(background()));
                    require(menuCalls == 0, "outside release cancels menu");
                    touch(MotionEvent.ACTION_DOWN, ids(2), points(m));
                    touch(MotionEvent.ACTION_UP, ids(2), points(m));
                    require(menuCalls == 1, "inside release opens menu once");
                    trace();
                });
                runCase("menu_releases_concurrent_direction", () -> {
                    float[] up = direction(U), m = center(bounds("Menu"));
                    touch(MotionEvent.ACTION_DOWN, ids(0), points(up));
                    touch(pointerDown(1), ids(0, 4), points(up, m));
                    require(menuCalls == 0, "second finger DOWN does not open menu");
                    touch(pointerUp(1), ids(0, 4), points(up, m));
                    require(menuCalls == 1 && held.isEmpty(), "menu opens after releasing the game control");
                    trace(U, -U);
                    touch(MotionEvent.ACTION_UP, ids(0), points(up));
                    trace(U, -U);
                });
                runCase("unrelated_finger_preserves_control", () -> {
                    float[] c = center(bounds("Confirm")), empty = background();
                    touch(MotionEvent.ACTION_DOWN, ids(5), points(c));
                    touch(pointerDown(1), ids(5, 11), points(c, empty));
                    touch(pointerUp(1), ids(5, 11), points(c, empty));
                    require(held.contains(C), "untouched game area finger does not clear confirm");
                    touch(MotionEvent.ACTION_UP, ids(5), points(c));
                    trace(C, -C);
                });
                runCase("scale_clamps_and_invalid_values", () -> {
                    setScale(-1); near(scale(), 0.65f, "minimum clamp");
                    setScale(100); near(scale(), 1.5f, "maximum clamp");
                    setScale(Float.NaN); near(scale(), 1, "NaN defaults to 100%");
                    setScale(Float.POSITIVE_INFINITY); near(scale(), 1, "infinity defaults to 100%");
                });
                runCase("geometry_1280x720", () -> geometry(1280, 720));
                runCase("geometry_1920x1080", () -> geometry(1920, 1080));
                runCase("small_landscape_geometry_fits", () -> {
                    layout(640, 360); setScale(1.5f);
                    requireInside(bounds("Dpad"), 640, 360, "small D-pad");
                    requireInside(bounds("Confirm"), 640, 360, "small confirm");
                    requireInside(bounds("Back"), 640, 360, "small back");
                    require(!RectF.intersects(bounds("Dpad"), bounds("Back")), "small screen clusters stay separate");
                });
            });
            JSONObject report = new JSONObject();
            report.put("targetPackage", getTargetContext().getPackageName());
            report.put("targetVersion", getTargetContext().getPackageManager().getPackageInfo(getTargetContext().getPackageName(), 0).versionName);
            report.put("targetClass", viewClass.getName());
            report.put("model", Build.MODEL);
            report.put("androidRelease", Build.VERSION.RELEASE);
            report.put("androidApi", Build.VERSION.SDK_INT);
            report.put("density", getTargetContext().getResources().getDisplayMetrics().density);
            report.put("passed", passed); report.put("failed", failed); report.put("assertions", assertions);
            report.put("cases", results);
            report.put("scope", "Installed TouchControlsView on Android main thread with real MotionEvent; no game activity launched or save files accessed");
            output.putString("kif.touch.report", report.toString());
            output.putString("passed", Integer.toString(passed));
            output.putString("failed", Integer.toString(failed));
            finish(failed == 0 ? Activity.RESULT_OK : Activity.RESULT_CANCELED, output);
        } catch (Throwable failure) {
            output.putString("kif.touch.error", android.util.Log.getStackTraceString(failure));
            finish(Activity.RESULT_CANCELED, output);
        }
    }

    private void runCase(String name, Check check) {
        JSONObject result = new JSONObject();
        try {
            freshView();
            int startAssertions = assertions;
            check.run();
            require(held.isEmpty(), "case finishes without held keys");
            result.put("name", name); result.put("passed", true);
            result.put("assertions", assertions - startAssertions);
            passed++;
        } catch (Throwable failure) {
            failed++;
            try { result.put("name", name); result.put("passed", false); result.put("error", android.util.Log.getStackTraceString(failure)); }
            catch (Exception ignored) { }
        } finally {
            try { if (view != null) invoke("resetTouches"); } catch (Exception ignored) { }
        }
        results.put(result);
    }

    private void freshView() throws Exception {
        events.clear(); held.clear(); menuCalls = 0;
        Class<?> listenerClass = Class.forName("org.kuray.kif.TouchControlsView$Listener", true, viewClass.getClassLoader());
        Object listener = Proxy.newProxyInstance(listenerClass.getClassLoader(), new Class<?>[] { listenerClass }, (proxy, method, args) -> {
            if ("onKey".equals(method.getName())) {
                int key = (Integer)args[0]; boolean down = (Boolean)args[1];
                require(down ? held.add(key) : held.remove(key), "no duplicate down or unmatched up for " + key);
                events.add(down ? key : -key);
            } else if ("onMenu".equals(method.getName())) {
                require(held.isEmpty(), "menu callback sees every game key released"); menuCalls++;
            } else if ("toString".equals(method.getName())) return "TouchChecksListener";
            else if ("hashCode".equals(method.getName())) return System.identityHashCode(proxy);
            else if ("equals".equals(method.getName())) return proxy == args[0];
            return null;
        });
        view = (View)viewClass.getConstructor(Context.class, listenerClass).newInstance(getTargetContext(), listener);
        layout(1280, 720);
    }

    private void layout(int width, int height) {
        view.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY));
        view.layout(0, 0, width, height);
    }

    private Object invoke(String name) throws Exception { return viewClass.getMethod(name).invoke(view); }
    private RectF bounds(String name) throws Exception { return (RectF)invoke("get" + name + "Bounds"); }
    private void setScale(float value) throws Exception { viewClass.getMethod("setScale", float.class).invoke(view, value); }
    private float scale() throws Exception { return (Float)invoke("getScale"); }
    private void near(float actual, float expected, String message) { require(Math.abs(actual - expected) < 0.001f, message); }
    private void require(boolean condition, String message) { assertions++; if (!condition) throw new AssertionError(message); }
    private void trace(int... expected) {
        List<Integer> values = new ArrayList<>(); for (int key : expected) values.add(key);
        require(events.equals(values), "key trace expected " + Arrays.toString(expected) + ", actual " + events);
    }

    private void geometry(int width, int height) throws Exception {
        layout(width, height);
        float previousDpad = 0, previousConfirm = 0, previousBack = 0;
        for (float size : new float[] {.65f, 1f, 1.5f}) {
            setScale(size); near(scale(), size, "requested size is retained");
            RectF pad = bounds("Dpad"), c = bounds("Confirm"), b = bounds("Back"), m = bounds("Menu");
            requireInside(pad, width, height, "D-pad"); requireInside(c, width, height, "confirm");
            requireInside(b, width, height, "back"); requireInside(m, width, height, "menu");
            require(pad.width() > previousDpad && c.width() > previousConfirm && b.width() > previousBack,
                    "65/100/150% visibly increase control sizes");
            previousDpad = pad.width(); previousConfirm = c.width(); previousBack = b.width();
            require(!RectF.intersects(pad, c) && !RectF.intersects(pad, b), "left and right clusters do not overlap");
            require(!RectF.intersects(c, b) && !RectF.intersects(m, c), "action controls and menu do not overlap");
            touch(MotionEvent.ACTION_DOWN, ids(0), points(c));
            touch(MotionEvent.ACTION_UP, ids(0), points(c));
            require(held.isEmpty(), "resized confirm releases");
        }
    }

    private void requireInside(RectF bounds, int width, int height, String label) {
        require(bounds.width() > 0 && bounds.height() > 0, label + " has visible size");
        require(bounds.left >= 0 && bounds.top >= 0 && bounds.right <= width && bounds.bottom <= height,
                label + " stays inside the safe container: " + bounds);
    }

    private float[] direction(int key) throws Exception {
        RectF pad = bounds("Dpad");
        if (key == U) return new float[] {pad.centerX(), pad.top + pad.height() * .15f};
        if (key == D) return new float[] {pad.centerX(), pad.bottom - pad.height() * .15f};
        if (key == L) return new float[] {pad.left + pad.width() * .15f, pad.centerY()};
        return new float[] {pad.right - pad.width() * .15f, pad.centerY()};
    }

    private float[] background() throws Exception {
        return new float[] {(bounds("Dpad").right + Math.min(bounds("Confirm").left, bounds("Back").left)) / 2,
                view.getHeight() * .45f};
    }

    private static int pointerDown(int index) { return MotionEvent.ACTION_POINTER_DOWN | index << MotionEvent.ACTION_POINTER_INDEX_SHIFT; }
    private static int pointerUp(int index) { return MotionEvent.ACTION_POINTER_UP | index << MotionEvent.ACTION_POINTER_INDEX_SHIFT; }
    private static int[] ids(int... ids) { return ids; }
    private static float[] center(RectF bounds) { return new float[] {bounds.centerX(), bounds.centerY()}; }
    private static float[][] points(RectF bounds) { return points(center(bounds)); }
    private static float[][] points(float[]... positions) { return positions; }

    private boolean touch(int action, int[] ids, float[][] positions) {
        MotionEvent.PointerProperties[] properties = new MotionEvent.PointerProperties[ids.length];
        MotionEvent.PointerCoords[] coordinates = new MotionEvent.PointerCoords[ids.length];
        for (int i = 0; i < ids.length; i++) {
            properties[i] = new MotionEvent.PointerProperties(); properties[i].id = ids[i];
            properties[i].toolType = MotionEvent.TOOL_TYPE_FINGER;
            coordinates[i] = new MotionEvent.PointerCoords();
            coordinates[i].x = positions[i][0]; coordinates[i].y = positions[i][1];
            coordinates[i].pressure = 1; coordinates[i].size = 1;
        }
        eventTime = Math.max(eventTime + 1, SystemClock.uptimeMillis());
        if (action == MotionEvent.ACTION_DOWN) downTime = eventTime;
        MotionEvent event = MotionEvent.obtain(downTime, eventTime, action, ids.length, properties,
                coordinates, 0, 0, 1, 1, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0);
        try { return view.dispatchTouchEvent(event); } finally { event.recycle(); }
    }
}
