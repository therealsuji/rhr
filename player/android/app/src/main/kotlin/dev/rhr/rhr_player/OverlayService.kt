package dev.rhr.rhr_player

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.os.Handler
import android.os.Looper

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
	private val main = Handler(Looper.getMainLooper())
	private val refreshOverlay: () -> Unit = { main.post { refresh() } }

	override fun onCreate() {
		super.onCreate()
		instance = this
		RhrSessionService.updateListeners.add(refreshOverlay)
	}

	override fun onBind(intent: Intent?): IBinder? = null

	override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
		startForeground(NOTIF_ID, buildNotification())

		if (intent?.getStringExtra("cmd") == "stop") {
			stopSelf()
			return START_NOT_STICKY
		}

		refresh()
		return START_STICKY
	}

	private fun refresh() {
		if (!RhrSessionService.usesExternalVm) {
			stopSelf()
		}
		if (playerVisible || !RhrSessionService.usesExternalVm) {
			overlay?.detach()
			overlay = null
			return
		}
		if (overlay == null && SystemOverlayHost.granted(this)) {
			overlay = DevOverlay(this, SystemOverlayHost(this)).also { it.attach() }
		}
	}

	override fun onDestroy() {
		overlay?.detach()
		overlay = null
		RhrSessionService.updateListeners.remove(refreshOverlay)
		main.removeCallbacksAndMessages(null)
		instance = null
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
		private var instance: OverlayService? = null
		private var playerVisible = false

		fun setPlayerVisible(visible: Boolean) {
			playerVisible = visible
			instance?.refresh()
		}
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
