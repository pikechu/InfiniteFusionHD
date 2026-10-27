package org.kuray.kif;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;
import java.util.zip.*;

public final class PayloadArchiveHostTest {
    private static int checks;
    private static Path base;
    interface Operation { void run() throws Exception; }
    static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message); checks++;
    }
    static void rejects(Operation operation, String message) throws Exception {
        try { operation.run(); } catch (IOException expected) { checks++; return; }
        throw new AssertionError("Accepted " + message);
    }
    static byte[] bytes(String value) { return value.getBytes(StandardCharsets.UTF_8); }
    static String sha(byte[] value) throws Exception {
        StringBuilder result = new StringBuilder();
        for (byte b : MessageDigest.getInstance("SHA-256").digest(value))
            result.append(String.format(Locale.ROOT, "%02x", b & 255));
        return result.toString();
    }
    static PayloadArchive.Entry entry(byte[] value, String source) throws Exception {
        return new PayloadArchive.Entry(value.length, sha(value), source);
    }
    static Map<String, PayloadArchive.Entry> manifest(byte[] value) throws Exception {
        Map<String, PayloadArchive.Entry> result = new LinkedHashMap<>();
        result.put("Audio/source.bin", entry(value, null));
        result.put("Audio/alias.bin", entry(value, "Audio/source.bin"));
        result.put("Graphics/sub/alias.bin", entry(value, "Audio/source.bin"));
        return result;
    }
    static byte[] zip(String[] names, byte[][] values) throws Exception {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        try (ZipOutputStream zip = new ZipOutputStream(bytes)) {
            for (int i = 0; i < names.length; i++) {
                zip.putNextEntry(new ZipEntry(names[i])); zip.write(values[i]); zip.closeEntry();
            }
        }
        return bytes.toByteArray();
    }
    static Path directory(String name) throws Exception { return Files.createDirectory(base.resolve(name)); }
    static final class CountedInput extends FilterInputStream {
        int reads;
        CountedInput(byte[] data) { super(new ByteArrayInputStream(data)); }
        @Override public int read() throws IOException { reads++; return in.read(); }
        @Override public int read(byte[] data, int offset, int length) throws IOException {
            reads++; return in.read(data, offset, length);
        }
    }
    static long restore(byte[] archive, Map<String, PayloadArchive.Entry> entries, Path root) throws Exception {
        return PayloadArchive.restore(new ByteArrayInputStream(archive), entries,
            name -> {
                Path destination = root.resolve(name).normalize();
                if (!destination.startsWith(root)) throw new IOException("Unsafe fixture destination");
                return destination.toFile();
            }, (done, total, path) -> { if (done > total) throw new AssertionError("Invalid progress"); });
    }
    public static void main(String[] args) throws Exception {
        Path approved = Paths.get(args[0]).toAbsolutePath().normalize();
        Files.createDirectories(approved);
        base = Files.createTempDirectory(approved, "payload-").toAbsolutePath().normalize();
        if (!base.startsWith(approved)) throw new IOException("Fixture escaped approved temp root");
        byte[] allBytes = new byte[256]; StringBuilder expectedHex = new StringBuilder();
        for (int i = 0; i < 256; i++) { allBytes[i] = (byte)i; expectedHex.append(String.format(Locale.ROOT,"%02x",i)); }
        check(PayloadArchive.hex(allBytes).equals(expectedHex.toString()) && PayloadArchive.hex(new byte[0]).equals(""),
              "allocation-bounded digest encoding preserves all byte values and leading zeroes");
        byte[] original = bytes("Actual audio/image bytes: \u2603\n");
        byte[] archive = zip(new String[]{"Audio/source.bin"}, new byte[][]{original});
        Map<String, PayloadArchive.Entry> entries = manifest(original);
        Path first = directory("fresh");
        check(restore(archive, entries, first) == original.length * 3L, "logical progress includes aliases");
        for (String name : entries.keySet())
            check(Arrays.equals(original, Files.readAllBytes(first.resolve(name))), "restored bytes " + name);
        check(!Files.isSameFile(first.resolve("Audio/source.bin"), first.resolve("Graphics/sub/alias.bin")),
              "aliases must be independent files, never hardlinks");
        Files.write(first.resolve("Graphics/sub/alias.bin"), bytes("downloaded replacement"));
        check(Arrays.equals(original, Files.readAllBytes(first.resolve("Audio/source.bin"))),
              "writing a sprite alias preserves canonical content");
        check(Arrays.equals(original, Files.readAllBytes(first.resolve("Audio/alias.bin"))),
              "writing a sprite alias preserves other aliases");
        restore(archive, entries, first);
        check(Arrays.equals(original, Files.readAllBytes(first.resolve("Graphics/sub/alias.bin"))),
              "interrupted install repairs an existing incorrect alias");
        Files.write(first.resolve("Audio/source.bin"), bytes("corrupt"));
        Files.write(first.resolve("Audio/alias.bin.installing"), bytes("interrupted copy"));
        restore(archive, entries, first);
        check(Arrays.equals(original, Files.readAllBytes(first.resolve("Audio/source.bin"))),
              "resume repairs canonical data");
        check(Arrays.equals(original, Files.readAllBytes(first.resolve("Audio/alias.bin"))),
              "resume preserves an already verified alias");
        check(!Files.exists(first.resolve("Audio/alias.bin.installing")), "resume removes owned stale alias partial");
        check(restore(archive, entries, first) == original.length * 3L, "repeat restoration succeeds");

        Map<String, PayloadArchive.Entry> old = new LinkedHashMap<>();
        old.put("Game.ini", entry(original, null)); old.put("Data/example.dat", entry(original, null));
        Path legacy = directory("legacy");
        byte[] oldZip = zip(new String[]{"Game.ini", "Data/example.dat"}, new byte[][]{original, original});
        check(restore(oldZip, old, legacy) == original.length * 2L, "old manifests without aliases remain supported");
        check(Arrays.equals(original, Files.readAllBytes(legacy.resolve("Data/example.dat"))), "legacy bytes intact");

        Map<String, PayloadArchive.Entry> bad = manifest(original);
        bad.put("Audio/alias.bin", entry(original, "missing.bin"));
        rejects(() -> restore(archive, bad, directory("missing-source")), "missing alias source");
        Map<String, PayloadArchive.Entry> chain = manifest(original);
        chain.put("Graphics/sub/alias.bin", entry(original, "Audio/alias.bin"));
        rejects(() -> restore(archive, chain, directory("chain")), "alias chain");
        Map<String, PayloadArchive.Entry> self = manifest(original);
        self.put("Audio/alias.bin", entry(original, "Audio/alias.bin"));
        rejects(() -> restore(archive, self, directory("self")), "self alias");
        Map<String, PayloadArchive.Entry> mismatch = manifest(original);
        mismatch.put("Audio/alias.bin", entry(bytes("different"), "Audio/source.bin"));
        rejects(() -> restore(archive, mismatch, directory("metadata-mismatch")), "alias size/hash mismatch");
        for (String name : Arrays.asList("../escape", "/absolute", "C:/drive", "folder\\windows", "a//b", "./x", "x/../y")) {
            Map<String, PayloadArchive.Entry> traversal = new LinkedHashMap<>();
            traversal.put(name, entry(original, null));
            rejects(() -> restore(archive, traversal, directory("unsafe-" + checks)), "unsafe path " + name);
        }
        Map<String, PayloadArchive.Entry> collision = manifest(original);
        collision.put("audio/SOURCE.bin", entry(original, null));
        rejects(() -> restore(archive, collision, directory("case")), "case collision");
        byte[] wrong = Arrays.copyOf(original, original.length); wrong[0] ^= 1;
        byte[] corrupt = zip(new String[]{"Audio/source.bin"}, new byte[][]{wrong});
        rejects(() -> restore(corrupt, entries, directory("bad-hash")), "archive corruption");
        // Even when a correct installed copy exists, consume and verify the bounded ZIP entry.
        rejects(() -> restore(corrupt, entries, first), "corrupt archive with an already verified destination");
        byte[] large = Arrays.copyOf(original, original.length + 1);
        byte[] oversize = zip(new String[]{"Audio/source.bin"}, new byte[][]{large});
        rejects(() -> restore(oversize, entries, directory("oversize")), "oversized ZIP entry");
        byte[] empty = zip(new String[]{}, new byte[][]{});
        rejects(() -> restore(empty, entries, directory("missing")), "missing canonical ZIP member");
        byte[] aliasZip = zip(new String[]{"Audio/source.bin", "Audio/alias.bin"}, new byte[][]{original, original});
        rejects(() -> restore(aliasZip, entries, directory("alias-in-zip")), "alias must not be stored twice");
        byte[] extraZip = zip(new String[]{"Audio/source.bin", "unknown.bin"}, new byte[][]{original, original});
        rejects(() -> restore(extraZip, entries, directory("extra")), "unlisted ZIP member");
        byte[] duplicate = zip(new String[]{"Audio/source.bin", "Audio/second.bin"}, new byte[][]{original, original});
        byte[] from = bytes("Audio/second.bin"), to = bytes("Audio/source.bin");
        for (int index = 0; index <= duplicate.length - from.length; index++) {
            boolean same = true;
            for (int j = 0; j < from.length; j++) same &= duplicate[index + j] == from[j];
            if (same) System.arraycopy(to, 0, duplicate, index, to.length);
        }
        rejects(() -> restore(duplicate, entries, directory("duplicate")), "duplicate canonical ZIP member");
        check(!Files.exists(base.resolve("escape")), "path validation never creates outside destination");
        byte[] noise = new byte[1024 * 1024]; new Random(7).nextBytes(noise);
        byte[] tail = bytes("entry boundary after incompressible data");
        Map<String, PayloadArchive.Entry> bulk = new LinkedHashMap<>();
        bulk.put("one.bin", entry(noise,null)); bulk.put("tail.bin", entry(tail,null)); bulk.put("two.bin", entry(noise,null));
        CountedInput counted = new CountedInput(zip(new String[]{"one.bin","tail.bin","two.bin"}, new byte[][]{noise,tail,noise}));
        Path buffered = directory("buffered");
        check(PayloadArchive.restore(counted,bulk,name -> buffered.resolve(name).toFile(),(a,b,c) -> {}) == noise.length*2L+tail.length,
              "large buffers preserve adjacent ZIP entry boundaries and hashes");
        check(Arrays.equals(Files.readAllBytes(buffered.resolve("two.bin")),noise), "pushback preserves following large entry");
        check(counted.reads < 128, "payload restore avoids thousands of 512-byte asset JNI reads");
        System.out.println("PAYLOAD_SOURCE_READS=" + counted.reads);
        System.out.println("PASS " + checks + " assertions (production PayloadArchive restore; host filesystem)");
        System.out.println("Fixture evidence retained: " + base);
    }
}
