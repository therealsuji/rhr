package dev.rhr.rhr_player

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import org.json.JSONArray
import android.os.Build
import android.provider.Settings
import dev.rhr.adb.AdbConnection
import dev.rhr.adb.ShellVm
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

/** Phone setup and target inspection do not require a running target VM. */
object RunPreparation {
	@Volatile var setupAction = ""
		private set
	@Volatile var setupMessage = ""
		private set

	fun handle(
		context: Context,
		request: JSONObject,
		reply: (JSONObject) -> Unit,
		selectVm: (String) -> Unit,
		isCurrent: () -> Boolean,
	) {
		Thread {
			val response = JSONObject().put("t", "run_response").put("id", request.optInt("id"))
			try {
				if (!isCurrent()) return@Thread
				when (request.getString("action")) {
					"inspect" -> {
						val pkg = packageName(request)
						val info = try {
							context.packageManager.getApplicationInfo(pkg, 0)
						} catch (_: android.content.pm.PackageManager.NameNotFoundException) { null }
						response.put("installed", info != null)
						if (info != null) {
							response.put("debuggable", info.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0)
							response.put("apkSha256", sha256(File(info.sourceDir)))
							val signatures = if (Build.VERSION.SDK_INT >= 28) {
								context.packageManager.getPackageInfo(pkg, PackageManager.GET_SIGNING_CERTIFICATES)
									.signingInfo?.apkContentsSigners
							} else {
								@Suppress("DEPRECATION")
								context.packageManager.getPackageInfo(pkg, PackageManager.GET_SIGNATURES).signatures
							}
							response.put("certificates", JSONArray(signatures?.map {
								MessageDigest.getInstance("SHA-256").digest(it.toByteArray())
									.joinToString("") { byte -> "%02x".format(byte) }
							} ?: emptyList<String>()))
						}
					}
					"connector" -> {
						val message = when {
							Build.VERSION.SDK_INT < 30 -> error("Connector mode requires Android 11 or later.")
							Settings.Global.getInt(context.contentResolver, "adb_wifi_enabled", 0) != 1 ->
								"Enable Wireless debugging on this phone."
							!AdbConnection.paired(context) -> "Pair this phone with RHR."
							!AdbConnection.ensureConnected(context) -> "Reconnect Wireless debugging to RHR."
							!Settings.canDrawOverlays(context) -> "Allow RHR to display the session controls over your app."
							else -> ""
						}
						setupAction = if (message.isEmpty()) "" else "connector"
						setupMessage = message
						response.put("ready", message.isEmpty()).put("message", message)
					}
					// The beacon route needs no Wireless debugging: only the
					// overlay the session controls are drawn in.
					"beacon_setup" -> {
						val message = if (Settings.canDrawOverlays(context)) ""
							else "Allow RHR to display the session controls over your app."
						setupAction = if (message.isEmpty()) "" else "overlay"
						setupMessage = message
						response.put("ready", message.isEmpty()).put("message", message)
					}
					"install_permission" -> {
						val allowed = Build.VERSION.SDK_INT < 26 || context.packageManager.canRequestPackageInstalls()
						setupAction = if (allowed) "" else "install"
						setupMessage = if (allowed) "" else "Allow RHR to install this debug build."
						response.put("ready", allowed).put("message", setupMessage)
					}
					"launch" -> {
						val pkg = packageName(request)
						val info = context.packageManager.getApplicationInfo(pkg, 0)
						check(info.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) { "The installed app is not a debug build." }
						if (request.optBoolean("beacon")) {
							val vm = launchWithBeacon(context, pkg)
							if (!isCurrent()) return@Thread
							selectVm(vm)
							// The tester may close and reopen the app; its VM then
							// listens on a new port, and the beacon reports it.
							Beacons.onAnnounce = { reported, address ->
								if (reported == pkg && isCurrent()) selectVm(address)
							}
							OverlayService.start(context)
							response.put("vm", vm)
							response.put("ok", true)
							if (isCurrent()) reply(response)
							return@Thread
						}
						check(AdbConnection.ensureConnected(context)) { "Wireless debugging disconnected. Complete connector setup and retry." }
						if (!isCurrent()) return@Thread
						check(ShellVm.launch(pkg, context)) { "The debug app has no launcher activity." }
						val vm = ShellVm.discoverVmUriBlocking(pkg, context, 45_000)
							?: error("The app did not expose a Dart VM. Check its launch logs and debug build.")
						if (!isCurrent()) return@Thread
						selectVm(vm)
						OverlayService.start(context)
						response.put("vm", vm)
					}
					else -> error("Unsupported RHR preparation action.")
				}
				response.put("ok", true)
			} catch (error: Exception) {
				response.put("ok", false).put("message", error.message ?: error.javaClass.simpleName)
			}
			if (isCurrent()) reply(response)
		}.start()
	}

	/** Opens [pkg] and waits for its beacon. A running app is asked to report
	 *  again, since this player may have restarted since it last did. */
	private fun launchWithBeacon(context: Context, pkg: String): String {
		Beacons.forget(pkg)
		val intent = context.packageManager.getLaunchIntentForPackage(pkg)
			?: error("The debug app has no launcher activity.")
		context.startActivity(intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))
		Beacons.requestAnnounce(context, pkg)
		return Beacons.await(pkg, 45_000)
			?: error("The app did not report its Dart VM. Run rhr again to rebuild it.")
	}

	private fun packageName(request: JSONObject): String {
		val pkg = request.getString("package")
		require(Regex("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+").matches(pkg)) {
			"Invalid Android package name."
		}
		return pkg
	}

	private fun sha256(file: File): String {
		val digest = MessageDigest.getInstance("SHA-256")
		file.inputStream().use { input ->
			val buffer = ByteArray(64 * 1024)
			while (true) {
				val count = input.read(buffer)
				if (count < 0) break
				digest.update(buffer, 0, count)
			}
		}
		return digest.digest().joinToString("") { "%02x".format(it) }
	}
}
