package dev.rhr.rhr_player

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import org.json.JSONArray
import android.os.Build
import android.provider.Settings
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
		selectVm: (vm: String, pkg: String) -> Unit,
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
					// The overlay the session controls are drawn in; holding it
					// also lets the player open the app from the background.
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
						val vm = launchWithBeacon(context, pkg)
						if (!isCurrent()) return@Thread
						selectVm(vm, pkg)
						// The tester may close and reopen the app; its VM then
						// listens on a new port, and the beacon reports it.
						Beacons.onAnnounce = { reported, address ->
							if (reported == pkg && isCurrent()) selectVm(address, pkg)
						}
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
