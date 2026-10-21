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
    protected static volatile boolean fpsOverlayEnabled = true;
    private static TextView fps;
    private final Set<Integer> held = new HashSet<>();
    private boolean resumed;

    @Override public void loadLibraries() {
        super.loadLibraries();
        // SDL's native environment is also used by ARM translation. Java Os.setenv alone
        // does not reach the guest libc environment on the Android 11 x86_64 emulator.
        SDLActivity.nativeSetenv("KIF_SAVE_DIR", new File(getFilesDir(), "saves").getAbsolutePath());
        SDLActivity.nativeSetenv("KIF_ANDROID_FILES", getFilesDir().getAbsolutePath());
        try {
            System.loadLibrary("kif_android_bridge");
            NetworkBridge.configure();
            SDLActivity.nativeSetenv("KIF_NATIVE_LIB_DIR", getApplicationInfo().nativeLibraryDir);
            SDLActivity.nativeSetenv("KIF_ANDROID_NETWORK", "1");
        } catch (UnsatisfiedLinkError | RuntimeException unavailable) {
            android.util.Log.w("KIF-Network", "Verified HTTPS bridge unavailable; offline mode remains available");
        }
    }

    @Override protected void onCreate(Bundle state) {
        GAME_PATH = getIntent().getStringExtra("gamePath");
        if (GAME_PATH == null) { super.onCreate(state); finish(); return; }
        try {
            Os.setenv("KIF_SAVE_DIR", new File(getFilesDir(), "saves").getAbsolutePath(), true);
            Os.setenv("KIF_ANDROID_FILES", getFilesDir().getAbsolutePath(), true);
            if (getIntent().getBooleanExtra("runtimeSmoke", false)) {
                // Config is a per-content copy and is restored at every normal launch.
                writeConfig("android-runtime-smoke.rb");
            } else if (getIntent().getBooleanExtra("gameSmoke", false)) writeConfig("android-game-smoke.rb");
            else writeConfig(null);
        } catch (Exception ex) { throw new IllegalStateException("Cannot prepare game paths", ex); }
        super.onCreate(state);
        if (mBrokenLibraries || mLayout == null) return;
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        // Insets apply to the whole surface and controls; the game retains its 4:3 aspect ratio inside.
        mLayout.setOnApplyWindowInsetsListener((view, insets) -> {
            android.graphics.Insets edges = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
            view.setPadding(edges.left, edges.top, edges.right, edges.bottom); return insets;
        });
        createControls();
    }
    private void writeConfig(String script) throws Exception {
        String config = AssetInstaller.read(getAssets().open("mkxp-base.json"));
        org.json.JSONObject json = new org.json.JSONObject(config);
        if (script != null) json.put("customScript", script);
        File file = new File(GAME_PATH, "mkxp.json");
        try (FileOutputStream out = new FileOutputStream(file)) { out.write(json.toString(2).getBytes("UTF-8")); }
    }
    private int dp(int n) { return (int)(n * getResources().getDisplayMetrics().density + .5f); }
    private void key(int code, boolean down) {
        if (down ? held.add(code) : held.remove(code)) {
            if (down) SDLActivity.onNativeKeyDown(code); else SDLActivity.onNativeKeyUp(code);
        }
    }
    private Button button(String text, int keycode) {
        Button b = new Button(this); b.setText(text); b.setTextSize(13); b.setAlpha(.65f);
        b.setMinWidth(0); b.setMinimumWidth(0); b.setPadding(0, 0, 0, 0);
        b.setOnTouchListener((view, event) -> {
            if (event.getActionMasked() == MotionEvent.ACTION_DOWN) { key(keycode, true); return true; }
            if (event.getActionMasked() == MotionEvent.ACTION_UP || event.getActionMasked() == MotionEvent.ACTION_CANCEL) { key(keycode, false); view.performClick(); return true; }
            return true;
        });
        return b;
    }
    private void createControls() {
        // Controls occupy side rails. The surface is inset by the same rail width to avoid covering game menus.
        int rail = dp(112);
        android.view.ViewGroup.MarginLayoutParams surface = (android.view.ViewGroup.MarginLayoutParams)mSurface.getLayoutParams();
        surface.leftMargin = rail; surface.rightMargin = rail; mSurface.setLayoutParams(surface);
        RelativeLayout controls = new RelativeLayout(this);
        mLayout.addView(controls, new ViewGroup.LayoutParams(-1, -1));
        GridLayout arrows = new GridLayout(this); arrows.setColumnCount(3); arrows.setRowCount(3);
        for (int i = 0; i < 9; i++) {
            String[] labels = {"", "↑", "", "←", "", "→", "", "↓", ""};
            int[] codes = {0, KeyEvent.KEYCODE_DPAD_UP, 0, KeyEvent.KEYCODE_DPAD_LEFT, 0, KeyEvent.KEYCODE_DPAD_RIGHT, 0, KeyEvent.KEYCODE_DPAD_DOWN, 0};
            View cell = codes[i] == 0 ? new View(this) : button(labels[i], codes[i]);
            arrows.addView(cell, new ViewGroup.LayoutParams(dp(36), dp(48)));
        }
        RelativeLayout.LayoutParams left = new RelativeLayout.LayoutParams(rail, dp(144)); left.addRule(RelativeLayout.ALIGN_PARENT_LEFT); left.addRule(RelativeLayout.CENTER_VERTICAL); controls.addView(arrows, left);
        GridLayout right = new GridLayout(this); right.setColumnCount(2);
        String[] labels = {"OK(C)", "Back(X)", "Run(Z)", "A", "S", "D", "Q", "W"};
        int[] codes = {KeyEvent.KEYCODE_C, KeyEvent.KEYCODE_X, KeyEvent.KEYCODE_Z, KeyEvent.KEYCODE_A, KeyEvent.KEYCODE_S, KeyEvent.KEYCODE_D, KeyEvent.KEYCODE_Q, KeyEvent.KEYCODE_W};
        for (int i = 0; i < codes.length; i++) right.addView(button(labels[i], codes[i]), new ViewGroup.LayoutParams(dp(56), dp(48)));
        Button keyboard = new Button(this); keyboard.setText("Keyboard"); keyboard.setTextSize(10); keyboard.setPadding(0,0,0,0);
        keyboard.setOnClickListener(view -> SDLActivity.showTextInput(rail, 0, 1, 1));
        GridLayout.LayoutParams keyboardLayout = new GridLayout.LayoutParams(GridLayout.spec(4), GridLayout.spec(0, 2));
        keyboardLayout.width = dp(112); keyboardLayout.height = dp(40); right.addView(keyboard, keyboardLayout);
        Button saves = new Button(this); saves.setText("Saves / Exit"); saves.setTextSize(10); saves.setPadding(0,0,0,0);
        saves.setOnClickListener(view -> {
            new android.app.AlertDialog.Builder(this).setTitle("Close game to manage saves?").setMessage("Save in the game first. Unsaved progress will be lost.")
                .setPositiveButton("Close game", (dialog, which) -> {
                    startActivity(new android.content.Intent(this, LauncherActivity.class).putExtra("manageSaves", true)); finish();
                }).setNegativeButton("Cancel", null).show();
        });
        GridLayout.LayoutParams savesLayout = new GridLayout.LayoutParams(GridLayout.spec(5), GridLayout.spec(0, 2));
        savesLayout.width = dp(112); savesLayout.height = dp(40); right.addView(saves, savesLayout);
        RelativeLayout.LayoutParams rp = new RelativeLayout.LayoutParams(rail, -2); rp.addRule(RelativeLayout.ALIGN_PARENT_RIGHT); rp.addRule(RelativeLayout.CENTER_VERTICAL); controls.addView(right, rp);
        fps = new TextView(this); fps.setTextColor(Color.WHITE); fps.setTextSize(11); fps.setText("KIF • starting");
        RelativeLayout.LayoutParams fp = new RelativeLayout.LayoutParams(-2, -2); fp.leftMargin = rail; controls.addView(fps, fp);
    }
    private void releaseKeys() { for (int code : new ArrayList<>(held)) key(code, false); }
    @Override protected void onResume() {
        super.onResume(); resumed = true;
        if (GAME_PATH != null && !mBrokenLibraries) {
            resumeNativeThread();
            if (mLayout != null && !getIntent().getBooleanExtra("runtimeSmoke", false)
                && !getIntent().getBooleanExtra("gameSmoke", false)) Analytics.onGameResume(this);
        }
    }
    @Override protected void onPause() { Analytics.onGamePause(); if (!mBrokenLibraries) { releaseKeys(); pauseNativeThread(); } resumed = false; super.onPause(); }
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
            key(KeyEvent.KEYCODE_X, event.getAction() == KeyEvent.ACTION_DOWN); return true;
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
