package dev.rhr.rhr_player

import java.nio.ByteBuffer

/**
 * One binary tunnel frame from the host: `[1B op][4B channel BE][payload]`
 * (bridge/lib/tunnel.dart has the format).
 *
 * Frames arrive off the network, and on the direct path they are handed over
 * inside a WebRTC JNI callback, where an exception does not unwind politely.
 * So every length is checked here, once, and a frame that does not fit its op
 * parses to null instead of reaching code that indexes into it.
 */
internal sealed interface TunnelFrame {
	val channel: Int

	/** [target] is null for the VM service, else a device endpoint byte. */
	class Open(override val channel: Int, val target: Int?) : TunnelFrame

	/** Payload is `frame[HEADER_BYTES until frame.size]`, not copied out. */
	class Data(override val channel: Int, val frame: ByteArray) : TunnelFrame {
		val length: Int get() = frame.size - HEADER_BYTES
	}

	class Close(override val channel: Int) : TunnelFrame

	/** Flow control: the peer consumed [bytes] more bytes of [channel]. */
	class Ack(override val channel: Int, val bytes: Int) : TunnelFrame

	/** An APK chunk; the update handler parses the whole [frame] itself. */
	class UpdateData(override val channel: Int, val frame: ByteArray) : TunnelFrame

	companion object {
		const val HEADER_BYTES = 5
		const val OP_OPEN = 0
		const val OP_DATA = 1
		const val OP_CLOSE = 2
		const val OP_ACK = 3
		const val OP_UPDATE_DATA = 4

		/** The frame, or null when it is malformed or names an unknown op. */
		fun parse(frame: ByteArray): TunnelFrame? {
			if (frame.size < HEADER_BYTES) return null
			val channel = ByteBuffer.wrap(frame, 1, 4).int
			return when (frame[0].toInt()) {
				OP_OPEN -> when (frame.size) {
					HEADER_BYTES -> Open(channel, null)
					HEADER_BYTES + 1 -> Open(channel, frame[HEADER_BYTES].toInt() and 0xff)
					else -> null
				}
				OP_DATA -> Data(channel, frame)
				OP_CLOSE -> if (frame.size == HEADER_BYTES) Close(channel) else null
				OP_ACK -> {
					if (frame.size != HEADER_BYTES + 4) return null
					val bytes = ByteBuffer.wrap(frame, HEADER_BYTES, 4).int
					// A negative count would grow the window it is meant to shrink.
					if (bytes < 0) null else Ack(channel, bytes)
				}
				OP_UPDATE_DATA -> UpdateData(channel, frame)
				else -> null
			}
		}
	}
}
