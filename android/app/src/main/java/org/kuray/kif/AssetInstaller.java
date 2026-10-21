package org.kuray.kif;

import android.content.Context;
import android.system.Os;
import org.json.JSONObject;
import java.io.*;
import java.security.MessageDigest;
import java.util.Iterator;

/** Versioned base content plus persistent writable overlays. Never stores saves in a content version. */
final class AssetInstaller {
    interface Progress { void update(long bytes, long total, String path); }
    private final Context context;
    AssetInstaller(Context context) { this.context = context; }

    static void mkdir(File dir) throws IOException {
        if (!dir.isDirectory() && !dir.mkdirs()) throw new IOException("Cannot create " + dir);
    }
    static String read(InputStream in) throws IOException {
        try (InputStream source = in; ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] b = new byte[65536]; int n;
            while ((n = source.read(b)) != -1) out.write(b, 0, n);
            return out.toString("UTF-8");
        }
    }
    private static String hex(byte[] bytes) {
        StringBuilder b = new StringBuilder();
        for (byte value : bytes) b.append(String.format(java.util.Locale.ROOT, "%02x", value & 255));
        return b.toString();
    }
    private static File safeChild(File root, String path) throws IOException {
        File file = new File(root, path);
        if (!file.getCanonicalPath().startsWith(root.getCanonicalPath() + File.separator))
            throw new IOException("Unsafe archive path: " + path);
        return file;
    }
    private static void link(File target, File path) throws Exception {
        if (path.exists()) return;
        mkdir(path.getParentFile());
        Os.symlink(target.getAbsolutePath(), path.getAbsolutePath());
    }
    private static void atomicText(File path, String text) throws IOException {
        File staging = new File(path.getPath() + ".pending");
        try (FileOutputStream out = new FileOutputStream(staging)) {
            out.write(text.getBytes("UTF-8")); out.getFD().sync();
        }
        if (!staging.renameTo(path)) throw new IOException("Cannot commit " + path);
    }

    private static String fileHash(File path) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (InputStream in = new FileInputStream(path)) {
            byte[] buffer = new byte[262144]; int n;
            while ((n = in.read(buffer)) != -1) digest.update(buffer, 0, n);
        }
        return hex(digest.digest());
    }
    private static void migrateGraphics(File previous, File current, File oldRoot) throws Exception {
        File oldManifest = new File(oldRoot, ".base-files.json");
        if (!oldManifest.isFile() || !previous.isDirectory()) return;
        JSONObject base = new JSONObject(read(new FileInputStream(oldManifest))).getJSONObject("files");
        java.util.ArrayDeque<File> queue = new java.util.ArrayDeque<>(); queue.add(previous);
        String prefix = previous.getCanonicalPath() + File.separator;
        while (!queue.isEmpty()) {
            File[] children = queue.remove().listFiles();
            if (children == null) throw new IOException("Cannot enumerate previous sprite downloads");
            for (File file : children) {
                if (!file.getCanonicalPath().startsWith(prefix)) throw new IOException("Sprite path escaped private storage");
                if (file.isDirectory()) { queue.add(file); continue; }
                String relative = file.getCanonicalPath().substring(prefix.length()).replace(File.separatorChar, '/');
                if (relative.endsWith(".installing")) continue;
                String key = "Graphics/" + relative;
                // Unchanged bundled images belong to their content version. Downloads and custom edits persist.
                if (base.has(key) && file.length() == base.getJSONObject(key).getLong("size") &&
                    fileHash(file).equals(base.getJSONObject(key).getString("sha256"))) continue;
                File dest = safeChild(current, relative); mkdir(dest.getParentFile());
                File pending = new File(dest.getPath() + ".installing");
                try (InputStream in = new FileInputStream(file); OutputStream out = new FileOutputStream(pending)) {
                    byte[] buffer = new byte[262144]; int n;
                    while ((n = in.read(buffer)) != -1) out.write(buffer, 0, n);
                }
                if (!pending.renameTo(dest)) throw new IOException("Cannot migrate sprite " + relative);
            }
        }
    }

    File install(Progress progress) throws Exception {
        // Activities may be reopened while an earlier installer thread is finishing.
        synchronized (AssetInstaller.class) { return installLocked(progress); }
    }
    private File installLocked(Progress progress) throws Exception {
        JSONObject manifest = new JSONObject(read(context.getAssets().open("payload-manifest.json")));
        String id = manifest.getString("id");
        if (!id.matches("[a-f0-9]{24}")) throw new IOException("Invalid content identity");
        int archiveFormat = manifest.optInt("archiveFormat", 1);
        if (archiveFormat != 1 && archiveFormat != 2) throw new IOException("Unsupported payload archive format");
        JSONObject entries = manifest.getJSONObject("files");
        java.util.LinkedHashMap<String, PayloadArchive.Entry> inventory = new java.util.LinkedHashMap<>();
        int archiveFiles = 0; long archiveBytes = 0;
        for (Iterator<String> it = entries.keys(); it.hasNext();) {
            String name = it.next(); JSONObject item = entries.getJSONObject(name);
            String source = item.has("source") ? item.getString("source") : null;
            if (archiveFormat == 1 && source != null) throw new IOException("Legacy payload cannot contain aliases");
            PayloadArchive.Entry entry = new PayloadArchive.Entry(item.getLong("size"), item.getString("sha256"), source);
            inventory.put(name, entry);
            if (source == null) { archiveFiles++; archiveBytes += entry.size; }
        }
        long total = PayloadArchive.validate(inventory);
        if (total != manifest.getLong("bytes") || (archiveFormat == 2 &&
            (archiveFiles != manifest.getInt("archiveFiles") || archiveBytes != manifest.getLong("archiveBytes"))))
            throw new IOException("Payload inventory totals mismatch");
        File files = context.getFilesDir();
        File root = new File(files, "content/" + id);
        File overlay = new File(files, "writable");
        // Each content version has its own writable sprite generation. A failed upgrade cannot mutate
        // the previous version's live tree. Additional downloads/edits are merged only after verification.
        File graphics = new File(overlay, "Graphics-" + id);
        File marker = new File(root, ".complete");
        mkdir(root); mkdir(graphics);
        for (String name : new String[]{"saves", "backups", "writable/Cache", "writable/ExportedPokemons", "writable/Mods", "logs"}) mkdir(new File(files, name));
        link(graphics, new File(root, "Graphics"));
        for (String name : new String[]{"Cache", "ExportedPokemons", "Mods"}) link(new File(overlay, name), new File(root, name));
        boolean bootFilesPresent = new File(root, "Game.ini").isFile() && new File(root, "kif_android_preload.rb").isFile() &&
            (manifest.optBoolean("runtimeOnly", false) || new File(root, "Data/Scripts.rxdata").isFile());
        if (marker.isFile() && bootFilesPresent && id.equals(read(new FileInputStream(marker)).trim())) {
            atomicText(new File(files, "active-content"), id);
            return root;
        }
        // Existing verified files can be reused after interruption; do not demand another full copy.
        long remaining = total;
        for (Iterator<String> it = entries.keys(); it.hasNext();) {
            String name = it.next();
            File dest = name.startsWith("Graphics/") ? safeChild(graphics, name.substring(9)) : safeChild(root, name);
            if (dest.isFile() && dest.length() == entries.getJSONObject(name).getLong("size")) remaining -= dest.length();
        }
        if (files.getUsableSpace() < remaining + 128L * 1024 * 1024) throw new IOException("Need at least " + ((remaining + 134217728) / 1048576) + " MiB free to finish installation");
        PayloadArchive.restore(context.getAssets().open("payload.zip"), inventory,
            name -> name.startsWith("Graphics/") ? safeChild(graphics, name.substring(9)) : safeChild(root, name),
            (done, expectedTotal, name) -> progress.update(done, expectedTotal, name));
        File active = new File(files, "active-content");
        if (active.isFile()) {
            String previous = read(new FileInputStream(active)).trim();
            if (previous.matches("[a-f0-9]{24}") && !previous.equals(id)) {
                progress.update(total, total, "Preserving downloaded and customized sprites…");
                migrateGraphics(new File(overlay, "Graphics-" + previous), graphics, new File(files, "content/" + previous));
            }
        }
        atomicText(new File(root, ".base-files.json"), manifest.toString());
        atomicText(marker, id);
        atomicText(new File(files, "active-content"), id);
        progress.update(total, total, "Ready");
        return root;
    }
}
