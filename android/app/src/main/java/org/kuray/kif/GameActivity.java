package org.kuray.kif;

import android.app.Activity;
import android.os.*;
import android.system.Os;
import android.view.*;
import android.widget.*;
import android.graphics.Color;
import java.io.*;
import java.util.*;
import org.libsdl.app.SDLActivity;

public final class GameActivity extends SDLActivity {
    // JNI contracts of the pinned mkxp-z source. Keep these names even when the application id changes.
    private static String GAME_PATH;
    protected static volatile boolean fpsOverlayEnabled = false;
    private static TextView fps;
    private final Set<Integer> held = new HashSet<>();
    private boolean resumed;
    private boolean bridgeReady;
    private TouchControlsView touchControls;
    private LinearLayout extraControls;
    private final List<Button> extraKeyButtons = new ArrayList<>();
    private android.app.AlertDialog controlsDialog;
    private static final String CONTROL_PREFS = "touch_controls";
    private static final String CONTROL_SCALE = "button_scale";
    private static final String DISPLAY_PREFS = "display";
    private static final String DISPLAY_STRETCH = "stretch_to_fill";

    @Override public void loadLibraries() {
        super.loadLibraries();
        bridgeReady = false;
        SDLActivity.nativeSetenv("KIF_ANDROID_INPUT", "0");
        SDLActivity.nativeSetenv("KIF_ANDROID_NETWORK", "0");
        try {
            org.libsdl.app.SDL.loadLibrary("kif_android_bridge");
            NetworkBridge.configure();
            NetworkBridge.clearVirtualKeys();
            NetworkBridge.setDisplayStretch(savedDisplayStretch());
            bridgeReady = true;
        } catch (LinkageError | RuntimeException failure) {
            android.util.Log.e("KIF-Input", "Required virtual input bridge unavailable", failure);
            throw new IllegalStateException("Required KIF virtual input bridge unavailable. Rebuild with scripts/android/build_bridge.ps1.", failure);
        }
        // SDL's native environment is also used by ARM translation. Java Os.setenv alone
        // does not reach the guest libc environment on the Android 11 x86_64 emulator.
        SDLActivity.nativeSetenv("KIF_SAVE_DIR", new File(getFilesDir(), "saves").getAbsolutePath());
        SDLActivity.nativeSetenv("KIF_ANDROID_FILES", getFilesDir().getAbsolutePath());
        SDLActivity.nativeSetenv("KIF_NATIVE_LIB_DIR", getApplicationInfo().nativeLibraryDir);
        SDLActivity.nativeSetenv("KIF_ANDROID_INPUT", "1");
        SDLActivity.nativeSetenv("KIF_ANDROID_NETWORK", NetworkBridge.enabled(this) ? "1" : "0");
    }

