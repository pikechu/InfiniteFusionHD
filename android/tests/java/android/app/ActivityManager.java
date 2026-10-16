package android.app;
import java.util.*;
public class ActivityManager {
    public static boolean gameRunning;
    public static class RunningAppProcessInfo { public String processName; }
    public List<RunningAppProcessInfo> getRunningAppProcesses() {
        List<RunningAppProcessInfo> result = new ArrayList<>();
        if (gameRunning) { RunningAppProcessInfo p = new RunningAppProcessInfo(); p.processName="org.kuray.kif:game"; result.add(p); }
        return result;
    }
}
