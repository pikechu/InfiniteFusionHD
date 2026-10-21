package org.kuray.kif;

import android.app.Activity;
import android.os.*;
import android.system.Os;
import java.io.*;
import java.util.Locale;
import org.libsdl.app.SDLActivity;

/** The class/field/method names below match the pinned mkxp JNI contract. */
public final class GameActivity extends SDLActivity {
    private static String GAME_PATH;
    protected static volatile boolean fpsOverlayEnabled = false;
    private File output;
    @Override protected void onCreate(Bundle state) {
        try {
            output = NativeProbeLauncherActivity.privateDirectory(this, "output");
            String supplied = getIntent().getStringExtra("probePath");
            if (supplied == null) throw new IOException("Probe content path missing");
            File content = new File(supplied).getCanonicalFile();
            File expected = NativeProbeLauncherActivity.privateDirectory(this, "content");
            if (!content.isDirectory() || !content.getPath().startsWith(expected.getPath() + File.separator)) throw new IOException("Probe content escaped private files");
            GAME_PATH = content.getAbsolutePath();
            // A native loader failure must not leave a previous run's PASS as current evidence.
            try (FileOutputStream pending = new FileOutputStream(new File(output, "probe-result.json"))) {
                String status = new org.json.JSONObject().put("status", "native_start_pending")
                    .put("applicationId", getPackageName()).put("processId", android.os.Process.myPid())
                    .put("startedAtMillis", System.currentTimeMillis()).toString();
                pending.write(status.getBytes("UTF-8")); pending.getFD().sync();
            }
            Os.setenv("KIF_ANDROID_FILES", getFilesDir().getAbsolutePath(), true);
            Os.setenv("KIF_NATIVE_PROBE_OUTPUT", output.getAbsolutePath(), true);
            Os.setenv("KIF_SAVE_DIR", output.getAbsolutePath(), true);
            super.onCreate(state);
        } catch (Exception failure) { throw new IllegalStateException("Cannot prepare private probe paths", failure); }
    }
    @Override public void loadLibraries() {
        super.loadLibraries();
        org.libsdl.app.SDL.loadLibrary("kif_android_bridge");
        NetworkBridge.configure();
        NetworkBridge.clearVirtualKeys();
        // SDL's environment reaches translated guest libc as well as real ARM64.
        SDLActivity.nativeSetenv("KIF_ANDROID_FILES", getFilesDir().getAbsolutePath());
        SDLActivity.nativeSetenv("KIF_NATIVE_PROBE_OUTPUT", output.getAbsolutePath());
        SDLActivity.nativeSetenv("KIF_SAVE_DIR", output.getAbsolutePath());
        SDLActivity.nativeSetenv("KIF_NATIVE_LIB_DIR", getApplicationInfo().nativeLibraryDir);
        SDLActivity.nativeSetenv("KIF_ANDROID_NETWORK", "0");
        SDLActivity.nativeSetenv("KIF_ANDROID_INPUT", "0");
    }
    @Override protected void onResume() {
        super.onResume();
        // This pinned SDL wrapper leaves API >= 24 resume to its embedding Activity.
        if (GAME_PATH != null && !mBrokenLibraries) resumeNativeThread();
    }
    @Override protected void onPause() {
        if (!mBrokenLibraries) { NetworkBridge.clearVirtualKeys(); pauseNativeThread(); }
        super.onPause();
    }
    @Override protected void onDestroy() {
        super.onDestroy();
        // MRI is initialized only once in the separate :probe process.
        android.os.Process.killProcess(android.os.Process.myPid());
    }
    private static String getSystemLanguage() { return Locale.getDefault().toString(); }
    private static boolean hasVibrator() { return ((Vibrator)getContext().getSystemService(VIBRATOR_SERVICE)).hasVibrator(); }
    private static void vibrate(int duration) { ((Vibrator)getContext().getSystemService(VIBRATOR_SERVICE)).vibrate(VibrationEffect.createOneShot(Math.max(1, duration), VibrationEffect.DEFAULT_AMPLITUDE)); }
    private static void vibrateStop() { ((Vibrator)getContext().getSystemService(VIBRATOR_SERVICE)).cancel(); }
    private static boolean inMultiWindow(Activity activity) { return activity.isInMultiWindowMode(); }
    public static void updateFPSText(int value) { }
}
