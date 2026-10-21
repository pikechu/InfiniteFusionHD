package android.content;
import java.io.File;
import android.app.ActivityManager;
public class Context {
    public static final String ACTIVITY_SERVICE = "activity";
    private final File files;
    public Context(File files) { this.files = files; }
    public File getFilesDir() { return files; }
    public String getPackageName() { return "org.kuray.kif"; }
    public Object getSystemService(String name) { return new ActivityManager(); }
}
