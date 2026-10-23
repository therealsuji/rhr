package dev.rhr.rhr_player

import android.accessibilityservice.AccessibilityServiceInfo
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import android.util.Log
import android.view.accessibility.AccessibilityManager
import java.io.File

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

	/**
	 * "missing", "untrusted" (signed with another key), "outdated" (from an
	 * older release than this player), "off", or "on".
	 */
	fun status(context: Context): String {
		val packages = context.packageManager
		val agent = try {
			packages.getPackageInfo(PACKAGE, 0)
		} catch (_: PackageManager.NameNotFoundException) {
			return "missing"
		}
		if (packages.checkSignatures(context.packageName, PACKAGE) != PackageManager.SIGNATURE_MATCH) {
			return "untrusted"
		}
		// Releases stamp the player and the agent with one build number. An
		// agent built locally carries none, and is whatever its builder meant.
		val player = packages.getPackageInfo(context.packageName, 0)
		if (agent.versionName != LOCAL_BUILD && ReleaseApk.versionCode(agent) < ReleaseApk.versionCode(player)) {
			return "outdated"
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
			return "Allow RHR Player to install apps. The install carries on when you come back."
		}
		val version = packages.getPackageInfo(context.packageName, 0).versionName ?: ""
		val apk = File(context.cacheDir, "rhr-agent.apk").apply { delete() }
		try {
			ReleaseApk.download(ReleaseApk.url(version, "rhr-agent-$version.apk"), apk, MAX_APK_BYTES)
				?.let { problem ->
					return if (problem.startsWith("Not found")) {
						"No RHR Agent is published for player $version. A player you built yourself " +
							"needs RHR Agent built with the same key; install it with rhr mcp's install_agent."
					} else problem
				}
			val archive = ReleaseApk.archiveInfo(context, apk)
			if (archive?.packageName != PACKAGE) return "The download is not RHR Agent. Try again later."
			if (!ReleaseApk.signedLikePlayer(context, archive)) {
				return "The downloaded RHR Agent is not signed like this player, so it was not installed."
			}
			ReleaseApk.commit(context, apk, PACKAGE, Intent(context, AgentInstallReceiver::class.java))
			return null
		} catch (e: Exception) {
			Log.w(TAG, "agent install failed: $e")
			return "Could not install RHR Agent: ${e.message ?: e}"
		} finally {
			apk.delete()
		}
	}

	/** The agent's versionName when it was not built by a release. */
	private const val LOCAL_BUILD = "0.0.0-dev"

	/** Opens the agent's screen, which walks the user to its switch. */
	fun open(context: Context) {
		context.startActivity(
			Intent()
				.setClassName(PACKAGE, "$PACKAGE.MainActivity")
				.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
		)
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