    @Override protected void onCreate(Bundle state) {
        GAME_PATH = getIntent().getStringExtra("gamePath");
        if (GAME_PATH == null) { super.onCreate(state); finish(); return; }
        try {
            Os.setenv("KIF_SAVE_DIR", new File(getFilesDir(), "saves").getAbsolutePath(), true);
            Os.setenv("KIF_ANDROID_FILES", getFilesDir().getAbsolutePath(), true);
            if (getIntent().getBooleanExtra("fontSmoke", false)) writeConfig("android-font-smoke.rb");
            else if (getIntent().getBooleanExtra("networkSmoke", false)) writeConfig("android-network-smoke.rb");
            else if (getIntent().getBooleanExtra("runtimeSmoke", false)) {
                // Config is a per-content copy and is restored at every normal launch.
                writeConfig("android-runtime-smoke.rb");
            } else if (getIntent().getBooleanExtra("gameSmoke", false)) writeConfig("android-game-smoke.rb");
            else writeConfig(null);
        } catch (Exception ex) { throw new IllegalStateException("Cannot prepare game paths", ex); }
        super.onCreate(state);
        if (mBrokenLibraries || mLayout == null) return;
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        getWindow().setDecorFitsSystemWindows(false);
        WindowManager.LayoutParams window = getWindow().getAttributes();
        window.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
        getWindow().setAttributes(window);
        // Transient system bars overlay the game instead of resizing the RGSS viewport.
        // Physical cutouts remain excluded from both the surface and thumb controls.
        mLayout.setOnApplyWindowInsetsListener((view, insets) -> {
            android.graphics.Insets edges = insets.getInsets(WindowInsets.Type.displayCutout());
            view.setPadding(edges.left, edges.top, edges.right, edges.bottom); return insets;
        });
        createControls();
        enterImmersiveMode();
    }
    private void writeConfig(String script) throws Exception {
        String config = AssetInstaller.read(getAssets().open("mkxp-base.json"));
        org.json.JSONObject json = new org.json.JSONObject(config);
        json.put("fixedAspectRatio", !savedDisplayStretch());
        if (script != null) json.put("customScript", script);
        if ("android-font-smoke.rb".equals(script)) {
            int mode = getIntent().getIntExtra("fontMetricsMode", 1);
            if (mode != 0 && mode != 1) throw new IllegalArgumentException("Invalid font probe metrics mode");
            json.put("fontHeightReporting", mode);
        }
        File file = new File(GAME_PATH, "mkxp.json");
        try (FileOutputStream out = new FileOutputStream(file)) { out.write(json.toString(2).getBytes("UTF-8")); }
    }
    private int dp(int n) { return (int)(n * getResources().getDisplayMetrics().density + .5f); }
    private static int virtualCode(int code) {
        switch (code) {
            case KeyEvent.KEYCODE_DPAD_DOWN: return 2;
            case KeyEvent.KEYCODE_DPAD_LEFT: return 4;
            case KeyEvent.KEYCODE_DPAD_RIGHT: return 6;
            case KeyEvent.KEYCODE_DPAD_UP: return 8;
            case KeyEvent.KEYCODE_Z: case KeyEvent.KEYCODE_SHIFT_LEFT: case KeyEvent.KEYCODE_SHIFT_RIGHT: return 11;
            case KeyEvent.KEYCODE_X: case KeyEvent.KEYCODE_BACK: return 12;
            case KeyEvent.KEYCODE_C: case KeyEvent.KEYCODE_ENTER: case KeyEvent.KEYCODE_SPACE: return 13;
            case KeyEvent.KEYCODE_A: return 14;
            case KeyEvent.KEYCODE_S: return 15;
            case KeyEvent.KEYCODE_D: return 16;
            case KeyEvent.KEYCODE_Q: return 17;
            case KeyEvent.KEYCODE_W: return 18;
            default: throw new IllegalArgumentException("Unmapped virtual key: " + code);
        }
    }
    private void key(int code, boolean down) {
        if (!bridgeReady) throw new IllegalStateException("KIF virtual input bridge is not ready");
        int logical = virtualCode(code);
        if (down ? held.add(code) : held.remove(code)) {
            boolean logicalDown = false;
            for (int active : held) if (virtualCode(active) == logical) { logicalDown = true; break; }
            NetworkBridge.setVirtualKey(logical, logicalDown);
        }
    }
    private Button button(String text, int keycode) {
        Button b = new Button(this); b.setText(text); b.setTextSize(13); b.setFocusable(false);
        b.setMinWidth(0); b.setMinimumWidth(0); b.setPadding(0, 0, 0, 0);
        b.setOnTouchListener((view, event) -> {
            if (event.getActionMasked() == MotionEvent.ACTION_DOWN) { view.setPressed(true); key(keycode, true); return true; }
            if (event.getActionMasked() == MotionEvent.ACTION_UP || event.getActionMasked() == MotionEvent.ACTION_CANCEL) {
                key(keycode, false); view.setPressed(false);
                if (event.getActionMasked() == MotionEvent.ACTION_UP) view.performClick();
                return true;
            }
            return true;
        });
        extraKeyButtons.add(b);
        return b;
    }
    private void createControls() {
        // The surface owns all available space. The controls never reserve a side rail.
        android.view.ViewGroup.MarginLayoutParams surface = (android.view.ViewGroup.MarginLayoutParams)mSurface.getLayoutParams();
        surface.leftMargin = 0; surface.rightMargin = 0; mSurface.setLayoutParams(surface);
        RelativeLayout controls = new RelativeLayout(this);
        mLayout.addView(controls, new ViewGroup.LayoutParams(-1, -1));
        controls.setMotionEventSplittingEnabled(true);
        touchControls = new TouchControlsView(this, new TouchControlsView.Listener() {
            @Override public void onKey(int code, boolean down) { key(code, down); }
            @Override public void onMenu() { toggleExtraControls(); }
        });
        touchControls.setScale(savedControlScale());
        controls.addView(touchControls, new RelativeLayout.LayoutParams(-1, -1));

        extraControls = new LinearLayout(this); extraControls.setOrientation(LinearLayout.VERTICAL);
        extraControls.setPadding(dp(8), dp(8), dp(8), dp(8));
        android.graphics.drawable.GradientDrawable panel = new android.graphics.drawable.GradientDrawable();
        panel.setColor(0xe622262a); panel.setCornerRadius(dp(12)); extraControls.setBackground(panel);
        extraControls.setVisibility(View.GONE);
        extraControls.addView(actionButton("显示模式", () -> { hideExtraControls(); showDisplaySettings(); }), new LinearLayout.LayoutParams(-1, dp(44)));
        extraControls.addView(actionButton("按键设置", () -> { hideExtraControls(); showControlSettings(); }), new LinearLayout.LayoutParams(-1, dp(44)));
        GridLayout shortcuts = new GridLayout(this); shortcuts.setColumnCount(3);
        String[] labels = {"A", "S", "快捷 D", "Q", "W"};
        int[] codes = {KeyEvent.KEYCODE_A, KeyEvent.KEYCODE_S, KeyEvent.KEYCODE_D, KeyEvent.KEYCODE_Q, KeyEvent.KEYCODE_W};
        for (int i = 0; i < codes.length; i++) shortcuts.addView(button(labels[i], codes[i]), new ViewGroup.LayoutParams(dp(64), dp(44)));
        extraControls.addView(shortcuts);
        LinearLayout tools = new LinearLayout(this);
        tools.addView(actionButton("键盘", () -> {
            hideExtraControls(); NetworkBridge.requestTextInput();
            SDLActivity.showTextInput(dp(8), 0, 1, 1);
        }), new LinearLayout.LayoutParams(0, dp(44), 1));
        tools.addView(actionButton("存档 / 退出", () -> { hideExtraControls(); showSaveManager(); }), new LinearLayout.LayoutParams(0, dp(44), 1));
        extraControls.addView(tools);
        RelativeLayout.LayoutParams extra = new RelativeLayout.LayoutParams(dp(208), -2);
        extra.addRule(RelativeLayout.ALIGN_PARENT_RIGHT); extra.topMargin = dp(60); extra.rightMargin = dp(12);
        controls.addView(extraControls, extra);
        fps = new TextView(this); fps.setTextColor(Color.WHITE); fps.setTextSize(11); fps.setText("InfiniteFusionHD • starting");
        fps.setVisibility(fpsOverlayEnabled ? View.VISIBLE : View.GONE);
        RelativeLayout.LayoutParams fp = new RelativeLayout.LayoutParams(-2, -2); fp.leftMargin = dp(8); controls.addView(fps, fp);
    }
    private Button actionButton(String label, Runnable action) {
        Button b = new Button(this); b.setText(label); b.setTextSize(12); b.setFocusable(false); b.setMinWidth(0); b.setMinimumWidth(0); b.setPadding(0, 0, 0, 0);
        b.setOnClickListener(view -> action.run()); return b;
    }
    private float savedControlScale() {
        float value = getSharedPreferences(CONTROL_PREFS, MODE_PRIVATE).getFloat(CONTROL_SCALE, 1f);
        if (Float.isNaN(value) || Float.isInfinite(value)) return 1f;
        return Math.max(TouchControlsView.MIN_SCALE, Math.min(TouchControlsView.MAX_SCALE, value));
    }
    private boolean savedDisplayStretch() {
        return getSharedPreferences(DISPLAY_PREFS, MODE_PRIVATE).getBoolean(DISPLAY_STRETCH, false);
    }
    private void showDisplaySettings() {
        releaseKeys();
        android.app.AlertDialog dialog = new android.app.AlertDialog.Builder(this)
            .setTitle("显示模式")
            .setSingleChoiceItems(new String[] {"保持比例（默认）", "拉伸填满"}, savedDisplayStretch() ? 1 : 0,
                (choice, which) -> {
                    boolean stretch = which == 1;
                    NetworkBridge.setDisplayStretch(stretch);
                    getSharedPreferences(DISPLAY_PREFS, MODE_PRIVATE).edit().putBoolean(DISPLAY_STRETCH, stretch).apply();
                    choice.dismiss();
                })
            .setNegativeButton("取消", null).create();
        dialog.setOnDismissListener(closed -> { mSurface.requestFocus(); enterImmersiveMode(); });
        dialog.show();
    }
    private void toggleExtraControls() {
        boolean show = extraControls.getVisibility() != View.VISIBLE;
        releaseKeys(); extraControls.setVisibility(show ? View.VISIBLE : View.GONE);
    }
    private void hideExtraControls() {
        releaseKeys(); if (extraControls != null) extraControls.setVisibility(View.GONE);
    }
    private void showControlSettings() {
        if (controlsDialog != null) return;
        final float before = savedControlScale();
        final boolean[] saved = {false};
        LinearLayout content = new LinearLayout(this); content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(dp(24), dp(12), dp(24), dp(8));
        TextView value = new TextView(this); value.setTextSize(17);
        SeekBar size = new SeekBar(this);
        int min = Math.round(TouchControlsView.MIN_SCALE * 100), max = Math.round(TouchControlsView.MAX_SCALE * 100);
        size.setMax(max - min); size.setContentDescription("按键大小");
        size.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override public void onProgressChanged(SeekBar bar, int progress, boolean user) {
                int percent = min + progress; value.setText("按键大小：" + percent + "%"); touchControls.setScale(percent / 100f);
            }
            @Override public void onStartTrackingTouch(SeekBar bar) { releaseKeys(); }
            @Override public void onStopTrackingTouch(SeekBar bar) {}
        });
        size.setProgress(Math.round(before * 100) - min);
        value.setText("按键大小：" + Math.round(before * 100) + "%");
        TextView hint = new TextView(this); hint.setText(min + "%–" + max + "%，滑动可预览。小屏会自动限制最大尺寸，不改变游戏画面大小。"); hint.setTextSize(13);
        content.addView(value); content.addView(size, new LinearLayout.LayoutParams(-1, dp(48))); content.addView(hint);
        controlsDialog = new android.app.AlertDialog.Builder(this).setTitle("按键设置").setView(content)
            .setPositiveButton("保存", (dialog, which) -> {
                getSharedPreferences(CONTROL_PREFS, MODE_PRIVATE).edit().putFloat(CONTROL_SCALE, (min + size.getProgress()) / 100f).apply(); saved[0] = true;
            }).setNegativeButton("取消", null).setNeutralButton("恢复默认", null).create();
        controlsDialog.setOnDismissListener(dialog -> {
            touchControls.setScale(saved[0] ? savedControlScale() : before); controlsDialog = null; mSurface.requestFocus(); enterImmersiveMode();
        });
        controlsDialog.show();
        controlsDialog.getButton(android.app.AlertDialog.BUTTON_NEUTRAL).setOnClickListener(view -> size.setProgress(100 - min));
        controlsDialog.getWindow().setDimAmount(.25f);
    }
    private void showSaveManager() {
        new android.app.AlertDialog.Builder(this).setTitle("关闭游戏以管理存档？").setMessage("请先在游戏内保存。未保存的进度会丢失。")
            .setPositiveButton("关闭游戏", (dialog, which) -> {
                startActivity(new android.content.Intent(this, LauncherActivity.class).putExtra("manageSaves", true)); finish();
            }).setNegativeButton("取消", null).show();
    }
    private void enterImmersiveMode() {
        if (mLayout == null || mBrokenLibraries) return;
        WindowInsetsController controller = getWindow().getInsetsController();
        if (controller != null) {
            controller.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
            controller.hide(WindowInsets.Type.systemBars());
        }
    }
    private void releaseKeys() {
        if (touchControls != null) touchControls.resetTouches();
        for (Button b : extraKeyButtons) b.setPressed(false);
        held.clear(); if (bridgeReady) NetworkBridge.clearVirtualKeys();
    }
    @Override public void onWindowFocusChanged(boolean focused) {
        super.onWindowFocusChanged(focused);
        if (focused) enterImmersiveMode(); else if (bridgeReady) releaseKeys();
    }
    @Override protected void onResume() {
        super.onResume(); resumed = true;
        if (GAME_PATH != null && !mBrokenLibraries) {
            resumeNativeThread(); enterImmersiveMode();
            if (!getIntent().getBooleanExtra("runtimeSmoke", false)
                && !getIntent().getBooleanExtra("gameSmoke", false)
                && !getIntent().getBooleanExtra("networkSmoke", false)
                && !getIntent().getBooleanExtra("fontSmoke", false)) Analytics.onGameResume(this);
        }
    }
    @Override protected void onPause() {
        Analytics.onGamePause(); NetworkBridge.cancelPendingRequests();
        if (!mBrokenLibraries) { releaseKeys(); pauseNativeThread(); }
        resumed = false; super.onPause();
    }
    @Override public boolean dispatchKeyEvent(KeyEvent event) {
        if (event.getKeyCode() == KeyEvent.KEYCODE_BACK && !mBrokenLibraries) {
            if (mScreenKeyboardShown) {
                if (event.getAction() == KeyEvent.ACTION_UP) {
                    ((android.view.inputmethod.InputMethodManager)getSystemService(INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(mLayout.getWindowToken(), 0);
                    mScreenKeyboardShown = false;
                    if (mTextEdit != null) ((View)mTextEdit).setVisibility(View.GONE);
                }
                return true;
            }
            if (extraControls != null && extraControls.getVisibility() == View.VISIBLE) {
                if (event.getAction() == KeyEvent.ACTION_UP) hideExtraControls();
                return true;
            }
            key(event.getKeyCode(), event.getAction() == KeyEvent.ACTION_DOWN); return true;
        }
        return super.dispatchKeyEvent(event);
    }
    @Override protected void onDestroy() {
        Analytics.onGamePause(); if (!mBrokenLibraries) releaseKeys(); super.onDestroy();
        // MRI cannot be initialized twice in one process. The launcher remains in its own process.
        android.os.Process.killProcess(android.os.Process.myPid());
    }
    private static String getSystemLanguage() { return Locale.getDefault().toString(); }
    private static boolean hasVibrator() { return ((Vibrator)getContext().getSystemService(VIBRATOR_SERVICE)).hasVibrator(); }
    private static void vibrate(int duration) { ((Vibrator)getContext().getSystemService(VIBRATOR_SERVICE)).vibrate(VibrationEffect.createOneShot(Math.max(1, duration), VibrationEffect.DEFAULT_AMPLITUDE)); }
    private static void vibrateStop() { ((Vibrator)getContext().getSystemService(VIBRATOR_SERVICE)).cancel(); }
    private static boolean inMultiWindow(Activity activity) { return activity.isInMultiWindowMode(); }
    public static void updateFPSText(int value) { if (fps != null) ((Activity)getContext()).runOnUiThread(() -> fps.setText(value + " FPS")); }
}
