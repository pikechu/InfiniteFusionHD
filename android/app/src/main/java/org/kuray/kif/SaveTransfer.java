package org.kuray.kif;

import android.app.ActivityManager;
import android.content.Context;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.zip.*;

/** Byte-only SAF transfers. Never loads Ruby/Marshal objects or overwrites a save. */
public final class SaveTransfer {
    public static final int MAX_FILES = 4096;
    public static final int MAX_ENTRIES = 8192;
    public static final long MAX_FILE_BYTES = 64L * 1024 * 1024;
    public static final long MAX_TOTAL_BYTES = 512L * 1024 * 1024;
    public static final long MAX_ARCHIVE_BYTES = 256L * 1024 * 1024;
    private static final String WORK = ".kif-save-transfer-v1";
    private static final String OWNER = "KIF_PRIVATE_SAVE_TRANSFER_V1\n";
    private SaveTransfer() { }

    /** Call before starting the game, including after a process was killed during import. */
    public static synchronized void recoverIfNeeded(Context context) throws IOException {
        Path files = privateFiles(context), saves = files.resolve("saves"), work = files.resolve(WORK);
        if (!Files.exists(work, LinkOption.NOFOLLOW_LINKS)) return;
        assertGameStopped(context);
        noLink(work);
        Path marker = work.resolve("owner");
        if (!Files.exists(marker, LinkOption.NOFOLLOW_LINKS)) {
            try (DirectoryStream<Path> entries = Files.newDirectoryStream(work)) {
                if (entries.iterator().hasNext()) throw new IOException("Unrecognized save-transfer staging directory; saves were not changed.");
            }
            Files.delete(work); // Only an empty, reserved staging directory.
            return;
        }
        noLink(marker);
        if (Files.size(marker) > 128 || !OWNER.equals(new String(Files.readAllBytes(marker), StandardCharsets.UTF_8)))
            throw new IOException("Invalid save-transfer recovery marker; saves were not changed.");
        Path previous = work.resolve("previous");
        if (Files.exists(previous, LinkOption.NOFOLLOW_LINKS)) {
            noLink(previous);
            if (!Files.exists(saves, LinkOption.NOFOLLOW_LINKS)) {
                Files.move(previous, saves, StandardCopyOption.ATOMIC_MOVE);
            } else {
                noLink(saves); // Both exist only after the merged directory was activated.
            }
        }
        deleteTree(work);
    }

    /** Caller owns the stream. Call from a worker thread while the game is closed. */
    public static synchronized String exportZip(Context context, OutputStream destination) throws IOException {
        assertGameStopped(context);
        recoverIfNeeded(context);
        Path saves = privateFiles(context).resolve("saves");
        List<Path> entries = new ArrayList<>();
        if (Files.exists(saves, LinkOption.NOFOLLOW_LINKS)) collect(saves, saves, entries, true, new long[2]);
        try (ZipOutputStream zip = new ZipOutputStream(new FilterOutputStream(destination) {
            @Override public void write(byte[] b, int off, int len) throws IOException { out.write(b, off, len); }
            @Override public void close() throws IOException { flush(); }
        })) {
            byte[] buffer = new byte[65536];
            long total = 0;
            for (Path file : entries) {
                String relative = relative(saves, file);
                zip.putNextEntry(new ZipEntry(relative));
                long size = 0;
                try (InputStream in = Files.newInputStream(file, LinkOption.NOFOLLOW_LINKS)) {
                    int count;
                    while ((count = in.read(buffer)) != -1) {
                        size += count; total += count;
                        checkSizes(size, total);
                        zip.write(buffer, 0, count);
                    }
                }
                zip.closeEntry();
            }
        }
        return "Exported " + entries.size() + " save, backup and keybinding files.";
    }

