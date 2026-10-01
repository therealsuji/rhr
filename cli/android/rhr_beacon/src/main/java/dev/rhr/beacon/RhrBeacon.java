package dev.rhr.beacon;

import android.app.ActivityManager;
import android.app.ApplicationExitInfo;
import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.ProviderInfo;
import android.content.pm.Signature;
import android.database.Cursor;
import android.net.Uri;
import android.os.Build;
import android.os.Binder;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.os.Process;

import java.io.BufferedReader;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Tells RHR Player where this debug app's Dart VM service is listening.
 *
 * The engine prints that address, with its secret token, only to this app's
 * own log, and only this process may read that log without adb. The CLI adds
 * this provider to the debug build it generates (never to the project, never
 * to a release build). It starts with the process, watches the log, and hands
 * the address to the player, which tunnels the VM service to the developer.
 *
 * The address is a credential, so it goes only to a player whose signing
 * certificate matches the one the CLI baked into this build.
 *
 * The same player may also ask for this app's native log, for the developer's
 * agent: only this app can read it without adb.
 */
public final class RhrBeacon extends ContentProvider {
    private static final Pattern VM_LINE =
            Pattern.compile("Dart VM [Ss]ervice.*?(http://127\\.0\\.0\\.1:\\d+/\\S+/)");

    private static volatile String latest;

    @Override
    public boolean onCreate() {
        final Context context = getContext().getApplicationContext();
        Thread watcher = new Thread(() -> watch(context), "rhr-beacon");
        watcher.setDaemon(true);
        watcher.start();
        return true;
    }

    /**
     * "announce": the player asks again after it restarts and has lost the
     * address. "logs": the player asks for this app's log stream.
     */
    @Override
    public Bundle call(String method, String arg, Bundle extras) {
        final String vm = latest;
        final Context context = getContext();
        if (context == null) return null;
        if ("announce".equals(method) && vm != null) {
            new Thread(() -> announce(context.getApplicationContext(), vm), "rhr-beacon").start();
        }
        if ("logs".equals(method)) return logs(context);
        return null;
    }

    /**
     * One end of a socket pair that carries this app's log as logcat text
     * lines. The player writes one byte once it holds its own copy of the end
     * it was handed; only then is the copy here closed, so the player hanging
     * up is what ends the stream.
     */
    private static Bundle logs(Context context) {
        if (!callerIsPlayer(context)) {
            throw new SecurityException("Only the RHR player this app was built for reads its log.");
        }
        final ParcelFileDescriptor ours;
        final ParcelFileDescriptor theirs;
        try {
            ParcelFileDescriptor[] pair = ParcelFileDescriptor.createSocketPair();
            ours = pair[0];
            theirs = pair[1];
        } catch (Exception e) {
            return null;
        }
        new Thread(() -> streamLogs(context.getApplicationContext(), ours, theirs), "rhr-beacon-logs").start();
        Bundle answer = new Bundle();
        answer.putParcelable("socket", theirs);
        return answer;
    }

    private static void streamLogs(Context context, ParcelFileDescriptor ours, ParcelFileDescriptor theirs) {
        java.lang.Process logcat = null;
        try (ParcelFileDescriptor socket = ours) {
            new FileInputStream(socket.getFileDescriptor()).read();
            theirs.close();
            OutputStream out = new FileOutputStream(socket.getFileDescriptor());
            out.write(lastExit(context).getBytes(StandardCharsets.UTF_8));
            // Without adb, logcat shows only this app's own lines, from every
            // process it has run, so the recent tail still holds the stack
            // trace of a crash that killed the previous process.
            logcat = new ProcessBuilder("logcat", "-v", "threadtime", "-T", "500")
                    .redirectErrorStream(true)
                    .start();
            InputStream lines = logcat.getInputStream();
            byte[] buffer = new byte[16 * 1024];
            int read;
            while ((read = lines.read(buffer)) != -1) out.write(buffer, 0, read);
        } catch (Exception ignored) {
            // The player hung up.
        } finally {
            if (logcat != null) logcat.destroy();
            try {
                theirs.close();
            } catch (Exception ignored) {
            }
        }
    }

    /** Why this app's previous process ended, as one log-like line. */
    private static String lastExit(Context context) {
        if (Build.VERSION.SDK_INT < 30) return "";
        ActivityManager activities = context.getSystemService(ActivityManager.class);
        java.util.List<ApplicationExitInfo> exits =
                activities.getHistoricalProcessExitReasons(context.getPackageName(), 0, 1);
        if (exits.isEmpty()) return "";
        ApplicationExitInfo exit = exits.get(0);
        return "rhr-exit time=" + exit.getTimestamp()
                + " pid=" + exit.getPid()
                + " reason=" + reasonName(exit.getReason())
                + " status=" + exit.getStatus()
                + " description=" + exit.getDescription() + "\n";
    }

