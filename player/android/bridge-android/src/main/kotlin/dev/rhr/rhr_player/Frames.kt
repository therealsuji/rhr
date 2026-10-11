package dev.rhr.rhr_player

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import org.json.JSONObject

/**
 * Device-control framing on the tunnel, mirrored by cli/lib/device_control.dart:
 * a 4-byte big-endian length, then that many bytes of UTF-8 JSON.
 */
internal object Frames {
	private const val MAX_BYTES = 32 * 1024 * 1024

	/** The next message, or null at a clean end of stream. */
	fun read(input: DataInputStream): JSONObject? {
		val length = try {
			input.readInt()
		} catch (_: EOFException) {
			return null
		}
		require(length in 0..MAX_BYTES) { "device-control frame of $length bytes" }
		val bytes = ByteArray(length)
		input.readFully(bytes)
		return JSONObject(String(bytes, Charsets.UTF_8))
	}

	fun write(output: DataOutputStream, message: JSONObject) {
		val bytes = message.toString().toByteArray(Charsets.UTF_8)
		synchronized(output) {
			output.writeInt(bytes.size)
			output.write(bytes)
			output.flush()
		}
	}
}
