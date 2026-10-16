package org.kuray.kif;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.os.Bundle;
import android.view.Gravity;
import android.widget.*;
import java.io.File;

/** Installer runs outside SDL and outside the game process; failure never launches a partial installation. */
public final class LauncherActivity extends Activity {
    private TextView message;
    private ProgressBar progress;
    private boolean working;
    private File installedRoot;
    private LinearLayout saveMenu;
    private LinearLayout installLayout;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout layout = new LinearLayout(this);
        installLayout = layout;
        layout.setOrientation(LinearLayout.VERTICAL); layout.setGravity(Gravity.CENTER); layout.setPadding(48, 24, 48, 24);
        message = new TextView(this); message.setText("Preparing KIF game content…"); message.setTextSize(20); layout.addView(message);
        progress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal); progress.setMax(1000);
        layout.addView(progress, new LinearLayout.LayoutParams(-1, 24));
        setContentView(layout); install();
    }
    private void install() {
        if (working) return; working = true;
        new Thread(() -> {
            try {
                long started = android.os.SystemClock.elapsedRealtime();
                SaveTransfer.recoverIfNeeded(this);
                File root = new AssetInstaller(this).install((done, total, path) -> runOnUiThread(() -> {
                    progress.setProgress((int)(done * 1000 / Math.max(1, total)));
                    message.setText("Installing " + (done / 1048576) + " / " + (total / 1048576) + " MiB\n" + path);
                }));
                android.util.Log.i("KIF-Install", "Content ready in " + (android.os.SystemClock.elapsedRealtime() - started) + "ms at " + root);
                runOnUiThread(() -> {
                    if (isFinishing() || isDestroyed()) return;
                    installedRoot = root;
                    if (getIntent().getBooleanExtra("manageSaves", false)) showSaveMenu();
                    else startGame();
                });
            } catch (Exception ex) {
                android.util.Log.e("KIF-Install", "Installation failed", ex);
                runOnUiThread(() -> {
                    working = false;
                    if (!isFinishing() && !isDestroyed()) new AlertDialog.Builder(this).setTitle("KIF installation failed")
                        .setMessage(ex.getMessage() + "\nYour saves are unchanged. Free space if necessary, then retry.")
                        .setPositiveButton("Retry", (d, w) -> install()).setNegativeButton("Close", (d, w) -> finish()).show();
                });
            }
        }, "KIF-Installer").start();
    }
    private void startGame() {
        Intent game = new Intent(this, GameActivity.class).putExtra("gamePath", installedRoot.getAbsolutePath());
        if (getIntent().getBooleanExtra("runtimeSmoke", false)) game.putExtra("runtimeSmoke", true);
        if (getIntent().getBooleanExtra("gameSmoke", false)) game.putExtra("gameSmoke", true);
        if (getIntent().getBooleanExtra("networkSmoke", false)) game.putExtra("networkSmoke", true);
        startActivity(game); finish();
    }
    private void showSaveMenu() {
        LinearLayout menu = new LinearLayout(this); menu.setOrientation(LinearLayout.VERTICAL); menu.setGravity(Gravity.CENTER); menu.setPadding(48,24,48,24);
        saveMenu = menu;
        TextView title = new TextView(this); title.setText("KIF saves • export before uninstalling"); title.setTextSize(20); menu.addView(title);
        Button play = new Button(this); play.setText("Start game"); play.setOnClickListener(v -> startGame()); menu.addView(play);
        Button export = new Button(this); export.setText("Export saves to ZIP"); export.setOnClickListener(v -> startActivityForResult(new Intent(Intent.ACTION_CREATE_DOCUMENT).setType("application/zip").addCategory(Intent.CATEGORY_OPENABLE).putExtra(Intent.EXTRA_TITLE, "KIF-saves.zip"), 202)); menu.addView(export);
        Button importButton = new Button(this); importButton.setText("Import saves from ZIP"); importButton.setOnClickListener(v -> startActivityForResult(new Intent(Intent.ACTION_OPEN_DOCUMENT).setType("application/zip").addCategory(Intent.CATEGORY_OPENABLE), 201)); menu.addView(importButton);
        Button repair = new Button(this); repair.setText("Verify / repair bundled assets"); repair.setOnClickListener(v -> {
            File marker = new File(installedRoot, ".complete");
            if (marker.exists() && !marker.delete()) { Toast.makeText(this, "Cannot start asset verification", Toast.LENGTH_LONG).show(); return; }
            working = false; setContentView(installLayout);
            install();
        }); menu.addView(repair);
        setContentView(menu);
    }
    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (result != RESULT_OK || data == null || data.getData() == null) return;
        if (saveMenu != null) for (int i = 0; i < saveMenu.getChildCount(); i++) saveMenu.getChildAt(i).setEnabled(false);
        new Thread(() -> {
            try {
                String resultText;
                if (request == 202) {
                    try (java.io.OutputStream out = getContentResolver().openOutputStream(data.getData())) { resultText = SaveTransfer.exportZip(this, out); }
                } else if (request == 201) {
                    try (java.io.InputStream in = getContentResolver().openInputStream(data.getData())) { resultText = SaveTransfer.importZip(this, in); }
                } else return;
                final String message = resultText;
                runOnUiThread(() -> { if (!isFinishing() && !isDestroyed()) new AlertDialog.Builder(this).setMessage(message).setPositiveButton("OK", null).show(); });
            } catch (Exception ex) {
                android.util.Log.e("KIF-Saves", "Save transfer failed", ex);
                runOnUiThread(() -> { if (!isFinishing() && !isDestroyed()) new AlertDialog.Builder(this).setTitle("Save transfer failed").setMessage(ex.getMessage()).setPositiveButton("OK", null).show(); });
            } finally {
                runOnUiThread(() -> { if (saveMenu != null) for (int i = 0; i < saveMenu.getChildCount(); i++) saveMenu.getChildAt(i).setEnabled(true); });
            }
        }, "KIF-SaveTransfer").start();
    }
}
