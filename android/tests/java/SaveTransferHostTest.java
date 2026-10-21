import android.content.Context;
import android.app.ActivityManager;
import org.kuray.kif.SaveTransfer;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.zip.*;
public class SaveTransferHostTest {
    private static int checks;
    interface Operation { void run() throws Exception; }
    static void check(boolean value, String label) { if(!value) throw new AssertionError(label); checks++; }
    static void rejects(Operation op, String label) throws Exception { try { op.run(); } catch(IOException expected) { checks++; return; } throw new AssertionError("Accepted: "+label); }
    static byte[] zip(String... names) throws Exception {
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();
        try(ZipOutputStream out=new ZipOutputStream(bytes)) { for(String name:names) { out.putNextEntry(new ZipEntry(name)); out.write(("bytes:"+name).getBytes(StandardCharsets.UTF_8)); out.closeEntry(); } }
        return bytes.toByteArray();
    }
    static byte[] zeroBomb() throws Exception {
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();
        try(ZipOutputStream out=new ZipOutputStream(bytes)) { out.putNextEntry(new ZipEntry("Large.rxdata")); byte[] zeros=new byte[65536]; for(int i=0;i<1041;i++)out.write(zeros); out.closeEntry(); }
        return bytes.toByteArray();
    }
    static byte[] corrupt() throws Exception {
        byte[] data=new byte[]{1,2,3}; CRC32 crc=new CRC32();crc.update(data);
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();
        try(ZipOutputStream out=new ZipOutputStream(bytes)) { ZipEntry entry=new ZipEntry("Corrupt.rxdata");entry.setMethod(ZipEntry.STORED);entry.setSize(data.length);entry.setCompressedSize(data.length);entry.setCrc(crc.getValue());out.putNextEntry(entry);out.write(data);out.closeEntry(); }
        byte[] result=bytes.toByteArray(); int name=(result[26]&255)|((result[27]&255)<<8);int extra=(result[28]&255)|((result[29]&255)<<8); result[30+name+extra]^=1;return result;
    }
    static void remove(Path path) throws Exception { if(Files.isDirectory(path,LinkOption.NOFOLLOW_LINKS)) {try(DirectoryStream<Path> children=Files.newDirectoryStream(path)){for(Path child:children)remove(child);}} Files.deleteIfExists(path); }
    static Set<String> zipNames(byte[] bytes) throws Exception {Set<String> names=new HashSet<>();try(ZipInputStream in=new ZipInputStream(new ByteArrayInputStream(bytes))){ZipEntry e;while((e=in.getNextEntry())!=null){names.add(e.getName());in.closeEntry();}}return names;}
    public static void main(String[] args) throws Exception {
        Path base=Files.createTempDirectory(Paths.get(args[0]),"saves-");Context context=new Context(base.toFile());Path saves=Files.createDirectory(base.resolve("saves"));
        Files.write(saves.resolve("File A.rxdata"),new byte[]{4,8,1,2,3});Files.createDirectory(saves.resolve("backups"));Files.write(saves.resolve("backups/Original.rxdata.bak"),new byte[]{9});Files.write(saves.resolve("keybindings.mkxp1"),new byte[]{2});Files.write(saves.resolve("android-runtime-smoke.dat"),new byte[]{7});Files.write(saves.resolve("settings.json"),"{}".getBytes(StandardCharsets.UTF_8));
        byte[] original=Files.readAllBytes(saves.resolve("File A.rxdata"));
        class TrackedOutput extends ByteArrayOutputStream {boolean closed;public void close()throws IOException{closed=true;super.close();}}
        TrackedOutput exported=new TrackedOutput();String exportResult=SaveTransfer.exportZip(context,exported);
        check(!exported.closed,"export must leave caller stream open");check(zipNames(exported.toByteArray()).equals(new HashSet<>(Arrays.asList("File A.rxdata","backups/Original.rxdata.bak","keybindings.mkxp1"))),"export filtering and backup paths");
        class TrackedInput extends ByteArrayInputStream {boolean closed;TrackedInput(byte[] bytes){super(bytes);}public void close()throws IOException{closed=true;super.close();}}
        TrackedInput incoming=new TrackedInput(zip("File B.rxdata","backups/New.rxdata"));String importResult=SaveTransfer.importZip(context,incoming);check(!incoming.closed,"import must leave caller stream open");check(Files.exists(saves.resolve("File B.rxdata")),"new slot activated");check(Files.exists(saves.resolve("backups/New.rxdata")),"new backup activated");check(Arrays.equals(original,Files.readAllBytes(saves.resolve("File A.rxdata"))),"original save preserved");check(Files.exists(saves.resolve("settings.json"))&&Files.exists(saves.resolve("android-runtime-smoke.dat")),"existing excluded files preserved");
        rejects(()->SaveTransfer.importZip(context,new ByteArrayInputStream(zip("File D.rxdata","File A.rxdata"))),"conflict");check(!Files.exists(saves.resolve("File D.rxdata")),"conflict cannot partially activate");
        rejects(()->SaveTransfer.importZip(context,new ByteArrayInputStream(zip("file a.rxdata"))),"case-only conflict");
        for(String path:Arrays.asList("../escape.rxdata","/absolute.rxdata","C:/drive.rxdata","folder\\bad.rxdata","folder//bad.rxdata","./bad.rxdata","settings.json","probe.rxdata","android-runtime-smoke.rxdata")) rejects(()->SaveTransfer.importZip(context,new ByteArrayInputStream(zip(path))),"unsafe/unsupported "+path);
        rejects(()->SaveTransfer.importZip(context,new ByteArrayInputStream(zip("Duplicate.rxdata","duplicate.rxdata"))),"case-colliding duplicate ZIP names");
        rejects(()->SaveTransfer.importZip(context,new ByteArrayInputStream(zip("hidden/","Injected.rxdata"))),"directory entries cannot hide expanded payloads");
        rejects(()->SaveTransfer.importZip(context,new ByteArrayInputStream(corrupt())),"invalid CRC");
        rejects(()->SaveTransfer.importZip(context,new ByteArrayInputStream(zeroBomb())),"expanded 64 MiB file limit");
        rejects(()->SaveTransfer.importZip(context,new ByteArrayInputStream(new byte[]{1,2,3})),"not a ZIP");
        byte[] archive=zip("Trailing.rxdata");InputStream trailing=new SequenceInputStream(new ByteArrayInputStream(archive),new InputStream(){long remaining=SaveTransfer.MAX_ARCHIVE_BYTES;public int read(){return remaining-->0?0:-1;}public int read(byte[] b,int off,int len){if(remaining<=0)return -1;int n=(int)Math.min(remaining,len);Arrays.fill(b,off,off+n,(byte)0);remaining-=n;return n;}});rejects(()->SaveTransfer.importZip(context,trailing),"compressed input/trailing-data byte limit");
        check(!Files.exists(saves.resolve("Trailing.rxdata"))&&!Files.exists(saves.resolve("Corrupt.rxdata"))&&!Files.exists(saves.resolve("Large.rxdata")),"failed imports leave no activated files");check(!Files.exists(base.resolve(".kif-save-transfer-v1")),"failed staging cleaned");
        ActivityManager.gameRunning=true;rejects(()->SaveTransfer.importZip(context,new ByteArrayInputStream(zip("Busy.rxdata"))),"running-game import guard");rejects(()->SaveTransfer.exportZip(context,new ByteArrayOutputStream()),"running-game export guard");ActivityManager.gameRunning=false;
        Path work=Files.createDirectory(base.resolve(".kif-save-transfer-v1"));Files.write(work.resolve("owner"),"KIF_PRIVATE_SAVE_TRANSFER_V1\n".getBytes(StandardCharsets.UTF_8));Files.move(saves,work.resolve("previous"),StandardCopyOption.ATOMIC_MOVE);SaveTransfer.recoverIfNeeded(context);check(Files.exists(saves.resolve("File A.rxdata")),"interrupted activation restores previous save tree");check(!Files.exists(work),"recovery cleans only owned stage");
        Files.createDirectory(work);Files.write(work.resolve("owner"),"KIF_PRIVATE_SAVE_TRANSFER_V1\n".getBytes(StandardCharsets.UTF_8));Files.createDirectory(work.resolve("previous"));Files.write(work.resolve("previous/Old.rxdata"),new byte[]{1});SaveTransfer.recoverIfNeeded(context);check(Files.exists(saves.resolve("File B.rxdata"))&&!Files.exists(work),"completed activation recovery keeps new active saves");
        check(Arrays.equals(original,Files.readAllBytes(saves.resolve("File A.rxdata"))),"original unchanged after all rejection and recovery tests");
        System.out.println(exportResult);System.out.println(importResult);System.out.println("PASS "+checks+" assertions (host ZIP/filesystem tests; Android SAF not exercised)");remove(base);
    }
}
