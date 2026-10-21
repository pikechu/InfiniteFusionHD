package org.kuray.kif;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.widget.TextView;
import java.io.*;
import java.security.MessageDigest;
import java.util.*;
import java.util.zip.*;
import org.json.JSONObject;

/** Tiny private probe installer, with no game save management or external path inputs. */
public final class NativeProbeLauncherActivity extends Activity {
    static final String APPLICATION_ID = "org.kuray.kif.nativeprobe";
    private static String hex(byte[] bytes) {
        StringBuilder out = new StringBuilder();
        for (byte value : bytes) out.append(String.format(Locale.ROOT, "%02x", value & 255));
        return out.toString();
    }
    private static byte[] read(InputStream source) throws IOException {
        try (InputStream in = source; ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] b = new byte[65536]; int n;
            while ((n = in.read(b)) != -1) out.write(b, 0, n);
            return out.toByteArray();
        }
    }
    static File privateDirectory(Activity activity, String relative) throws IOException {
        if (!APPLICATION_ID.equals(activity.getPackageName())) throw new IOException("Wrong application identity");
        File base = new File(activity.getFilesDir(), "native-probe").getCanonicalFile();
        File path = new File(base, relative).getCanonicalFile();
        if (!path.getPath().startsWith(base.getPath() + File.separator)) throw new IOException("Invalid private probe path");
        if (!path.isDirectory() && !path.mkdirs()) throw new IOException("Cannot create private probe directory");
        return path;
    }
    private File install() throws Exception {
        JSONObject manifest = new JSONObject(new String(read(getAssets().open("probe-manifest.json")), "UTF-8"));
        String id = manifest.getString("id");
        if (!id.matches("[a-f0-9]{24}")) throw new IOException("Invalid probe content id");
        File root = privateDirectory(this, "content/" + id);
        JSONObject files = manifest.getJSONObject("files");
        Set<String> restored = new HashSet<>();
        try (ZipInputStream archive = new ZipInputStream(getAssets().open("probe-payload.zip"))) {
            ZipEntry item;
            while ((item = archive.getNextEntry()) != null) {
                String name = item.getName();
                if (item.isDirectory() || !files.has(name) || !restored.add(name) || name.contains("\\")) throw new IOException("Unlisted/duplicate probe payload entry");
                File dest = new File(root, name).getCanonicalFile();
                if (!dest.getPath().startsWith(root.getCanonicalPath() + File.separator)) throw new IOException("Probe payload path escaped");
                File parent = dest.getParentFile();
                if (!parent.isDirectory() && !parent.mkdirs()) throw new IOException("Cannot create payload directory");
                JSONObject expected = files.getJSONObject(name);
                MessageDigest digest = MessageDigest.getInstance("SHA-256");
                File pending = new File(dest.getPath() + ".pending");
                long size = 0;
                try (FileOutputStream out = new FileOutputStream(pending)) {
                    byte[] buffer = new byte[65536]; int n;
                    while ((n = archive.read(buffer)) != -1) {
                        size += n;
                        if (size > expected.getLong("size")) throw new IOException("Oversize probe file");
                        digest.update(buffer, 0, n); out.write(buffer, 0, n);
                    }
                    out.getFD().sync();
                }
                if (size != expected.getLong("size") || !hex(digest.digest()).equals(expected.getString("sha256"))) throw new IOException("Probe payload digest mismatch");
                if (!pending.renameTo(dest)) throw new IOException("Cannot commit probe payload");
            }
        }
        if (restored.size() != files.length()) throw new IOException("Incomplete probe payload");
        return root;
    }
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        TextView status = new TextView(this); status.setText("Native Ruby Probe: verifying private diagnostic files…"); setContentView(status);
        new Thread(() -> {
            try {
                File root = install();
                runOnUiThread(() -> { if (!isFinishing()) { startActivity(new Intent(this, GameActivity.class).putExtra("probePath", root.getAbsolutePath())); finish(); } });
            } catch (Exception failure) {
                android.util.Log.e("KIF-Native-Probe", "Probe installation failed", failure);
                runOnUiThread(() -> status.setText("Probe preparation failed: " + failure));
            }
        }, "native-probe-installer").start();
    }
}
