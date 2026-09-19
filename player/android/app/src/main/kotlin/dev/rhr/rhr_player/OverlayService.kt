package dev.rhr.rhr_player

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.util.Log

/**
 * Owns the dev overlay in CONNECTOR mode, where the tester is looking at their
 * own app and the player has no Activity on screen.
 *
 * It is a foreground service for the same reason the session service is: once
 * the player is backgrounded, Android is free to kill a plain service, and an
 * overlay that disappears halfway through a QA run is worse than none. The
 * notification doubles as the honest "this app is watching your sensors" signal
 * that a shake detector ought to carry.
 *
 * Hosted mode does NOT use this — there the overlay lives in the player's own
 * Activity (see [ActivityOverlayHost]), needs no permission, and is torn down
 * with the Activity.
 */
class OverlayService : Service() {
	private var overlay: DevOverlay? = null

	override fun onBind(intent: Intent?): IBinder? = null

	override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
		startForeground(NOTIF_ID, buildNotification())

		if (intent?.getStringExtra("cmd") == "stop") {
			stopSelf()
			return START_NOT_STICKY
		}

		if (overlay == null) {
			// Without the permission the window manager rejects the view with
			// a BadTokenException. Checking first turns "the app crashed" into
			// a log line and a service that simply does nothing.
			if (!SystemOverlayHost.granted(this)) {
				Log.w(TAG, "overlay permission not granted — bubble unavailable")
				stopSelf()
				return START_NOT_STICKY
			}
			overlay = DevOverlay(this, SystemOverlayHost(this)).also { it.attach() }
		}
		// STICKY: if Android reclaims us mid-session, come back — the session
		// itself is still alive in RhrSessionService.
		return START_STICKY
	}

	override fun onDestroy() {
		overlay?.detach()
		overlay = null
		super.onDestroy()
	}

	private fun buildNotification(): Notification {
		val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
		nm.createNotificationChannel(
			NotificationChannel(
				CHANNEL,
				"rhr dev overlay",
				NotificationManager.IMPORTANCE_LOW,
			).apply {
				description = "Shake-to-open session bubble while tunneling an app"
			})
		return Notification.Builder(this, CHANNEL)
			.setContentTitle("rhr — shake to open")
			.setContentText("Shake the phone to see the session or disconnect")
			.setSmallIcon(android.R.drawable.stat_sys_download)
			.setOngoing(true)
			.build()
	}

	companion object {
		private const val TAG = "rhr_overlay"
		private const val CHANNEL = "rhr_overlay"
		private const val NOTIF_ID = 7414

		fun start(context: Context) {
			context.startForegroundService(
				Intent(context, OverlayService::class.java))
		}

		fun stop(context: Context) {
			context.startService(
				Intent(context, OverlayService::class.java).putExtra("cmd", "stop"))
		}
	}
}
