package dev.rhr.rhr_player

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.os.IBinder
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.WindowManager

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
	private var screenHold: View? = null
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
		holdScreen(RhrSessionService.usesExternalVm && RhrSessionService.status == "connected")
		if (playerVisible || !RhrSessionService.usesExternalVm) {
			overlay?.detach()
			overlay = null
			return
		}
		if (overlay == null && SystemOverlayHost.granted(this)) {
			overlay = DevOverlay(this, SystemOverlayHost(this)).also { it.attach() }
		}
	}

	/**
	 * Keeps the display from timing out while a developer is attached.
	 *
	 * The streamed app is another package, so the player cannot set
	 * FLAG_KEEP_SCREEN_ON on the window the tester is looking at. It can set
	 * it on a window of its own above that app: the flag holds the screen for
	 * as long as any visible window carries it. So this is a 1×1, fully
	 * transparent, untouchable overlay whose only job is the flag. Fully
	 * transparent also exempts it from Android 12's untrusted-touch blocking.
	 *
	 * The bubble window cannot carry the flag instead: it is only on screen
	 * after a shake. The power button still turns the screen off; only the
	 * idle timeout is suppressed.
	 */
	private fun holdScreen(hold: Boolean) {
		val wm = getSystemService(WINDOW_SERVICE) as WindowManager
		val current = screenHold
		if (!hold || !SystemOverlayHost.granted(this)) {
			if (current != null) runCatching { wm.removeView(current) }
			screenHold = null
			return
		}
		if (current != null) return
		val view = View(this)
		val params = WindowManager.LayoutParams(
			1,
			1,
			WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
			WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
				WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
				WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
			PixelFormat.TRANSLUCENT,
		).apply { alpha = 0f }
		runCatching { wm.addView(view, params) }
			.onSuccess { screenHold = view }
			.onFailure { android.util.Log.w("rhr_overlay", "screen hold rejected", it) }
	}

	override fun onDestroy() {
		holdScreen(false)
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
