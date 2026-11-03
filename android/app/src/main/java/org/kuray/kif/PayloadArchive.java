package org.kuray.kif;

import java.io.*;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.util.*;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

/** The actual payload restore implementation; pure Java so host tests exercise device code. */
final class PayloadArchive {
    private static final int ARCHIVE_BUFFER = 262144;
    private static final class PayloadZipStream extends ZipInputStream {
        PayloadZipStream(InputStream source) {
            super(new BufferedInputStream(source, ARCHIVE_BUFFER));
            // ZipInputStream defaults to 512-byte inflater reads. Keep its
            // pushback capacity in step when enlarging the protected buffer.
            buf = new byte[ARCHIVE_BUFFER];
            in = new PushbackInputStream(in, ARCHIVE_BUFFER);
        }
    }
    static final class Entry {
        final long size;
        final String sha256, source;
        Entry(long size, String sha256, String source) {
            this.size = size; this.sha256 = sha256; this.source = source;
        }
    }
    interface Destination { File resolve(String name) throws IOException; }
    interface Progress { void update(long bytes, long total, String path); }

    static void path(String name) throws IOException {
        if (name == null || name.isEmpty() || name.indexOf('\\') != -1 || name.indexOf(':') != -1 ||
            name.indexOf('\0') != -1 || name.startsWith("/") || name.endsWith("/"))
            throw new IOException("Unsafe payload path: " + name);
        for (String part : name.split("/", -1))
            if (part.isEmpty() || part.equals(".") || part.equals(".."))
                throw new IOException("Unsafe payload path: " + name);
    }

    static long validate(Map<String, Entry> entries) throws IOException {
        long total = 0;
        HashSet<String> folded = new HashSet<>();
        for (Map.Entry<String, Entry> item : entries.entrySet()) {
            String name = item.getKey(); path(name);
            if (!folded.add(name.toLowerCase(Locale.ROOT))) throw new IOException("Payload case collision " + name);
            Entry expected = item.getValue();
            if (expected == null || expected.size < 0 || expected.sha256 == null ||
                !expected.sha256.matches("[a-f0-9]{64}") || Long.MAX_VALUE - total < expected.size)
                throw new IOException("Invalid payload metadata " + name);
            total += expected.size;
            if (expected.source != null) {
                path(expected.source);
                Entry canonical = entries.get(expected.source);
                if (name.equals(expected.source) || canonical == null || canonical.source != null ||
                    canonical.size != expected.size || !expected.sha256.equals(canonical.sha256))
                    throw new IOException("Invalid single-hop payload alias " + name);
            }
        }
        return total;
    }

    static String hex(byte[] bytes) {
        final String digits = "0123456789abcdef";
        char[] result = new char[bytes.length * 2];
        for (int i = 0; i < bytes.length; i++) {
            int value = bytes[i] & 255;
            result[i * 2] = digits.charAt(value >>> 4);
            result[i * 2 + 1] = digits.charAt(value & 15);
        }
        return new String(result);
    }

    private static boolean matches(File file, Entry expected) throws Exception {
        if (!file.isFile() || file.length() != expected.size) return false;
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (InputStream source = new FileInputStream(file)) {
            byte[] buffer = new byte[262144]; int n;
            while ((n = source.read(buffer)) != -1) digest.update(buffer, 0, n);
        }
        return hex(digest.digest()).equals(expected.sha256);
    }

    private static void restoreOne(InputStream source, String name, Entry expected, File destination,
                                   boolean consumeVerified) throws Exception {
        boolean existing = matches(destination, expected);
        if (existing && !consumeVerified) {
            // An interruption may leave a stale partial next to an already committed copy.
            Files.deleteIfExists(new File(destination.getPath() + ".installing").toPath());
            return;
        }
        File parent = destination.getParentFile();
        if (!parent.isDirectory() && !parent.mkdirs()) throw new IOException("Cannot create " + parent);
        File pending = new File(destination.getPath() + ".installing");
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        long size = 0;
        try {
            try (FileOutputStream output = existing ? null : new FileOutputStream(pending)) {
                byte[] buffer = new byte[262144]; int n;
                while ((n = source.read(buffer)) != -1) {
                    size += n;
                    if (size > expected.size) throw new IOException("Oversized payload entry " + name);
                    digest.update(buffer, 0, n);
                    if (output != null) output.write(buffer, 0, n);
                }
                if (output != null) output.getFD().sync();
            }
            if (size != expected.size || !hex(digest.digest()).equals(expected.sha256))
                throw new IOException("Payload checksum mismatch " + name);
            if (!existing) Files.move(pending.toPath(), destination.toPath(),
                                     StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
            else Files.deleteIfExists(pending.toPath());
        } catch (Exception error) {
            if (!existing) pending.delete();
            throw error;
        }
    }

    static long restore(InputStream archive, Map<String, Entry> entries, Destination destination,
                        Progress progress) throws Exception {
        long total = validate(entries), completed = 0;
        int count = 0, canonicalCount = 0;
        for (Entry entry : entries.values()) if (entry.source == null) canonicalCount++;
        HashSet<String> seen = new HashSet<>();
        // Old manifests have no source fields and follow this same extraction path.
        try (ZipInputStream zip = new PayloadZipStream(archive)) {
            ZipEntry item;
            while ((item = zip.getNextEntry()) != null) {
                String name = item.getName();
                Entry expected = entries.get(name);
                if (item.isDirectory() || expected == null || expected.source != null || !seen.add(name))
                    throw new IOException("Unexpected or duplicate payload ZIP entry " + name);
                restoreOne(zip, name, expected, destination.resolve(name), true);
                completed += expected.size; count++;
                if (count % 32 == 0) progress.update(completed, total, name);
                zip.closeEntry();
            }
        }
        if (seen.size() != canonicalCount) throw new IOException("Incomplete canonical payload archive");
        // Restore each original path as an independent copy. Writable sprites must never share
        // an inode with another path; changing or downloading one alias cannot change another.
        for (Map.Entry<String, Entry> item : entries.entrySet()) {
            String name = item.getKey(); Entry expected = item.getValue();
            if (expected.source == null) continue;
            try (InputStream source = new FileInputStream(destination.resolve(expected.source))) {
                restoreOne(source, name, expected, destination.resolve(name), false);
            }
            completed += expected.size; count++;
            if (count % 32 == 0) progress.update(completed, total, name);
        }
        if (count != entries.size() || completed != total) throw new IOException("Incomplete restored payload");
        return completed;
    }
}
