package dev.rhr.rhr_player

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import android.view.accessibility.AccessibilityManager
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * Puts RHR Agent on the phone from the player itself, so agent control is
 * set up once on the phone and never needs a computer session first.
 *
 * The agent is the one published with this player's version. It is trusted
 * only if it is `dev.rhr.agent` signed with the player's own key, the same
 * pairing the agent and the player check at runtime; where it was downloaded
 * from does not matter.
 */
internal object AgentSetup {
	const val PACKAGE = "dev.rhr.agent"
	private const val TAG = "rhr_agent_setup"
	private const val MAX_APK_BYTES = 64L shl 20
	private const val RELEASES = "https://github.com/therealsuji/rhr/releases/download"

	/** "missing", "untrusted" (signed with another key), "off", or "on". */
	fun status(context: Context): String {
		val packages = context.packageManager
		try {
			packages.getPackageInfo(PACKAGE, 0)
		} catch (_: PackageManager.NameNotFoundException) {
			return "missing"
		}
		if (packages.checkSignatures(context.packageName, PACKAGE) != PackageManager.SIGNATURE_MATCH) {
			return "untrusted"
		}
		val accessibility = context.getSystemService(AccessibilityManager::class.java)
		val on = accessibility
			.getEnabledAccessibilityServiceList(AccessibilityServiceInfo.FEEDBACK_ALL_MASK)
			.any { it.resolveInfo.serviceInfo.packageName == PACKAGE }
		return if (on) "on" else "off"
	}

	/**
	 * Downloads, checks and hands the agent to Android's installer. Blocks,
	 * so call it off the main thread. Returns why it could not, or null once
	 * Android has the install (its confirmation sheet comes next).
	 */
	fun install(context: Context): String? {
		val packages = context.packageManager
		if (!packages.canRequestPackageInstalls()) {
			context.startActivity(
				Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))
					.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
			)
			return "Allow RHR Player to install apps, then come back and tap Install again."
		}
		val version = packages.getPackageInfo(context.packageName, 0).versionName ?: ""
		val apk = File(context.cacheDir, "rhr-agent.apk")
		try {
			download(URL("$RELEASES/v$version/rhr-agent-$version.apk"), apk)
				?.let { return it.replace("{version}", version) }
			val archive = archiveInfo(packages, apk)
			if (archive?.packageName != PACKAGE) return "The download is not RHR Agent. Try again later."
			if (certificates(archive) != certificates(ownInfo(context))) {
				return "The downloaded RHR Agent is not signed like this player, so it was not installed."
			}
			commit(context, apk)
			return null
		} catch (e: Exception) {
			Log.w(TAG, "agent install failed: $e")
			return "Could not install RHR Agent: ${e.message ?: e}"
		} finally {
			apk.delete()
		}
	}

	/** Opens the agent's screen, which walks the user to its switch. */
	fun open(context: Context) {
		context.startActivity(
			Intent()
				.setClassName(PACKAGE, "$PACKAGE.MainActivity")
				.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
		)
	}

	/** Null when [to] holds the APK, or the reason it does not. */
	private fun download(url: URL, to: File): String? {
		val connection = url.openConnection() as HttpURLConnection
		connection.connectTimeout = 15_000
		connection.readTimeout = 30_000
		try {
			when (connection.responseCode) {
				200 -> Unit
				404 -> return "No RHR Agent is published for player {version}. A player you built " +
					"yourself needs RHR Agent built with the same key; install it with rhr mcp's install_agent."
				else -> return "GitHub answered ${connection.responseCode}. Try again later."
			}
			if (connection.contentLengthLong > MAX_APK_BYTES) return "The download is too large to be RHR Agent."
			connection.inputStream.use { input ->
				to.outputStream().use { output ->
					val buffer = ByteArray(64 * 1024)
					var total = 0L
					while (true) {
						val read = input.read(buffer)
						if (read < 0) break
						total += read
						if (total > MAX_APK_BYTES) return "The download is too large to be RHR Agent."
						output.write(buffer, 0, read)
					}
				}
			}
			return null
		} finally {
			connection.disconnect()
		}
	}

	private fun commit(context: Context, apk: File) {
		val installer = context.packageManager.packageInstaller
		val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
			.apply {
				setAppPackageName(PACKAGE)
				setSize(apk.length())
			}
		val sessionId = installer.createSession(params)
		installer.openSession(sessionId).use { session ->
			session.openWrite("rhr-agent.apk", 0, apk.length()).use { out ->
				apk.inputStream().use { it.copyTo(out) }
				session.fsync(out)
			}
			val pending = PendingIntent.getBroadcast(
				context,
				sessionId,
				Intent(context, AgentInstallReceiver::class.java),
				PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
			)
			session.commit(pending.intentSender)
		}
	}

	private fun ownInfo(context: Context): PackageInfo =
		context.packageManager.getPackageInfo(context.packageName, signingFlags())

	private fun archiveInfo(packages: PackageManager, apk: File): PackageInfo? =
		packages.getPackageArchiveInfo(apk.path, signingFlags())

	@Suppress("DEPRECATION")
	private fun signingFlags(): Int =
		if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES
		else PackageManager.GET_SIGNATURES

	/** SHA-256 of each signing certificate, as a set to compare. */
	@Suppress("DEPRECATION")
	private fun certificates(info: PackageInfo): Set<String> {
		val signatures = if (Build.VERSION.SDK_INT >= 28) {
			info.signingInfo?.apkContentsSigners
		} else {
			info.signatures
		} ?: return emptySet()
		val sha = MessageDigest.getInstance("SHA-256")
		return signatures.map { signature ->
			sha.digest(signature.toByteArray()).joinToString("") { "%02x".format(it) }
		}.toSet()
	}
}

/**
 * Android's answer to the agent install: show its confirmation sheet, then
 * open the agent so the user can turn it on.
 */
class AgentInstallReceiver : BroadcastReceiver() {
	override fun onReceive(context: Context, intent: Intent) {
		when (val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -1)) {
			PackageInstaller.STATUS_PENDING_USER_ACTION -> {
				@Suppress("DEPRECATION")
				intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)?.let {
					context.startActivity(it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
				}
			}
			PackageInstaller.STATUS_SUCCESS -> AgentSetup.open(context)
			else -> Log.w(
				"rhr_agent_setup",
				"agent install ended with $status: ${intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)}",
			)
		}
	}
}