    /** All ZIP entries are staged/validated before a directory transaction activates any file. */
    public static synchronized String importZip(Context context, InputStream source) throws IOException {
        assertGameStopped(context);
        recoverIfNeeded(context);
        Path files = privateFiles(context), saves = files.resolve("saves"), work = files.resolve(WORK);
        Files.createDirectory(work);
        try {
            try (FileOutputStream marker = new FileOutputStream(work.resolve("owner").toFile())) {
                marker.write(OWNER.getBytes(StandardCharsets.UTF_8)); marker.getFD().sync();
            }
            Path incoming = Files.createDirectory(work.resolve("incoming"));
            List<String> imported = extract(source, incoming);
            if (imported.isEmpty()) throw new IOException("The ZIP contains no supported save files.");

            List<Path> existing = new ArrayList<>();
            if (Files.exists(saves, LinkOption.NOFOLLOW_LINKS)) collect(saves, saves, existing, false, new long[2]);
            Set<String> occupied = new HashSet<>();
            long oldBytes = 0, newBytes = 0;
            for (Path old : existing) { occupied.add(relative(saves, old).toLowerCase(Locale.ROOT)); oldBytes += Files.size(old); }
            for (String name : imported) {
                if (occupied.contains(name.toLowerCase(Locale.ROOT)))
                    throw new IOException("A save already exists: " + name + ". Rename it in the ZIP or export a backup first; nothing was imported.");
                newBytes += Files.size(incoming.resolve(name));
            }
            if (files.toFile().getUsableSpace() < oldBytes + newBytes + 16L * 1024 * 1024)
                throw new IOException("Not enough free space to prepare the save import; existing saves are unchanged.");

            Path merged = Files.createDirectory(work.resolve("merged"));
            for (Path old : existing) copyDurable(old, merged.resolve(relative(saves, old)));
            for (String name : imported) copyDurable(incoming.resolve(name), merged.resolve(name));
            assertGameStopped(context);
            // Same-filesystem renames: no individual imported file is visible before activation.
            if (Files.exists(saves, LinkOption.NOFOLLOW_LINKS)) {
                noLink(saves);
                Files.move(saves, work.resolve("previous"), StandardCopyOption.ATOMIC_MOVE);
            }
            try {
                Files.move(merged, saves, StandardCopyOption.ATOMIC_MOVE);
            } catch (IOException failure) {
                Path previous = work.resolve("previous");
                if (Files.exists(previous, LinkOption.NOFOLLOW_LINKS)) {
                    try { Files.move(previous, saves, StandardCopyOption.ATOMIC_MOVE); }
                    catch (IOException restore) { failure.addSuppressed(restore); }
                }
                throw failure;
            }
            // If cleanup is interrupted, recovery sees both active saves and previous,
            // keeps the complete active directory and removes only our owned workspace.
            try { deleteTree(work); } catch (IOException ignored) { }
            return "Imported " + imported.size() + " files. Existing saves were preserved.";
        } catch (IOException | RuntimeException failure) {
            try {
                // If marker creation itself failed, this invocation still owns
                // the newly created workspace and has not moved the save tree.
                if (!Files.exists(work.resolve("previous"), LinkOption.NOFOLLOW_LINKS)) deleteTree(work);
                else recoverIfNeeded(context);
            } catch (IOException recovery) { failure.addSuppressed(recovery); }
            throw failure;
        }
    }

    private static List<String> extract(InputStream source, Path incoming) throws IOException {
        LimitedInputStream limited = new LimitedInputStream(source, MAX_ARCHIVE_BYTES);
        List<String> files = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        byte[] buffer = new byte[65536];
        long total = 0;
        int entries = 0;
        try (ZipInputStream zip = new ZipInputStream(new FilterInputStream(limited) {
            @Override public void close() { }
        })) {
            ZipEntry entry;
            while ((entry = zip.getNextEntry()) != null) {
                if (++entries > MAX_ENTRIES) throw new IOException("ZIP contains too many entries (maximum " + MAX_ENTRIES + ").");
                String name = safeName(entry.getName(), entry.isDirectory());
                if (!seen.add(name.toLowerCase(Locale.ROOT))) throw new IOException("Duplicate ZIP path: " + name);
                if (entry.isDirectory()) {
                    // A directory with hidden data must not bypass expanded-byte
                    // limits through ZipInputStream.closeEntry's discard loop.
                    if (entry.getSize() > 0 || zip.read() != -1) throw new IOException("ZIP directory entries must not contain data.");
                    zip.closeEntry(); continue;
                }
                if (!supported(name)) throw new IOException("Unsupported save-import file: " + name + ". JSON settings and diagnostic files are not imported.");
                if (files.size() >= MAX_FILES) throw new IOException("ZIP contains too many files (maximum " + MAX_FILES + ").");
                Path output = incoming.resolve(name).normalize();
                if (!output.startsWith(incoming)) throw new IOException("ZIP path escapes save staging.");
                Files.createDirectories(output.getParent());
                long size = 0;
                try (FileOutputStream out = new FileOutputStream(output.toFile())) {
                    int count;
                    while ((count = zip.read(buffer)) != -1) {
                        size += count; total += count;
                        checkSizes(size, total);
                        out.write(buffer, 0, count);
                    }
                    out.getFD().sync();
                }
                long compressed = entry.getCompressedSize();
                if (size > 1024 * 1024 && compressed > 0 && size / compressed > 1000)
                    throw new IOException("ZIP compression ratio exceeds the save-import limit.");
                zip.closeEntry(); // Also validates the ZIP CRC.
                files.add(name);
            }
            // Count trailing archive data too, without closing the caller's stream.
            while (limited.read(buffer) != -1) { }
        }
        return files;
    }

