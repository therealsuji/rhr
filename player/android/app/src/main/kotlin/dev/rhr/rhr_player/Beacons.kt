package dev.rhr.rhr_player

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.pm.ApplicationInfo
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import java.util.concurrent.ConcurrentHashMap

/**
 * VM service addresses reported by the RHR beacon inside CLI-built debug apps
 * (cli/android/rhr_beacon). The beacon replaces reading another app's log
 * over Wireless debugging, so the separate-app route needs no adb.
 */
object Beacons {
	private val latest = ConcurrentHashMap<String, String>()
	private val lock = Object()

	/** Called for every report; the run preparation uses it to follow an app
	 *  the tester reopened, whose VM listens on a new port. */
	@Volatile var onAnnounce: ((pkg: String, vm: String) -> Unit)? = null

	fun announce(pkg: String, vm: String) {
		latest[pkg] = vm
		synchronized(lock) { lock.notifyAll() }
		onAnnounce?.invoke(pkg, vm)
	}

	fun forget(pkg: String) {
		latest.remove(pkg)
	}

	/** The next address [pkg] reports, or null after [timeoutMs]. */
	fun await(pkg: String, timeoutMs: Long): String? {
		val deadline = System.currentTimeMillis() + timeoutMs
		synchronized(lock) {
			while (true) {
				latest[pkg]?.let { return it }
				val left = deadline - System.currentTimeMillis()
				if (left <= 0) return null
				lock.wait(left)
			}
		}
	}

	/** Asks a running beacon to report again. A player that restarted has
	 *  lost the address, and the app's process, still running, will not
	 *  report on its own. */
	fun requestAnnounce(context: Context, pkg: String) {
		try {
			context.contentResolver.call(Uri.parse("content://$pkg.rhrbeacon"), "announce", null, null)
		} catch (_: Exception) {
			// Not running yet, or an app built without the beacon.
		}
	}
}

/**
 * Where beacons report. Any app can call it, so a report counts only when the
 * caller is who Android says it is, is a debug build, and names a loopback VM
 * address; the run preparation then uses only the package it launched.
 */
class BeaconProvider : ContentProvider() {
	private val vmAddress = Regex("^http://127\\.0\\.0\\.1:\\d{1,5}/[A-Za-z0-9_=-]+/$")

	override fun call(method: String, arg: String?, extras: Bundle?): Bundle? {
		if (method != "vm" || arg == null || !vmAddress.matches(arg)) return null
		val context = context ?: return null
		val caller = callingPackage ?: return null
		val uidPackages = context.packageManager.getPackagesForUid(Binder.getCallingUid())
		if (uidPackages == null || caller !in uidPackages) return null
		val info = try {
			context.packageManager.getApplicationInfo(caller, 0)
		} catch (_: Exception) {
			return null
		}
		if (info.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) return null
		Beacons.announce(caller, arg)
		return null
	}

	override fun onCreate() = true
	override fun query(uri: Uri, p: Array<out String>?, s: String?, a: Array<out String>?, o: String?): Cursor? = null
	override fun getType(uri: Uri): String? = null
	override fun insert(uri: Uri, values: ContentValues?): Uri? = null
	override fun delete(uri: Uri, s: String?, a: Array<out String>?) = 0
	override fun update(uri: Uri, v: ContentValues?, s: String?, a: Array<out String>?) = 0
}
