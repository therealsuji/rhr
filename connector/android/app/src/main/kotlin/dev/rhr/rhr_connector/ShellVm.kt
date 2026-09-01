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
 * Two stages: the existing log buffer first, then force-stop + relaunch
 * the target (a fresh engine always prints the line) when the buffer has
 * rotated past it.
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
			// The stock ring buffer rotates the VM line within seconds on
			// busy phones — enlarge it before reading.
			onProgress("enlarging the log buffer")
			shell(ctx, "logcat -G 16M")

			var pid: Int? = null
			val deadline = System.currentTimeMillis() + timeoutMs
			while (System.currentTimeMillis() < deadline) {
				if (pid == null) {
					val pidText = shell(ctx, "pidof $pkg")
					pid = pidText.split(Regex("\\s+"))
						.firstOrNull { it.isNotBlank() }?.toIntOrNull()
					if (pid == null) {
						onProgress("target not running — launching $pkg")
						launch(pkg, ctx)
						val launchDeadline = System.currentTimeMillis() + 15_000
						while (pid == null && System.currentTimeMillis() < launchDeadline) {
							Thread.sleep(1000)
							val t = shell(ctx, "pidof $pkg")
							pid = t.split(Regex("\\s+"))
								.firstOrNull { it.isNotBlank() }?.toIntOrNull()
						}
						if (pid == null) {
							onProgress("target never started")
							return null
						}
					}
					onProgress("target pid $pid — reading its log")
				}

				val dump = shell(ctx, "logcat -d -v brief --pid=$pid")
				vmLineRegex.find(dump)?.let {
					onProgress("VM door found")
					return it.groupValues[1]
				}

				// The buffer rotated past the engine's startup line (the
				// target has been running for a while): restart it — a
				// fresh engine prints the door line immediately, and the
				// dev's kernel push replaces its Dart code right after.
				onProgress("no VM line in the buffer — restarting the target app")
				shell(ctx, "am force-stop $pkg")
				Thread.sleep(1000)
				launch(pkg, ctx)
				pid = null
			}
			onProgress("no VM service line within the timeout — is $pkg a debug build?")
			return null
		} catch (e: Exception) {
			Log.w(TAG, "vm discovery failed: $e")
			return null
		}
	}
}