    private static String safeName(String raw, boolean directory) throws IOException {
        if (raw == null || raw.isEmpty() || raw.length() > 1024 || raw.startsWith("/") || raw.indexOf('\\') >= 0 || raw.indexOf(':') >= 0)
            throw new IOException("Absolute or invalid ZIP path.");
        String name = directory && raw.endsWith("/") ? raw.substring(0, raw.length() - 1) : raw;
        String[] segments = name.split("/", -1);
        if (segments.length > 16) throw new IOException("ZIP path is too deeply nested.");
        for (String part : segments) {
            if (part.isEmpty() || part.equals(".") || part.equals("..") || part.endsWith(".") || part.endsWith(" "))
                throw new IOException("Invalid ZIP path segment: " + raw);
            for (int i = 0; i < part.length(); i++) if (part.charAt(i) < 32 || part.charAt(i) == 127)
                throw new IOException("Control character in ZIP path.");
        }
        return name;
    }

    private static boolean supported(String name) {
        String lower = name.toLowerCase(Locale.ROOT);
        for (String segment : lower.split("/")) {
            if (segment.startsWith(".kif-") || segment.contains("runtime-smoke") || segment.startsWith("probe") || segment.startsWith("diagnostic")) return false;
        }
        return lower.endsWith(".rxdata") || lower.endsWith(".rxdata.bak") || lower.equals("keybindings.mkxp1");
    }

    private static void collect(Path root, Path current, List<Path> files, boolean onlySupported, long[] limits) throws IOException {
        noLink(current);
        if (++limits[0] > MAX_ENTRIES) throw new IOException("Save folder contains too many entries.");
        if (Files.isDirectory(current, LinkOption.NOFOLLOW_LINKS)) {
            List<Path> children = new ArrayList<>();
            try (DirectoryStream<Path> stream = Files.newDirectoryStream(current)) { for (Path child : stream) children.add(child); }
            Collections.sort(children);
            for (Path child : children) collect(root, child, files, onlySupported, limits);
        } else if (Files.isRegularFile(current, LinkOption.NOFOLLOW_LINKS)) {
            String name = safeName(relative(root, current), false);
            if (onlySupported && !supported(name)) return;
            limits[1] += Files.size(current);
            checkSizes(Files.size(current), limits[1]);
            if (files.size() >= MAX_FILES) throw new IOException("Save folder contains too many files.");
            files.add(current);
        } else throw new IOException("Unsupported object in the private save folder.");
    }

    private static void copyDurable(Path source, Path target) throws IOException {
        noLink(source);
        Files.createDirectories(target.getParent());
        try (InputStream in = Files.newInputStream(source, LinkOption.NOFOLLOW_LINKS);
             FileOutputStream out = new FileOutputStream(target.toFile())) {
            byte[] buffer = new byte[65536]; int count;
            while ((count = in.read(buffer)) != -1) out.write(buffer, 0, count);
            out.getFD().sync();
        }
    }

    private static void deleteTree(Path root) throws IOException {
        if (Files.isDirectory(root, LinkOption.NOFOLLOW_LINKS)) {
            try (DirectoryStream<Path> stream = Files.newDirectoryStream(root)) { for (Path entry : stream) deleteTree(entry); }
        }
        Files.deleteIfExists(root); // Never follows symbolic links.
    }
    private static void noLink(Path path) throws IOException {
        if (Files.isSymbolicLink(path)) throw new IOException("Symbolic links are not allowed in save transfers.");
    }
    private static Path privateFiles(Context context) throws IOException {
        Path root = context.getFilesDir().toPath().toRealPath();
        if (!Files.isDirectory(root)) throw new IOException("Private app files directory is unavailable.");
        return root;
    }
    private static String relative(Path root, Path file) { return root.relativize(file).toString().replace(File.separatorChar, '/'); }
    private static void checkSizes(long file, long total) throws IOException {
        if (file > MAX_FILE_BYTES) throw new IOException("A save file exceeds 64 MiB.");
        if (total > MAX_TOTAL_BYTES) throw new IOException("Save transfer exceeds 512 MiB uncompressed.");
    }
    private static void assertGameStopped(Context context) throws IOException {
        ActivityManager manager = (ActivityManager)context.getSystemService(Context.ACTIVITY_SERVICE);
        if (manager == null) throw new IOException("Cannot verify that the game is closed.");
        List<ActivityManager.RunningAppProcessInfo> processes = manager.getRunningAppProcesses();
        if (processes == null) throw new IOException("Cannot verify that the game is closed.");
        for (ActivityManager.RunningAppProcessInfo process : processes)
            if ((context.getPackageName() + ":game").equals(process.processName)) throw new IOException("Close the running game before transferring saves.");
    }
    private static final class LimitedInputStream extends FilterInputStream {
        private long count;
        private final long limit;
        LimitedInputStream(InputStream in, long limit) { super(in); this.limit = limit; }
        @Override public int read() throws IOException { int value = in.read(); if (value != -1) add(1); return value; }
        @Override public int read(byte[] b, int off, int len) throws IOException { int size = in.read(b, off, len); if (size > 0) add(size); return size; }
        private void add(int size) throws IOException { count += size; if (count > limit) throw new IOException("Save ZIP exceeds 256 MiB compressed."); }
    }
}
