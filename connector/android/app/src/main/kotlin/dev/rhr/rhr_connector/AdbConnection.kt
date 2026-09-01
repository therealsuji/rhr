package dev.rhr.rhr_connector

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings
import android.util.Log
import android.content.SharedPreferences
import androidx.core.content.edit
import moe.shizuku.manager.adb.AdbClient
import moe.shizuku.manager.adb.AdbKey
import moe.shizuku.manager.adb.PreferenceAdbKeyStore
import moe.shizuku.manager.adb.AdbMdns
import moe.shizuku.manager.adb.AdbPairingClient
import android.os.Handler
import android.os.Looper

/**
 * Embedded wireless-debugging ADB client (vendored from Shizuku,
 * Apache-2.0). Pairs with THIS phone's own adbd over loopback — no
 * second app, no Shizuku manager, works on any network (pairing and
 * shell never leave the device; only the relay leg uses the internet).
 *
 * Flow:
 *   1. startPairing      — deep-links the user to Wireless debugging and
 *                          discovers the rotating PAIRING port (mDNS,
 *                          announced by the system adbd — registered with
 *                          the phone's own mDNS daemon, so on-device
 *                          NsdManager sees it even when the Wi-Fi
 *                          suppresses multicast).
 *   2. pair(code)        — SPAKE2+ pairing with the 6-digit code; the
 *                          connector's key is trusted by adbd permanently.
 *   3. ensureConnected   — discovers the rotating CONNECT port, connects
 *                          with the stored key; shell streams then run.
 */
object AdbConnection {
	const val TAG = "rhr_connector"
	private const val KEY_NAME = "rhr_connector"
	private const val PREFS = "rhr_adb"
	private const val PAIRING_SERVICE = "_adb-tls-pairing._tcp."
	private const val CONNECT_SERVICE = "_adb-tls-connect._tcp."

	private var key: AdbKey? = null
	private var client: AdbClient? = null

	private fun prefs(ctx: Context): SharedPreferences =
		ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

	/** The connector has completed pairing at least once. */
	fun paired(ctx: Context): Boolean =
		prefs(ctx).getBoolean("paired", false)

	/** An ADB connection is currently open (shell commands available). */
	fun connected(ctx: Context): Boolean = try {
		client != null && shell(ctx, "echo ok") == "ok"
	} catch (_: Exception) {
		false
	}

	private fun adbKey(ctx: Context): AdbKey {
		key?.let { return it }
		val k = AdbKey(PreferenceAdbKeyStore(prefs(ctx)), KEY_NAME)
		key = k
		return k
	}

	/** Deep-links the user to the Wireless debugging screen. */
	fun openWirelessDebugging(ctx: Context) {
		ctx.startActivity(Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
			.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
	}

	/**
	 * Discovers the rotating pairing port via mDNS (the system adbd
	 * announces `_adb-tls-pairing._tcp` on-device — visible to local
	 * NsdManager queries even when the Wi-Fi suppresses multicast,
	 * because the announcement lives in the phone's own mDNS daemon).
	 * Delivers the port, or -1 when not found in time.
	 */
	fun discoverPairingPort(ctx: Context, timeoutMs: Long, onPort: (Int) -> Unit) {
		discoverPort(ctx, PAIRING_SERVICE, timeoutMs, onPort)
	}

	fun discoverConnectPort(ctx: Context, timeoutMs: Long, onPort: (Int) -> Unit) {
		discoverPort(ctx, CONNECT_SERVICE, timeoutMs, onPort)
	}

	private fun discoverPort(
		ctx: Context, serviceType: String, timeoutMs: Long, onPort: (Int) -> Unit,
	) {
		val mdns = AdbMdns(ctx, serviceType) { port -> onPort(port) }
		mdns.start()
		Handler(ctx.mainLooper).postDelayed({
			mdns.stop()
			onPort(-1)
		}, timeoutMs)
	}

	/** SPAKE2+ pairing against the phone's own adbd pairing port. */
	fun pair(ctx: Context, host: String, port: Int, code: String): Boolean {
		val ok = AdbPairingClient(host, port, code, adbKey(ctx)).start()
		if (ok) {
			prefs(ctx).edit { putBoolean("paired", true) }
		}
		return ok
	}

	/** Opens (or reuses) the ADB connection. Blocking. */
	fun ensureConnected(ctx: Context): Boolean {
		if (connected(ctx)) return true
		if (!paired(ctx)) return false
		var port = -1
		discoverConnectPort(ctx, 8000) { p -> port = p }
		if (port <= 0) return false
		val c = AdbClient("127.0.0.1", port, adbKey(ctx))
		c.connect()
		client = c
		return true
	}

	/** Runs one shell command over the ADB connection. Blocking. */
	fun shell(ctx: Context, command: String): String {
		ensureConnected(ctx)
		val c = client ?: throw IllegalStateException("adb not connected")
		val out = StringBuilder()
		c.shellCommand(command) { bytes -> out.append(String(bytes)) }
		return out.toString().trim()
	}
}
