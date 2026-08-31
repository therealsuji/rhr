package dev.rhr.rhr_connector

import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.content.Intent
import android.os.IBinder
import android.util.Log
import rikka.shizuku.Shizuku
import rikka.shizuku.Shizuku.UserServiceArgs
import java.util.concurrent.atomic.AtomicReference

/**
 * Finds the target app's Dart VM service door using Shizuku shell powers:
 * the engine always prints
 * "Dart VM Service is listening on http://127.0.0.1:<port>/<auth>/"
 * to its process log — shell can read it for ANY app, which is the whole
 * reason the connector needs Shizuku at all.
 *
 * Poll-based by design (mDNS is unreliable across networks; logcat is not):
 * bind our IShellService into the Shizuku server, then dump the target's
 * logcat buffer every ~2 s until the door line shows up.
 */
object ShellVm {
	private const val TAG = "rhr_connector"
	private val vmLineRegex =
		Regex("Dart VM [Ss]ervice.*?(http://127\\.0\\.0\\.1:\\d+/\\S+/)")

	private val shellService = AtomicReference<IShellService?>(null)

	private fun ensureService(ctx: Context): IShellService? {
		shellService.get()?.let { return it }
		if (!Shizuku.pingBinder()) return null
		val latch = Object()
		var bound = false
		val connection = object : ServiceConnection {
			override fun onServiceConnected(name: ComponentName, binder: IBinder) {
				shellService.set(IShellService.Stub.asInterface(binder))
				bound = true
				synchronized(latch) { latch.notifyAll() }
			}

			override fun onServiceDisconnected(name: ComponentName) {
				shellService.set(null)
			}
		}
		val args = UserServiceArgs(ComponentName(ctx, ShellService::class.java))
			.processNameSuffix("connector")
			.debuggable(false)
			// Bump when ShellService's code changes: Shizuku restarts the
			// user service process on a version change.
			.version(2)
		Shizuku.bindUserService(args, connection)
		synchronized(latch) {
			while (!bound) {
				try {
					latch.wait(500)
				} catch (_: InterruptedException) {}
			}
		}
		return shellService.get()
	}

	/**
	 * Blocking poll-based discovery. Returns the full VM service URI
	 * (http://127.0.0.1:<port>/<auth>/) or null when none appears within
	 * [timeoutMs]. Runs on the caller's thread (call from a worker).
	 */
	fun discoverVmUriBlocking(
		pkg: String,
		ctx: Context,
		timeoutMs: Long = 30_000L,
		onProgress: (String) -> Unit = {},
	): String? {
		val svc = ensureService(ctx)
		if (svc == null) {
			onProgress("Shizuku server is not running")
			return null
		}
		var pid: Int? = null
		val deadline = System.currentTimeMillis() + timeoutMs
		while (System.currentTimeMillis() < deadline) {
			if (pid == null) {
				val pidText = try {
					svc.pidof(pkg).trim()
				} catch (e: Exception) {
					Log.w(TAG, "pidof failed: $e"); ""
				}
				pid = pidText.split(Regex("\\s+"))
					.firstOrNull { it.isNotBlank() }?.toIntOrNull()
				if (pid == null) {
					onProgress("target not running — launching $pkg")
					ShellVm.launch(pkg, ctx)
					// The VM line prints within seconds of engine start and
					// rotates fast — poll tight right after launch.
					repeat(8) {
						Thread.sleep(700)
						try {
							val t = svc.pidof(pkg).trim()
							val p = t.split(Regex("\\s+"))
								.firstOrNull { it.isNotBlank() }?.toIntOrNull()
							if (p != null) {
								pid = p
								break
							}
						} catch (_: Exception) {}
					}
					if (pid == null) continue
					continue
				}
				onProgress("target pid $pid — reading its log")
			}
			val dump = try {
				svc.dumpLogcat(pid)
			} catch (e: Exception) {
				// The target restarted: its pid is gone, rediscover.
				onProgress("target restarted — rediscovering")
				pid = null
				Thread.sleep(1500)
				continue
			}
			vmLineRegex.find(dump)?.let {
				onProgress("VM door found")
				return it.groupValues[1]
			}
			// The log buffer rotated past the engine's startup line (the
			// target has been running for a while): restart it — a fresh
			// engine prints the VM door line immediately, and the dev's
			// kernel push replaces its Dart code right after attach.
			onProgress("no VM line in the buffer — restarting the target app")
			svc.forceStop(pkg)
			Thread.sleep(1000)
			pid = null
			continue
		}
		onProgress("no VM service line within the timeout — is $pkg a debug build?")
		return null
	}

	/** Launches the target app via its launcher intent (normal app API —
	 *  no shell needed to start another app's launcher activity). */
	fun launch(pkg: String, ctx: Context): Boolean {
		val intent = ctx.packageManager.getLaunchIntentForPackage(pkg) ?: return false
		ctx.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
		return true
	}
}