    private static String reasonName(int reason) {
        switch (reason) {
            case ApplicationExitInfo.REASON_CRASH: return "crash";
            case ApplicationExitInfo.REASON_CRASH_NATIVE: return "native_crash";
            case ApplicationExitInfo.REASON_ANR: return "anr";
            case ApplicationExitInfo.REASON_LOW_MEMORY: return "low_memory";
            case ApplicationExitInfo.REASON_EXIT_SELF: return "exit_self";
            case ApplicationExitInfo.REASON_SIGNALED: return "signaled";
            case ApplicationExitInfo.REASON_USER_REQUESTED: return "user_requested";
            case ApplicationExitInfo.REASON_PERMISSION_CHANGE: return "permission_change";
            case ApplicationExitInfo.REASON_DEPENDENCY_DIED: return "dependency_died";
            case ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE: return "excessive_resource_usage";
            default: return String.valueOf(reason);
        }
    }

    private static boolean callerIsPlayer(Context context) {
        try {
            Bundle meta = context.getPackageManager()
                    .getApplicationInfo(context.getPackageName(), PackageManager.GET_META_DATA)
                    .metaData;
            String player = meta.getString("dev.rhr.beacon.player");
            String certificate = meta.getString("dev.rhr.beacon.playerCertificate");
            if (player == null || certificate == null) return false;
            PackageManager packages = context.getPackageManager();
            String[] callers = packages.getPackagesForUid(Binder.getCallingUid());
            if (callers == null) return false;
            for (String caller : callers) {
                if (caller.equals(player)) return signedBy(packages, player, certificate);
            }
        } catch (Exception ignored) {
        }
        return false;
    }

    private static void watch(Context context) {
        try {
            // No -d: dump what is already buffered, then keep following, so a
            // line printed before this thread started is still seen.
            java.lang.Process logcat = new ProcessBuilder(
                    "logcat", "--pid=" + Process.myPid(), "-v", "brief", "-s", "flutter:I")
                    .redirectErrorStream(true)
                    .start();
            BufferedReader lines = new BufferedReader(new InputStreamReader(logcat.getInputStream()));
            String line;
            while ((line = lines.readLine()) != null) {
                Matcher match = VM_LINE.matcher(line);
                if (match.find()) {
                    latest = match.group(1);
                    announce(context, latest);
                }
            }
        } catch (Exception ignored) {
            // No log access means no tunnel; the app itself runs normally.
        }
    }

    private static void announce(Context context, String vm) {
        String player;
        String certificate;
        try {
            Bundle meta = context.getPackageManager()
                    .getApplicationInfo(context.getPackageName(), PackageManager.GET_META_DATA)
                    .metaData;
            player = meta.getString("dev.rhr.beacon.player");
            certificate = meta.getString("dev.rhr.beacon.playerCertificate");
        } catch (Exception e) {
            return;
        }
        if (player == null || certificate == null) return;
        String authority = player + ".beacon";
        // The player may still be starting; the address is worth a few tries.
        for (int attempt = 0; attempt < 30; attempt++) {
            try {
                PackageManager packages = context.getPackageManager();
                ProviderInfo provider = packages.resolveContentProvider(authority, 0);
                if (provider != null && provider.packageName.equals(player)
                        && signedBy(packages, player, certificate)) {
                    context.getContentResolver().call(Uri.parse("content://" + authority), "vm", vm, null);
                    return;
                }
            } catch (Exception ignored) {
            }
            try {
                Thread.sleep(1000);
            } catch (InterruptedException e) {
                return;
            }
        }
    }

    private static boolean signedBy(PackageManager packages, String pkg, String sha256Hex)
            throws Exception {
        byte[] expected = new byte[sha256Hex.length() / 2];
        for (int i = 0; i < expected.length; i++) {
            expected[i] = (byte) Integer.parseInt(sha256Hex.substring(i * 2, i * 2 + 2), 16);
        }
        if (Build.VERSION.SDK_INT >= 28) {
            return packages.hasSigningCertificate(pkg, expected, PackageManager.CERT_INPUT_SHA256);
        }
        @SuppressWarnings("deprecation")
        PackageInfo info = packages.getPackageInfo(pkg, PackageManager.GET_SIGNATURES);
        @SuppressWarnings("deprecation")
        Signature[] signatures = info.signatures;
        if (signatures == null || signatures.length != 1) return false;
        return MessageDigest.isEqual(
                MessageDigest.getInstance("SHA-256").digest(signatures[0].toByteArray()), expected);
    }

    @Override
    public Cursor query(Uri uri, String[] projection, String selection, String[] args, String sort) {
        return null;
    }

    @Override
    public String getType(Uri uri) {
        return null;
    }

    @Override
    public Uri insert(Uri uri, ContentValues values) {
        return null;
    }

    @Override
    public int delete(Uri uri, String selection, String[] args) {
        return 0;
    }

    @Override
    public int update(Uri uri, ContentValues values, String selection, String[] args) {
        return 0;
    }
}
