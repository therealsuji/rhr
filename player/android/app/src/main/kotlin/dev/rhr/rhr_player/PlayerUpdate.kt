package dev.rhr.rhr_player

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.provider.Settings
import android.util.Log
import java.io.File

/**
 * Updates the player to a published release from the player itself: download
 * the release APK, check it, and hand it to Android, whose sheet asks the
 * user to install it. Nobody has to leave for a browser.
 *
 * The APK is about 100 MB and phones are often on a poor connection, so a
 * download that stops is continued, not restarted, the next time the user
 * asks. It is installed only if it is this player's package, newer than this
 * build, signed with this player's key, and the bytes the release lists in
 * SHA256SUMS.
 *
 * The lobby polls [state] while this runs.
 */
internal object PlayerUpdate {
	private const val TAG = "rhr_player_update"
	private const val MAX_APK_BYTES = 256L shl 20

	/** "idle", "downloading", "verifying", "installing", "permission" or "failed". */
	@Volatile var phase = "idle"
		private set
	@Volatile var done = 0L
		private set
	@Volatile var total = -1L
		private set
	@Volatile var problem: String? = null
		private set

	fun state(): Map<String, Any?> =
		mapOf("phase" to phase, "done" to done, "total" to total, "problem" to problem)

	/** Starts updating to [version], unless an update is already under way. */
	@Synchronized
	fun start(context: Context, version: String) {
		if (phase == "downloading" || phase == "verifying" || phase == "installing") return
		val app = context.applicationContext
		if (!app.packageManager.canRequestPackageInstalls()) {
			app.startActivity(
				Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${app.packageName}"))
					.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
			)
			// The lobby carries on with the update once this is allowed.
			phase = "permission"
			problem = null
			return
		}
		phase = "downloading"
		done = 0L
		total = -1L
		problem = null
		Thread { run(app, version) }.apply { isDaemon = true }.start()
	}

	/** Android's verdict on the install, when it is not a restart into the new version. */
	fun installEnded(message: String) {
		fail(message)
	}

	private fun run(context: Context, version: String) {
		val name = "rhr-player-$version-android-arm64.apk"
		val folder = File(context.cacheDir, "player-update").apply { mkdirs() }
		// Keep only this version's file: an older partial download is useless.
		folder.listFiles()?.filter { !it.name.startsWith(name) }?.forEach { it.delete() }
		val partial = File(folder, "$name.part")
		// A whole download from a try the user cancelled is reused: asking the
		// server for the rest of it gets "nothing left", and it is checked again.
		File(folder, name).takeIf { it.exists() }?.renameTo(partial)
		try {
			ReleaseApk.download(ReleaseApk.url(version, name), partial, MAX_APK_BYTES) { got, size ->
				done = got
				total = size
			}?.let { return fail(it) }

			phase = "verifying"
			val expected = ReleaseApk.publishedSha256(version, name)
				?: return fail("The release does not list a checksum for $name.")
			if (ReleaseApk.sha256(partial) != expected) {
				partial.delete()
				return fail("The download was corrupted. Try again.")
			}
			val apk = File(folder, name)
			partial.renameTo(apk)
			val archive = ReleaseApk.archiveInfo(context, apk)
				?: return fail("The download is not an app Android can read.")
			val own = ReleaseApk.ownInfo(context)
			if (archive.packageName != context.packageName) {
				return fail("The download is not RHR Player.")
			}
			if (!ReleaseApk.signedLikePlayer(context, archive)) {
				return fail(
					"This player was built with a different key than the published one, so it " +
						"cannot be updated in place. Install the release from GitHub instead.",
				)
			}
			if (ReleaseApk.versionCode(archive) <= ReleaseApk.versionCode(own)) {
				return fail("This player is already as new as $version.")
			}

			phase = "installing"
			ReleaseApk.commit(context, apk, context.packageName, Intent(context, PlayerInstallReceiver::class.java))
			// Android's sheet comes next. Installing replaces this process, so a
			// success is the new version starting, not a call back here.
		} catch (e: Exception) {
			Log.w(TAG, "player update failed: $e")
			fail("Could not update: ${e.message ?: e}")
		}
	}

	private fun fail(message: String) {
		Log.w(TAG, message)
		problem = message
		phase = "failed"
	}
}

/** Android's answer to the player's own install: show its sheet, or say why it stopped. */
class PlayerInstallReceiver : BroadcastReceiver() {
	override fun onReceive(context: Context, intent: Intent) {
		when (val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -1)) {
			PackageInstaller.STATUS_PENDING_USER_ACTION -> {
				@Suppress("DEPRECATION")
				intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)?.let {
					context.startActivity(it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
				}
			}
			PackageInstaller.STATUS_SUCCESS -> Unit
			PackageInstaller.STATUS_FAILURE_ABORTED -> PlayerUpdate.installEnded("The update was cancelled.")
			else -> PlayerUpdate.installEnded(
				"Android did not install the update (status $status): " +
					intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE).orEmpty(),
			)
		}
	}
}
