package dev.rhr.adb

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.RemoteInput
import moe.shizuku.manager.adb.AdbMdns
import java.util.concurrent.atomic.AtomicBoolean

/**
 * ONE-TIME pairing flow. Runs the wireless-debugging pairing via a
 * NOTIFICATION with a code input — the same mechanism Shizuku uses.
 *
 * The user's flow:
 *   1. Tap "Pair" in the connector → this service starts, shows a
 *      notification, and deep-links to the Wireless debugging settings.
 *   2. On the settings screen: tap "Pair device with pairing code" —
 *      the system dialog shows a 6-digit code.
 *   3. Pull down the NOTIFICATION SHADE (over the settings screen) —
 *      the connector's notification has an "Enter code" action.
 *   4. Type the 6-digit code into the notification's input.
 *   5. The service runs the SPAKE2 handshake → paired → the result is
 *      delivered to Flutter ('pairingDone') and the service stops.
 *
 * This happens ONCE per device. The ADB key trust it creates is
 * permanent (reboots, network changes, wireless-debugging toggles);
 * every later launch reconnects silently without this service.
 *
 * Fixes over the first version:
 *   - EVERY notification includes the code-input action (a status
 *     update used to replace the action and kill the flow).
 *   - A code submitted before mDNS finds the pairing port is buffered
 *     and pairs automatically once the port lands.
 *   - The receiver registers once, not per start.
 *   - No hardcoded LAN IP — loopback first, then the real interface.
 */
class PairingNotificationService : Service() {
	companion object {
		private const val TAG = "rhr_pairing"
		private const val CHANNEL_ID = "rhr_pairing"
		private const val NOTIF_ID = 7413
		private const val KEY_CODE = "pairing_code"
		private const val ACTION_SUBMIT_CODE = "dev.rhr.adb.SUBMIT_PAIRING_CODE"

		/** Set by MainActivity; delivers the final result to Flutter. */
		@Volatile
		var onResult: ((Boolean) -> Unit)? = null
	}

	private val main = Handler(Looper.getMainLooper())
	private var mdns: AdbMdns? = null

	@Volatile private var pairingPort = -1
	@Volatile private var pendingCode: String? = null
	private val pairingBusy = AtomicBoolean(false)
	private var receiverRegistered = false
	private var discoveryStarted = false

	override fun onBind(intent: Intent?): IBinder? = null

	override fun onCreate() {
		super.onCreate()
		createChannel()
		if (!receiverRegistered) {
			val filter = IntentFilter(ACTION_SUBMIT_CODE)
			if (Build.VERSION.SDK_INT >= 33) {
				registerReceiver(codeReceiver, filter, Context.RECEIVER_EXPORTED)
			} else {
				registerReceiver(codeReceiver, filter)
			}
			receiverRegistered = true
		}
	}

	override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
		// REQUIRED: startForeground within 5s of startForegroundService.
		// buildNotification always includes the code-input action.
		startForeground(NOTIF_ID, buildNotification("Waiting for the pairing code…"))

		startDiscovery()
		post("Pull down this notification → tap \"Enter pairing code\" → type the 6-digit code from the settings dialog")

		// Deep-link to the Wireless debugging settings screen.
		startActivity(
			Intent(android.provider.Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
				.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
		return START_NOT_STICKY
	}

	override fun onDestroy() {
		if (receiverRegistered) {
			try { unregisterReceiver(codeReceiver) } catch (_: Exception) {}
			receiverRegistered = false
		}
		try { mdns?.stop() } catch (_: Exception) {}
		mdns = null
		discoveryStarted = false
		pairingBusy.set(false)
		super.onDestroy()
	}

	private fun startDiscovery() {
		if (discoveryStarted) return
		discoveryStarted = true
		mdns = AdbMdns(this, "_adb-tls-pairing._tcp.") { port ->
			if (port > 0) {
				pairingPort = port
				Log.d(TAG, "pairing port discovered: $port")
				post("Pairing port $port found — enter the 6-digit code")
				// A code typed before the port was known: pair now.
				pendingCode?.let { code -> runPairing(port, code) }
			} else {
				// The system pairing dialog closed — its port died.
				pairingPort = -1
			}
		}
		mdns!!.start()
	}

	private val codeReceiver = object : BroadcastReceiver() {
		override fun onReceive(ctx: Context, intent: Intent) {
			val code = RemoteInput.getResultsFromIntent(intent)
				?.getCharSequence(KEY_CODE)?.toString()?.trim() ?: return
			if (code.length < 6) {
				post("That code looks short — the pairing code is 6 digits")
				return
			}
			val port = pairingPort
			if (port <= 0) {
				// mDNS may still be discovering (takes a few seconds) —
				// buffer the code; it pairs as soon as the port lands.
				pendingCode = code
				post("Code received — waiting for the pairing port… keep the system pairing dialog open")
				return
			}
			runPairing(port, code)
		}
	}

	private fun runPairing(port: Int, code: String) {
		if (!pairingBusy.compareAndSet(false, true)) return
		post("Pairing…")
		Thread {
			var ok = false
			var lastError: Throwable? = null
			val hosts = mutableListOf("127.0.0.1")
			AdbConnection.lanAddress()?.let { if (it !in hosts) hosts.add(it) }
			for (host in hosts) {
				try {
					if (AdbConnection.pair(applicationContext, host, port, code)) {
						ok = true
						break
					}
				} catch (e: Throwable) {
					// Throwable, not Exception: pairing runs vendored native
					// + hidden-API code, and an Error (NoSuchMethodError,
					// UnsatisfiedLinkError, …) must degrade to a status
					// update — never take the process down mid-flow.
					lastError = e
					Log.w(TAG, "pairing attempt via $host failed: $e")
				}
			}
			Log.d(TAG, "pairing via $hosts: ok=$ok lastError=$lastError")
			main.post {
				pairingBusy.set(false)
				if (ok) {
					post("Paired ✓ — you never need to do this again")
					onResult?.invoke(true)
					stopSelf()
				} else {
					pendingCode = null
					post("Pairing failed — is the pairing dialog still open? Check the 6-digit code and try again")
					onResult?.invoke(false)
				}
			}
		}.start()
	}

	/** EVERY notification keeps the code-input action. */
	private fun post(text: String) {
		val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
		nm.notify(NOTIF_ID, buildNotification(text))
	}

	private fun buildNotification(text: String): Notification {
		createChannel()
		val remoteInput = RemoteInput.Builder(KEY_CODE).setLabel("6-digit code").build()
		val submitIntent = Intent(ACTION_SUBMIT_CODE).setPackage(packageName)
		val pendingIntent = PendingIntent.getBroadcast(
			this, 0, submitIntent,
			PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
		val action = NotificationCompat.Action.Builder(
			null, "Enter pairing code", pendingIntent)
			.addRemoteInput(remoteInput)
			.build()
		return NotificationCompat.Builder(this, CHANNEL_ID)
			.setContentTitle("rhr — pair with this phone (one-time)")
			.setContentText(text)
			.setSmallIcon(android.R.drawable.stat_sys_download)
			.setOngoing(true)
			.addAction(action)
			.build()
	}

	private fun createChannel() {
		val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
		nm.createNotificationChannel(
			NotificationChannel(CHANNEL_ID, "rhr pairing",
				NotificationManager.IMPORTANCE_HIGH))
	}
}
