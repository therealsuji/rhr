package dev.rhr.rhr_player

import android.app.Application
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Wires the player's handlers into the session library when the process
 * starts, not when the screen opens: Android restarts the session service
 * on its own (an update, a reboot, memory pressure), and a session must
 * answer its computer before anyone opens the player.
 */
class RhrPlayerApp : Application() {
	override fun onCreate() {
		super.onCreate()
		// The library owns the tunnel; the player owns installs (PackageInstaller)
		// and run preparation.
		RhrSessionService.updateHandlerFactory = { ctx, sendText, sendBinary ->
			RhrPlayerUpdater(ctx, sendText, sendBinary)
		}
		RhrSessionService.runRequestHandler = RunPreparation::handle
	}
}

/** Brings the last session back after a reboot or after the player updated itself. */
class SessionRestoreReceiver : BroadcastReceiver() {
	override fun onReceive(context: Context, intent: Intent) {
		when (intent.action) {
			Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED ->
				RhrSessionService.restore(context)
		}
	}
}
