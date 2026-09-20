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
import java.io.OutputStream
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
 *   kind="app": the APK is a FOREIGN package delivered through the
 *       player. This process survives the install,
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
		set(value) {
			field = value
			// The overlay labels the transfer from this: replacing the player
			// and installing the developer's own app read very differently to
			// whoever is holding the phone.
			RhrSessionService.updatingForeignApp = value == "app"
		}
	private var installTarget = ""
	private var file: File? = null
	// OutputStream, not FileOutputStream: a gzip transfer inflates through
	// GzipSink on the way to the file.
	private var output: OutputStream? = null

	/** Tail of the write chain, counting and hashing the decoded APK. */
	private var sink: CountingSink? = null
	private var digest: MessageDigest? = null
	private var received = 0L
	private var commitRequested = false
	private var finished = false
	private var lastDataAt = 0L

	/** Wire encoding agreed for this transfer: "gzip" or "identity". */
	private var encoding = "identity"

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
			// An APK stores its native libraries uncompressed so Android can
			// mmap them, which leaves ~a third of the transfer compressible.
			// The dev offers what it can encode; we pick gzip when offered
			// and otherwise stay on the raw stream, so either side can be
			// older than the other.
			val offered = message.optJSONArray("encodings")
			encoding = if (offered != null &&
				(0 until offered.length()).any { offered.optString(it) == "gzip" }
			) "gzip" else "identity"
			val dir = File(context.filesDir, "updates").apply { mkdirs() }
			// One in-flight update at a time; a stale file from a dead
			// transfer is simply overwritten.
			file = File(dir, "player-update.apk")
			// size and sha256 describe the APK, never the wire bytes, so the
			// digest and the byte count both sit AFTER decompression and the
			// verification below is identical either way.
			digest = MessageDigest.getInstance("SHA-256")
			// Counting/hashing sits at the FILE end of the chain, so an
			// identity transfer and a gzip transfer verify identically.
			val counting = CountingSink(FileOutputStream(file), digest!!)
			sink = counting
			output = if (encoding == "gzip") GzipSink(counting) else counting
		}
		active = this
		Log.i(TAG, "update transfer $id started ($size bytes, $encoding)")
		status(id, "ready", encoding = encoding)
	}

	override fun handleData(frame: ByteArray) {
		val id = ByteBuffer.wrap(frame, 1, 4).int
		synchronized(this) {
			if (id != transferId || finished) return
			val n = frame.size - 5
			try {
				// expectedSize and expectedSha256 describe the APK, so both
				// must be measured on the decoded bytes. Under gzip the wire
				// frame is neither the right length nor the right content —
				// the sink reports what actually reached the file.
				output?.write(frame, 5, n)
				received = sink?.written ?: (received + n)
			} catch (e: Exception) {
				Log.w(TAG, "update write failed: $e")
				fail("could not write the APK on the device: $e")
				return
			}
			lastDataAt = System.currentTimeMillis()
			// Flow control is a wire-level window, so it acks wire bytes.
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
			// Closing flushes the inflater's tail, so the final count is only
			// authoritative afterwards.
			output?.close()
			output = null
		} catch (_: Exception) {}
		received = sink?.written ?: received
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
		// The bytes are all here. Stop showing a transfer and start showing
		// the install — the tester was reading "54%" at this point, because
		// the transfer's last number was the last thing anyone had said.
		RhrSessionService.setInstallPhase("installing")
		install(apk)
	}

	private fun install(apk: File) {
		try {
			// Declaring REQUEST_INSTALL_PACKAGES is not enough: on Android 8+
			// the user grants it per-app, and a freshly installed player does
			// not have it. Without this check the commit below is refused by
			// the system AFTER we have already reported "committed" (that
			// order is forced — a silent self-update kills this process during
			// commit), so a blocked install reads to the developer as a
			// finished one. Fail honestly instead, and say where to fix it.
			if (!context.packageManager.canRequestPackageInstalls()) {
				fail(
					"this phone does not allow the player to install apps — " +
						"grant \"Install unknown apps\" for RHR Player in " +
						"Settings, then retry",
				)
				return
			}
			val foreign = installKind == "app" && installTarget.isNotEmpty()
			val installer = context.packageManager.packageInstaller
			val params = PackageInstaller.SessionParams(
				PackageInstaller.SessionParams.MODE_FULL_INSTALL
			).apply {
				// kind=app delivers a FOREIGN package: the target comes
				// from the wire and this process survives the install.
				// kind=player is the self-update.
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
		// Android is holding a sheet in front of the tester. Say what it
		// wants, or the phone reads as busy while it is actually waiting.
		RhrSessionService.setInstallPhase("install_confirm")
		status(transferId, "pending_user")
	}

	fun onInstalled() {
		finished = true
		RhrSessionService.setInstallPhase("installed")
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
		// The developer's CLI normally echoes a failure back as the
		// "update_failed" phase, but a failure whose cause IS the socket
		// would never make that round trip — and the phone would sit on a
		// half-drawn bar with the reason in its own hand. Show it here.
		RhrSessionService.setInstallFailed(message)
		status(transferId, "failure", message)
		closeQuietly()
	}

	private fun closeQuietly() {
		try { output?.close() } catch (_: Exception) {}
		output = null
		sink = null
		file?.delete()
	}

	private fun status(
		id: Int,
		state: String,
		message: String? = null,
		encoding: String? = null,
	) {
		val payload = JSONObject().put("t", "update_status").put("id", id)
			.put("state", state)
		if (message != null) payload.put("message", message)
		// The dev only compresses once we have said we can decode it.
		if (encoding != null) payload.put("encoding", encoding)
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
				// delivered app installed successfully.
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

/**
 * Inflates a gzip stream as it is written.
 *
 * `GZIPInputStream` is the usual way to read one, but it pulls from a source
 * and the transfer pushes frames at us as they arrive off the tunnel. Rather
 * than park a thread on a piped stream, this inflates in place: each write
 * feeds the Inflater and drains whatever comes out to the file.
 *
 * Gzip framing is handled by `Inflater(nowrap = false)`... except that Java's
 * Inflater speaks zlib, not gzip, so the 10-byte header is skipped by hand and
 * the trailer is simply never fed (we stop at the Inflater's own end marker).
 */
private class GzipSink(private val sink: OutputStream) : OutputStream() {
    private val inflater = java.util.zip.Inflater(true)
    private val buffer = ByteArray(64 * 1024)
    private val header = java.io.ByteArrayOutputStream()
    private var headerDone = false

    override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)

    override fun write(b: ByteArray, off: Int, len: Int) {
        var start = off
        var count = len
        if (!headerDone) {
            // Buffer until the whole header is in hand. It is 10 bytes plus
            // whatever the FLG byte adds, and frames split anywhere, so this
            // cannot assume one write holds it.
            header.write(b, start, count)
            val consumed = consumeHeader(header.toByteArray()) ?: return
            val pending = header.toByteArray()
            headerDone = true
            header.reset()
            start = consumed
            count = pending.size - consumed
            if (count <= 0) return
            inflate(pending, start, count)
            return
        }
        inflate(b, start, count)
    }

    /**
     * Length of a complete gzip header in [bytes], or null while more is
     * needed. Parsed rather than assumed: Dart writes FLG=0 today, but a
     * header carrying FNAME or an EXTRA field would otherwise be fed to the
     * Inflater as if it were deflate data and corrupt the APK silently.
     */
    private fun consumeHeader(bytes: ByteArray): Int? {
        if (bytes.size < 10) return null
        if (bytes[0] != 0x1f.toByte() || bytes[1] != 0x8b.toByte()) {
            throw java.io.IOException("not a gzip stream")
        }
        val flg = bytes[2 + 1].toInt()
        var at = 10
        if (flg and 0x04 != 0) { // FEXTRA
            if (bytes.size < at + 2) return null
            val xlen = (bytes[at].toInt() and 0xff) or
                ((bytes[at + 1].toInt() and 0xff) shl 8)
            at += 2 + xlen
        }
        if (flg and 0x08 != 0) { // FNAME
            at = skipZeroTerminated(bytes, at) ?: return null
        }
        if (flg and 0x10 != 0) { // FCOMMENT
            at = skipZeroTerminated(bytes, at) ?: return null
        }
        if (flg and 0x02 != 0) at += 2 // FHCRC
        return if (bytes.size < at) null else at
    }

    private fun skipZeroTerminated(bytes: ByteArray, from: Int): Int? {
        var i = from
        while (i < bytes.size) {
            if (bytes[i] == 0.toByte()) return i + 1
            i++
        }
        return null
    }

    private fun inflate(b: ByteArray, off: Int, len: Int) {
        inflater.setInput(b, off, len)
        while (!inflater.finished()) {
            val n = inflater.inflate(buffer)
            if (n == 0) {
                if (inflater.needsInput() || inflater.needsDictionary()) break
            } else {
                sink.write(buffer, 0, n)
            }
        }
    }

    override fun flush() = sink.flush()

    override fun close() {
        try {
            inflater.end()
        } finally {
            sink.close()
        }
    }
}

/**
 * Counts and hashes what actually reaches the file.
 *
 * Under a compressed transfer the bytes arriving off the tunnel are neither
 * the APK's length nor its content, but `size`/`sha256` describe the APK. So
 * verification hangs off this, the last link in the chain, and is identical
 * whether or not the transfer was compressed.
 */
private class CountingSink(
    private val sink: OutputStream,
    private val digest: MessageDigest,
) : OutputStream() {
    var written = 0L
        private set

    override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)

    override fun write(b: ByteArray, off: Int, len: Int) {
        sink.write(b, off, len)
        digest.update(b, off, len)
        written += len
    }

    override fun flush() = sink.flush()
    override fun close() = sink.close()
}
