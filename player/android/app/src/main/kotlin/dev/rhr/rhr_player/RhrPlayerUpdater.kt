package dev.rhr.rhr_player

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.security.MessageDigest
import org.json.JSONObject

/**
 * Receives a replacement player APK streamed by the dev CLI and hands it to
 * Android's PackageInstaller (the Tachiyomi-style in-app install). Lives in
 * the native service beside the tunnel: the transfer must survive guest
 * hot-restarts, and the install itself kills the whole process.
 *
 * Protocol (mirror of cli/lib/player_update.dart):
 *   {"t":"update_begin","id":N,"size":S,"sha256":H,
 *    "kind":"player"|"app","target":"<pkg>"}        -> answer "ready"
 *   binary [op=4][4B id][chunk]                      -> append, ack (op 3)
 *   {"t":"update_commit","id":N}                     -> no more data is
 *       coming; verify once every byte has landed (the direct WebRTC path
 *       carries binary out-of-band from relay text, so commit may overtake
 *       the tail of the stream), then install and answer "committed" or
 *       "pending_user" / "installed" / "failure".
 *
 *   kind="player" (default): the APK replaces THIS app; a silent apply
 *       kills the process, so "committed" is sent before commit() and
 *       STATUS_SUCCESS is normally unreachable.
 *   kind="app": the APK is a FOREIGN package (the tier-2 wrapped app,
 *       delivered through the player). This process survives the install,
 *       so the result receiver reports the terminal "installed" (or
 *       "failure") after the user confirms the system sheet.
 */
