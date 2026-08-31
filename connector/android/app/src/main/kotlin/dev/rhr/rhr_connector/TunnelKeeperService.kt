package dev.rhr.rhr_connector

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.IBinder

/**
 * Holds the connector process alive (foreground priority) while a target
 * app is being hot-reloaded remotely. The tunnel itself runs in the Dart
 * isolate; this service only keeps Android from freezing or killing the
 * process when the screen turns off.
 */
class TunnelKeeperService : Service() {
	override fun onBind(intent: Intent?): IBinder? = null

	override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
		val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
		nm.createNotificationChannel(
			NotificationChannel(
				"rhr_connector_tunnel", "rhr tunnel",
				NotificationManager.IMPORTANCE_LOW))
		val notification = Notification.Builder(this, "rhr_connector_tunnel")
			.setContentTitle("rhr connector active")
			.setContentText("Tunneling a Flutter app to your developer")
			.setSmallIcon(android.R.drawable.stat_sys_download)
			.setOngoing(true)
			.build()
		startForeground(NOTIF_ID, notification)
		return START_STICKY
	}

	companion object {
		private const val NOTIF_ID = 7412
	}
}
