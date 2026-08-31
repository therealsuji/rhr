package dev.rhr.rhr_connector

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import rikka.shizuku.Shizuku
import java.io.File

/**
 * One-time Shizuku setup: manager install (bundled APK, triggered through
 * PackageInstaller — one system sheet tap), server start (one tap in the
 * Shizuku app; Android 11+ pairing is walked by Shizuku's own wizard), and
 * the per-app permission dialog.
 */
object ShizukuGate {
	const val TAG = "rhr_connector"
	const val MANAGER_PACKAGE = "moe.shizuku.privileged.api"
	const val PERMISSION_REQUEST_CODE = 7001
	private const val INSTALL_ACTION = "$MANAGER_PACKAGE.INSTALL_STATUS"

	fun isManagerInstalled(ctx: Context): Boolean = try {
		ctx.packageManager.getPackageInfo(MANAGER_PACKAGE, 0)
		true
	} catch (_: Exception) {
		false
	}

	fun isServerRunning(): Boolean = try {
		Shizuku.pingBinder()
	} catch (_: Exception) {
		false
	}

	fun hasPermission(): Boolean = try {
		isServerRunning() && Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
	} catch (_: Exception) {
		false
	}

	/** Copies the bundled manager APK out of assets and hands it to
	 *  PackageInstaller. The system shows the install sheet; the dynamic
	 *  receiver logs the outcome for debugging. */
	fun installFromAssets(activity: Activity) {
		try {
			val apk = File(activity.filesDir, "shizuku-manager.apk")
			activity.assets.open("shizuku.apk").use { input ->
				apk.outputStream().use { input.copyTo(it) }
			}
			val installer = activity.packageManager.packageInstaller
			val params = PackageInstaller.SessionParams(
				PackageInstaller.SessionParams.MODE_FULL_INSTALL
			).apply { setSize(apk.length()) }

			val receiver = object : BroadcastReceiver() {
				override fun onReceive(ctx: Context, intent: Intent) {
					val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -1)
					val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
					Log.i(TAG, "shizuku manager install status: $status $message")
					// STATUS_PENDING_USER_ACTION (-1) carries the confirm
					// dialog intent — nothing is shown until it is started.
					if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
						@Suppress("DEPRECATION")
						val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
						if (confirm != null) {
							activity.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
						}
					} else {
						try { activity.unregisterReceiver(this) } catch (_: Exception) {}
					}
				}
			}
			ContextCompat.registerReceiver(
				activity, receiver, IntentFilter(INSTALL_ACTION),
				ContextCompat.RECEIVER_NOT_EXPORTED,
			)

			val sessionId = installer.createSession(params)
			installer.openSession(sessionId).use { session ->
				session.openWrite("shizuku.apk", 0, apk.length()).use { out ->
					apk.inputStream().use { it.copyTo(out) }
					session.fsync(out)
				}
				val statusIntent = Intent(INSTALL_ACTION).setPackage(activity.packageName)
				val pending = PendingIntent.getBroadcast(
					activity,
					sessionId,
					statusIntent,
					PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
				)
				session.commit(pending.intentSender)
			}
			Log.i(TAG, "shizuku manager install session committed (sheet expected)")
		} catch (e: Exception) {
			Log.w(TAG, "shizuku manager install failed: $e")
		}
	}

	fun openManager(ctx: Context) {
		val intent = ctx.packageManager.getLaunchIntentForPackage(MANAGER_PACKAGE)
		if (intent != null) ctx.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
	}

	fun requestPermission(activity: Activity) {
		Shizuku.requestPermission(PERMISSION_REQUEST_CODE)
	}
}
