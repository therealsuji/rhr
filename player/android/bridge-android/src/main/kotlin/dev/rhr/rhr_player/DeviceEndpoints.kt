package dev.rhr.rhr_player

import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.os.Process
import android.system.Os
import android.system.OsConstants
import java.io.ByteArrayInputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.Socket
import org.json.JSONObject

/**
 * The phone end of one tunnel channel: the VM service socket, or a socket pair
 * handed over by another app. Writes to a read-only end are dropped.
 */
internal class ChannelEnd(
	val input: InputStream,
	private val output: OutputStream?,
	private val release: () -> Unit,
) {
	fun write(bytes: ByteArray, offset: Int, length: Int) {
		output?.write(bytes, offset, length)
	}

	fun close() {
		try { release() } catch (_: Exception) {}
	}

	companion object {
		fun of(socket: Socket) = ChannelEnd(socket.getInputStream(), socket.getOutputStream()) { socket.close() }

		/** A socket pair end. Shutting it down wakes a reader blocked on it,
		 *  which closing the descriptor alone does not. */
		fun of(pfd: ParcelFileDescriptor, writable: Boolean) = ChannelEnd(
			FileInputStream(pfd.fileDescriptor),
			if (writable) FileOutputStream(pfd.fileDescriptor) else null,
		) {
			try { Os.shutdown(pfd.fileDescriptor, OsConstants.SHUT_RDWR) } catch (_: Exception) {}
			pfd.close()
		}

		/** An end that says why it could not open, in the device-control
		 *  framing, and then closes. */
		fun refusal(error: String, message: String): ChannelEnd {
			val body = JSONObject().put("id", 0).put("error", error).put("message", message)
				.toString().toByteArray()
			val framed = java.nio.ByteBuffer.allocate(4 + body.size).putInt(body.size).put(body).array()
			return ChannelEnd(ByteArrayInputStream(framed), null) {}
		}
	}
}

/**
 * Opens the tunnel targets that are not the VM service (bridge/lib/tunnel.dart).
 *
 * Device control lives in the RHR Agent, a separate APK: Play Protect blocks
 * browser installs of any APK that declares an accessibility service, so the
 * player a tester downloads cannot carry one. The agent checks that its caller
 * is signed like itself. Its framing (Frames.kt) ends here: the agent gets
 * one binder call per request.
 *
 * Native logs come from the connected app's beacon, which can read its own
 * process's logcat without any permission. The player's own process covers a
 * hosted project.
 */
internal object DeviceEndpoints {
	const val TARGET_DEVICE = 1
	const val TARGET_LOGS = 2
	private const val AGENT_AUTHORITY = "dev.rhr.agent.control"
	private const val ATTACHED = 0

	fun open(context: Context, target: Int, connectedPackage: String?): ChannelEnd = when (target) {
		TARGET_DEVICE -> openAgent(context)
		TARGET_LOGS -> if (connectedPackage != null) openBeaconLogs(context, connectedPackage) else openOwnLogs()
		else -> ChannelEnd.refusal("unknown_target", "This player does not know tunnel target $target.")
	}

	/**
	 * Device control: the tunnel end of a local socket pair, whose other end
	 * a thread here serves by passing each request to the agent as its own
	 * binder call (see the agent's AgentProvider for why).
	 */
	private fun openAgent(context: Context): ChannelEnd {
		val (tunnel, served) = ParcelFileDescriptor.createSocketPair()
		Thread({ serveAgent(context, served) }, "rhr-device-control").start()
		return ChannelEnd.of(tunnel, writable = true)
	}

	private fun serveAgent(context: Context, end: ParcelFileDescriptor) = end.use {
		val input = DataInputStream(FileInputStream(end.fileDescriptor))
		val output = DataOutputStream(FileOutputStream(end.fileDescriptor))
		try {
			while (true) {
				val request = Frames.read(input) ?: break
				Frames.write(output, askAgent(context, request))
			}
		} catch (_: Exception) {
			// The tunnel closed its end, or sent something unreadable.
		}
	}

	private fun askAgent(context: Context, request: JSONObject): JSONObject {
		fun refusal(error: String, message: String) =
			JSONObject().put("id", request.optInt("id")).put("error", error).put("message", message)
		if (RhrSessionService.agentStopped) {
			return refusal(
				"agent_stopped",
				"The tester stopped agent control on the phone. It stays off until they connect again.",
			)
		}
		RhrSessionService.agentActed()
		return try {
			context.contentResolver
				.call(Uri.parse("content://$AGENT_AUTHORITY"), "request", request.toString(), null)
				?.getString("response")
				?.let(::JSONObject)
				?: refusal(
					"agent_missing",
					"RHR Agent is not installed on the phone. Install it with install_agent (rhr mcp).",
				)
		} catch (_: SecurityException) {
			refusal(
				"agent_untrusted",
				"RHR Agent on the phone is signed with a different key than this player. Uninstall it on the " +
					"phone, then install it again with install_agent (rhr mcp).",
			)
		} catch (_: IllegalArgumentException) {
			// The resolver's answer to an authority no installed app provides.
			refusal(
				"agent_missing",
				"RHR Agent is not installed on the phone. Install it with install_agent (rhr mcp).",
			)
		}
	}

	private fun openBeaconLogs(context: Context, pkg: String): ChannelEnd {
		val answer = try {
			context.contentResolver.call(Uri.parse("content://$pkg.rhrbeacon"), "logs", null, null)
		} catch (_: Exception) {
			null
		}
		val end = answer?.let(::socketFrom)
		return end ?: ChannelEnd.refusal(
			"logs_unavailable",
			"$pkg did not hand over its logs. Run rhr again to rebuild it with the current beacon.",
		)
	}

	/** A hosted project runs in the player's own process. */
	private fun openOwnLogs(): ChannelEnd {
		val logcat = ProcessBuilder("logcat", "--pid=${Process.myPid()}", "-v", "threadtime", "-T", "500")
			.redirectErrorStream(true).start()
		return ChannelEnd(logcat.inputStream, null) { logcat.destroy() }
	}

	private fun socketFrom(answer: Bundle): ChannelEnd? {
		val pfd = if (android.os.Build.VERSION.SDK_INT >= 33) {
			answer.getParcelable("socket", ParcelFileDescriptor::class.java)
		} else {
			@Suppress("DEPRECATION")
			answer.getParcelable("socket")
		} ?: return null
		// The attach byte: once it arrives, the other app knows this process
		// holds its own copy of the socket and closes the one it handed over.
		// Only then does this end closing (or this process dying) reach it.
		FileOutputStream(pfd.fileDescriptor).write(ATTACHED)
		return ChannelEnd.of(pfd, writable = false)
	}
}
