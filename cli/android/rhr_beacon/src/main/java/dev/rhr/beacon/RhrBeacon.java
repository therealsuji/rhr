package dev.rhr.beacon;

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
import android.os.Bundle;
import android.os.Process;

import java.io.BufferedReader;
import java.io.InputStreamReader;
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

    /** The player asks again after it restarts and has lost the address. */
    @Override
    public Bundle call(String method, String arg, Bundle extras) {
        final String vm = latest;
        final Context context = getContext();
        if ("announce".equals(method) && vm != null && context != null) {
            new Thread(() -> announce(context.getApplicationContext(), vm), "rhr-beacon").start();
        }
        return null;
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
