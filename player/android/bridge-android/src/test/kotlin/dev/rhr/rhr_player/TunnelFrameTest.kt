package dev.rhr.rhr_player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer

class TunnelFrameTest {
	private fun frame(op: Int, channel: Int, payload: ByteArray = ByteArray(0)): ByteArray =
		ByteBuffer.allocate(5 + payload.size).put(op.toByte()).putInt(channel).put(payload).array()

	private fun int(value: Int): ByteArray = ByteBuffer.allocate(4).putInt(value).array()

	/** Every length that used to reach ByteBuffer.wrap past the end. */
	@Test
	fun `short frames parse to null instead of throwing`() {
		for (size in 0..4) assertNull("size $size", TunnelFrame.parse(ByteArray(size)))
		for (size in 5..8) {
			val bytes = ByteArray(size).also { it[0] = TunnelFrame.OP_ACK.toByte() }
			assertNull("ack of $size bytes", TunnelFrame.parse(bytes))
		}
	}

	@Test
	fun `each op takes only its own length`() {
		assertNull((TunnelFrame.parse(frame(TunnelFrame.OP_OPEN, 7)) as TunnelFrame.Open).target)
		assertEquals(1, (TunnelFrame.parse(frame(TunnelFrame.OP_OPEN, 7, byteArrayOf(1))) as TunnelFrame.Open).target)
		assertNull(TunnelFrame.parse(frame(TunnelFrame.OP_OPEN, 7, byteArrayOf(1, 2))))
		assertTrue(TunnelFrame.parse(frame(TunnelFrame.OP_CLOSE, 7)) is TunnelFrame.Close)
		assertNull(TunnelFrame.parse(frame(TunnelFrame.OP_CLOSE, 7, byteArrayOf(1))))
		assertNull(TunnelFrame.parse(frame(TunnelFrame.OP_ACK, 7, ByteArray(5))))
		assertNull(TunnelFrame.parse(frame(99, 7)))
	}

	@Test
	fun `ack carries its count and refuses a negative one`() {
		val ack = TunnelFrame.parse(frame(TunnelFrame.OP_ACK, 3, int(4096))) as TunnelFrame.Ack
		assertEquals(3, ack.channel)
		assertEquals(4096, ack.bytes)
		assertNull(TunnelFrame.parse(frame(TunnelFrame.OP_ACK, 3, int(-1))))
	}

	@Test
	fun `data exposes its payload length`() {
		val data = TunnelFrame.parse(frame(TunnelFrame.OP_DATA, 9, ByteArray(100))) as TunnelFrame.Data
		assertEquals(9, data.channel)
		assertEquals(100, data.length)
		assertEquals(0, (TunnelFrame.parse(frame(TunnelFrame.OP_DATA, 9)) as TunnelFrame.Data).length)
	}
}
