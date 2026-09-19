package dev.rhr.adb

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.core.content.edit
import moe.shizuku.manager.adb.AdbClient
import moe.shizuku.manager.adb.AdbKey
import moe.shizuku.manager.adb.AdbMdns
import moe.shizuku.manager.adb.AdbPairingClient
import moe.shizuku.manager.adb.PreferenceAdbKeyStore
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Embedded wireless-debugging ADB client (vendored from Shizuku,
 * Apache-2.0). Pairs with THIS phone's own adbd over loopback — no
 * second app, no Shizuku manager, works on any network (pairing and
 * shell never leave the device; only the relay leg uses the internet).
 *
 * Pairing is a ONE-TIME setup step: the SPAKE2 handshake (6-digit code)
 * puts the connector's public key into adbd's trusted-keys list, where
 * it survives reboots, network changes and wireless-debugging toggles.
 * Everything after it is silent — [ensureConnected] discovers the
 * rotating connect port (mDNS) and authenticates with the stored key.
 * No user interaction, ever again.
 *
 * Flow:
 *   1. pair(code)       — ONE-TIME. SPAKE2+ against the pairing port;
 *                         the key trust is permanent after this.
 *   2. ensureConnected  — every launch. Discovers the rotating CONNECT
 *                         port, connects with the stored key.
 *   3. shell            — one command over the connection; auto-heals
 *                         one dead connection per call.
 *
 * All functions block and must be called OFF the main thread.
 */
object AdbConnection {
	const val TAG = "rhr_adb"
	// Both names are ON-DISK/ON-DEVICE identities, not cosmetics. KEY_NAME is
	// the label baked into the RSA key adbd trusts — it is what the phone
	// shows in its paired-devices list — and PREFS is the SharedPreferences
	// file holding it. Renaming either orphans an existing pairing and forces
	// the user to pair again.
	private const val KEY_NAME = "rhr_player"
	private const val PREFS = "rhr_adb"
	private const val PAIRING_SERVICE = "_adb-tls-pairing._tcp."
	private const val CONNECT_SERVICE = "_adb-tls-connect._tcp."
	private const val DISCOVERY_TIMEOUT_MS = 8_000L

	private var key: AdbKey? = null
	private var client: AdbClient? = null

	private fun prefs(ctx: Context): SharedPreferences =
		ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

	/** The connector completed the one-time pairing at least once. */
	fun paired(ctx: Context): Boolean =
		prefs(ctx).getBoolean("paired", false)

	/** Marks the one-time pairing as done (after a successful SPAKE2). */
	fun markPaired(ctx: Context) {
		prefs(ctx).edit { putBoolean("paired", true) }
	}

	/** Liveness of the CURRENT connection — a real roundtrip, but no
	 *  reconnect attempts (that is [ensureConnected]'s job). */
	fun connected(ctx: Context): Boolean = try {
		val c = client ?: return false
		shellOn(c, "echo ok") == "ok"
	} catch (_: Exception) {
		false
	}

	@Synchronized
	fun adbKey(ctx: Context): AdbKey {
		key?.let { return it }
		val k = AdbKey(PreferenceAdbKeyStore(prefs(ctx)), KEY_NAME)
		key = k
		return k
	}

	/**
	 * This phone's Wi-Fi/LAN IPv4 address — the pairing fallback when
	 * adbd's pairing port is not reachable on loopback. Null when none.
	 */
	fun lanAddress(): String? = runCatching {
		NetworkInterface.getNetworkInterfaces().asSequence()
			.filter { it.isUp && !it.isLoopback }
			.flatMap { it.inetAddresses.asSequence() }
			.filterIsInstance<Inet4Address>()
			.firstOrNull { !it.isLoopbackAddress }
			?.hostAddress
	}.getOrNull()

	/**
	 * ONE-TIME pairing: SPAKE2+ against the phone's own adbd pairing
	 * port (alive only while the system pairing dialog is open). On
	 * success the key trust is permanent — this never runs again.
	 */
	fun pair(ctx: Context, host: String, port: Int, code: String): Boolean {
		val ok = AdbPairingClient(host, port, code, adbKey(ctx)).start()
		if (ok) markPaired(ctx)
		return ok
	}

	/**
	 * Opens (or reuses) the ADB connection. Discovers the rotating
	 * connect port via on-device mDNS (the phone hears its own adbd
	 * announcement even on Wi-Fi that suppresses multicast, because the
	 * announcement lives in the phone's own mDNS daemon), then
	 * authenticates with the stored key. Blocking; off the main thread.
	 */
	@Synchronized
	fun ensureConnected(ctx: Context): Boolean {
		if (connected(ctx)) return true
		if (!paired(ctx)) return false
		closeClient()
		val port = discoverPortBlocking(ctx, CONNECT_SERVICE)
		if (port <= 0) {
			Log.w(TAG, "no connect port discovered (wireless debugging off?)")
			return false
		}
		return try {
			val c = AdbClient("127.0.0.1", port, adbKey(ctx))
			c.connect()
			client = c
			Log.d(TAG, "adb connected on connect port $port")
			true
		} catch (e: Exception) {
			Log.w(TAG, "adb connect failed: $e")
			false
		}
	}

	/**
	 * Runs one shell command over the ADB connection. If the connection
	 * died since the last command (adbd restart, wireless-debugging
	 * toggle), reconnects once before failing.
	 */
	@Synchronized
	fun shell(ctx: Context, command: String): String {
		if (client == null && !ensureConnected(ctx)) {
			throw IllegalStateException("adb not connected")
		}
		return try {
			shellOn(client!!, command)
		} catch (e: Exception) {
			closeClient()
			if (!ensureConnected(ctx)) throw e
			shellOn(client!!, command)
		}
	}

	private fun shellOn(c: AdbClient, command: String): String {
		val out = StringBuilder()
		c.shellCommand(command) { bytes -> out.append(String(bytes)) }
		return out.toString().trim()
	}

	private fun closeClient() {
		client?.let { runCatching { it.close() } }
		client = null
	}

	/**
	 * BLOCKING mDNS discovery of adbd's port for [serviceType]. (The
	 * async check-after-start version of this was the bug that made
	 * every connect fail: the port check ran before any callback could.)
	 */
	private fun discoverPortBlocking(ctx: Context, serviceType: String): Int {
		val latch = CountDownLatch(1)
		var port = -1
		val mdns = AdbMdns(ctx, serviceType) { p ->
			if (p > 0 && port == -1) {
				port = p
				latch.countDown()
			}
		}
		mdns.start()
		try {
			return if (latch.await(DISCOVERY_TIMEOUT_MS, TimeUnit.MILLISECONDS)) port else -1
		} finally {
			runCatching { mdns.stop() }
		}
	}
}