class RhrPlayerUpdater(
	private val context: Context,
	private val sendText: (String) -> Unit,
	private val sendBinary: (ByteArray) -> Unit,
) : RhrUpdateHandler {
	companion object {
		private const val TAG = "rhr_updater"
		private const val OP_ACK = 3
		// After commit, an incomplete transfer that stops making progress for
		// this long is dead (the CLI's own ack-stall timeout is 60s too).
		private const val COMMIT_STALL_MS = 60_000L

		// The receiver runs in a fresh broadcast context; reach the live
		// updater through the service singleton.
		@Volatile var active: RhrPlayerUpdater? = null
	}

	private var transferId = 0
	private var expectedSize = 0L
	private var expectedSha256 = ""
	private var installKind = "player"
	private var installTarget = ""
	private var file: File? = null
	private var output: FileOutputStream? = null
	private var digest: MessageDigest? = null
	private var received = 0L
	private var commitRequested = false
	private var finished = false
	private var lastDataAt = 0L

	override fun handleBegin(message: JSONObject) {
		val id = message.optInt("id")
		val size = message.optLong("size")
		val sha = message.optString("sha256")
		if (id == 0 || size <= 0 || sha.isEmpty()) {
			status(id, "failure", "malformed update_begin")
			return
		}
		synchronized(this) {
			closeQuietly()
			transferId = id
			expectedSize = size
			expectedSha256 = sha
			installKind = message.optString("kind", "player")
			installTarget = message.optString("target", "")
			received = 0
			commitRequested = false
			finished = false
			val dir = File(context.filesDir, "updates").apply { mkdirs() }
			// One in-flight update at a time; a stale file from a dead
			// transfer is simply overwritten.
			file = File(dir, "player-update.apk")
			output = FileOutputStream(file)
			digest = MessageDigest.getInstance("SHA-256")
		}
		active = this
		Log.i(TAG, "update transfer $id started ($size bytes)")
		status(id, "ready")
	}

	override fun handleData(frame: ByteArray) {
		val id = ByteBuffer.wrap(frame, 1, 4).int
		synchronized(this) {
			if (id != transferId || finished) return
			val n = frame.size - 5
			try {
				output?.write(frame, 5, n)
				digest?.update(frame, 5, n)
			} catch (e: Exception) {
				Log.w(TAG, "update write failed: $e")
				fail("could not write the APK on the device: $e")
				return
			}
			received += n
			lastDataAt = System.currentTimeMillis()
			sendBinary(encodeAck(id, n))
			if (commitRequested && received >= expectedSize) finishTransfer()
		}
	}

	override fun handleCommit(message: JSONObject) {
		val id = message.optInt("id")
		synchronized(this) {
			if (id != transferId || finished) return
			commitRequested = true
			lastDataAt = System.currentTimeMillis()
			if (received >= expectedSize) {
				finishTransfer()
			} else {
				watchForStall()
			}
		}
	}

	// Commit arrived before the tail of the stream (direct-path reordering).
	// Wait for the rest, but not forever.
	private fun watchForStall() {
		Thread {
			while (true) {
				Thread.sleep(5000)
				synchronized(this) {
					if (finished || received >= expectedSize) return@Thread
					if (System.currentTimeMillis() - lastDataAt > COMMIT_STALL_MS) {
						fail(
							"transfer incomplete: $received of $expectedSize bytes")
						return@Thread
					}
				}
			}
		}.also { it.isDaemon = true }.start()
	}

	// Callers hold the monitor.
	private fun finishTransfer() {
		finished = true
		val apk = file ?: return
		try {
			output?.close()
			output = null
		} catch (_: Exception) {}
		if (received != expectedSize) {
			fail("size mismatch: got $received, expected $expectedSize")
			return
		}
		val actual = digest?.digest()?.joinToString("") { "%02x".format(it) }
		if (actual != expectedSha256) {
			fail("sha256 mismatch: transfer corrupted")
			return
		}
		Log.i(TAG, "update transfer $transferId verified; installing")
		install(apk)
	}

	private fun install(apk: File) {
		try {
			val foreign = installKind == "app" && installTarget.isNotEmpty()
			val installer = context.packageManager.packageInstaller
			val params = PackageInstaller.SessionParams(
				PackageInstaller.SessionParams.MODE_FULL_INSTALL
			).apply {
				// kind=app delivers a FOREIGN package (the tier-2 wrapped
				// app): the target comes from the wire and this process
				// survives the install. kind=player is the self-update.
				if (installTarget.isNotEmpty()) {
					setAppPackageName(installTarget)
				} else {
					setAppPackageName(context.packageName)
				}
				setSize(apk.length())
				if (Build.VERSION.SDK_INT >= 31) {
					// Installer-of-record self-updates apply with no user
					// interaction; everything else (including foreign
					// packages) falls back to the confirmation sheet,
					// surfaced as pending_user -> installed / failure.
					setRequireUserAction(
						PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
				}
			}
			val sessionId = installer.createSession(params)
			installer.openSession(sessionId).use { session ->
				session.openWrite("player.apk", 0, apk.length()).use { out ->
					apk.inputStream().use { it.copyTo(out) }
					session.fsync(out)
				}
				// A silent self-update kills this process during commit, so
				// the "committed" status must be on the wire first. The relay
				// socket send is async — give OkHttp a beat to flush.
				status(transferId, "committed")
				if (foreign) Thread.sleep(500)
				val intent = Intent(context, UpdateResultReceiver::class.java)
					.setAction(UpdateResultReceiver.ACTION)
				val pending = PendingIntent.getBroadcast(
					context,
					sessionId,
					intent,
					PendingIntent.FLAG_UPDATE_CURRENT or
						PendingIntent.FLAG_MUTABLE,
				)
				session.commit(pending.intentSender)
			}
			Log.i(TAG, "install session committed")
		} catch (e: Exception) {
			Log.w(TAG, "install failed: $e")
			fail("PackageInstaller rejected the update: $e")
		}
	}

	fun onPendingUser() {
		status(transferId, "pending_user")
	}

	fun onInstalled() {
		finished = true
		status(transferId, "installed")
		Log.i(TAG, "foreign package install confirmed")
	}

	fun onInstallFailed(message: String) {
		fail(message)
	}

	// Callers may or may not hold the monitor; status/cleanup are safe either
	// way (send goes straight to the socket, file deletion is idempotent).
	private fun fail(message: String) {
		finished = true
		status(transferId, "failure", message)
		closeQuietly()
	}

	private fun closeQuietly() {
		try { output?.close() } catch (_: Exception) {}
		output = null
		file?.delete()
	}

	private fun status(id: Int, state: String, message: String? = null) {
		val payload = JSONObject().put("t", "update_status").put("id", id)
			.put("state", state)
		if (message != null) payload.put("message", message)
		try {
			sendText(payload.toString())
		} catch (e: Exception) {
			Log.w(TAG, "could not send update status: $e")
		}
	}

	private fun encodeAck(channel: Int, n: Int): ByteArray =
		ByteBuffer.allocate(9).put(OP_ACK.toByte()).putInt(channel).putInt(n)
			.array()
}

/**
 * PackageInstaller's commit callback. STATUS_PENDING_USER_ACTION carries the
 * system confirmation intent that must be launched for a first-time or
 * signature-changing install; a successful silent self-update kills the
 * process before any success broadcast is observed.
 */
class UpdateResultReceiver : BroadcastReceiver() {
	companion object {
		const val ACTION = "dev.rhr.rhr_player.UPDATE_RESULT"
	}

	override fun onReceive(context: Context, intent: Intent) {
		val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -1)
		when (status) {
			PackageInstaller.STATUS_PENDING_USER_ACTION -> {
				@Suppress("DEPRECATION")
				val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
				if (confirm != null) {
					confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
					RhrPlayerUpdater.active?.onPendingUser()
					context.startActivity(confirm)
				}
			}
			PackageInstaller.STATUS_SUCCESS -> {
				// Unreachable for self-updates (the process dies first), but
				// THE terminal state for foreign packages (kind=app): the
				// wrapped app installed successfully.
				RhrPlayerUpdater.active?.onInstalled()
			}
			else -> {
				val message = intent.getStringExtra(
					PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "status $status"
				RhrPlayerUpdater.active?.onInstallFailed(message)
			}
		}
	}
}
