package dev.rhr.rhr_connector

import android.content.Context
import android.util.Log
import android.content.Intent
import dev.rhr.rhr_connector.AdbConnection

/**
 * Finds the target app's Dart VM service door using the embedded ADB
 * connection (wireless debugging, paired in-app): the engine always prints
 * "Dart VM Service is listening on http://127.0.0.1:<port>/<auth>/" to its
 * own log — shell can read it for ANY app.
 *
 * Launch discipline (the old loop killed the target every ~2s):
 *   - `logcat -G` clears the buffer, so a RUNNING app's startup line is
 *     usually unrecoverable → restart it ONCE for a fresh line.
 *   - After that, never force-stop on a timing hunch: the engine prints
 *     the door line when it's ready — poll the buffer for it until the
 *     deadline, relaunching only if the process actually died.
 */
object ShellVm {
	private const val TAG = "rhr_connector"
	private val vmLineRegex =
		Regex("Dart VM [Ss]ervice.*?(http://127\\.0\\.0\\.1:\\d+/\\S+/)")

	private fun shell(ctx: Context, command: String): String =
		AdbConnection.shell(ctx, command)

	fun launch(pkg: String, ctx: Context): Boolean {
		val intent = ctx.packageManager.getLaunchIntentForPackage(pkg) ?: return false
		ctx.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
		return true
	}

	fun discoverVmUriBlocking(
		pkg: String,
		ctx: Context,
		timeoutMs: Long = 45_000L,
		onProgress: (String) -> Unit = {},
	): String? {
		try {
			onProgress("enlarging the log buffer")
			// NOTE: changing the buffer size CLEARS it — any VM line the
			// running app already printed is gone after this.
			shell(ctx, "logcat -G 16M")

			fun pidOf(): Int? = shell(ctx, "pidof $pkg")
				.split(Regex("\\s+"))
				.firstOrNull { it.isNotBlank() }?.toIntOrNull()

			fun vmLine(pid: Int): String? =
				vmLineRegex.find(shell(ctx, "logcat -d -v brief --pid=$pid"))
					?.groupValues?.get(1)

			fun waitPid(pkg: String, ctx: Context, onProgress: (String) -> Unit): Int? {
				val launchDeadline = System.currentTimeMillis() + 15_000
				while (System.currentTimeMillis() < launchDeadline) {
					pidOf()?.let { return it }
					Thread.sleep(1000)
				}
				return null
			}

			val deadline = System.currentTimeMillis() + timeoutMs
			var pid = pidOf()

			if (pid != null) {
				// Already running — one look in case the line survived the
				// buffer wipe; otherwise restart ONCE for a fresh print.
				vmLine(pid)?.let {
					onProgress("VM door found")
					return it
				}
				onProgress("target already running — restarting it for a fresh VM door")
				shell(ctx, "am force-stop $pkg")
				Thread.sleep(800)
				pid = null
			}

			if (pid == null) {
				onProgress("launching $pkg")
				if (!launch(pkg, ctx)) {
					onProgress("cannot launch $pkg — no launcher entry")
					return null
				}
				pid = waitPid(pkg, ctx, onProgress)
				if (pid == null) {
					onProgress("target never started")
					return null
				}
			}

			onProgress("target pid $pid — waiting for its VM door")
			while (System.currentTimeMillis() < deadline) {
				// The process may die on its own (crash, OEM killer) —
				// relaunch it; do NOT force-stop a healthy app for being
				// slow to boot.
				val current = pidOf()
				if (current == null) {
					onProgress("target died — relaunching")
					if (!launch(pkg, ctx)) {
						onProgress("cannot relaunch $pkg")
						return null
					}
					pid = waitPid(pkg, ctx, onProgress)
					if (pid == null) {
						onProgress("target never restarted")
						return null
					}
					onProgress("target pid $pid — waiting for its VM door")
				} else if (current != pid) {
					pid = current
					onProgress("target pid $pid — waiting for its VM door")
				}

				vmLine(pid)?.let {
					onProgress("VM door found")
					return it
				}
				Thread.sleep(800)
			}
			onProgress("no VM service line within the timeout — is $pkg a debug build?")
			return null
		} catch (e: Exception) {
			Log.w(TAG, "vm discovery failed: $e")
			return null
		}
	}
}
