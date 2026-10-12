package dev.rhr.rhr_player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.security.MessageDigest
import java.util.zip.GZIPOutputStream

/** The APK transfer's write chain: gzip in, at most the announced size out. */
class UpdateSinkTest {
	private fun gzip(bytes: ByteArray): ByteArray =
		ByteArrayOutputStream().also { out -> GZIPOutputStream(out).use { it.write(bytes) } }.toByteArray()

	private fun chain(limit: Long, file: ByteArrayOutputStream): Pair<GzipSink, CountingSink> {
		val counting = CountingSink(file, MessageDigest.getInstance("SHA-256"), limit)
		return GzipSink(counting) to counting
	}

	@Test
	fun `an APK of exactly the announced size goes through`() {
		val apk = ByteArray(200_000) { (it % 251).toByte() }
		val file = ByteArrayOutputStream()
		val (sink, counting) = chain(apk.size.toLong(), file)
		sink.write(gzip(apk))
		sink.close()
		assertEquals(apk.size.toLong(), counting.written)
		assertEquals(apk.size, file.size())
	}

	/** A few kilobytes of gzip that inflate far past what was announced. */
	@Test
	fun `inflating past the announced size stops the transfer`() {
		val bomb = gzip(ByteArray(8 * 1024 * 1024))
		val file = ByteArrayOutputStream()
		val (sink, _) = chain(1024 * 1024, file)
		assertThrows(IOException::class.java) { sink.write(bomb) }
		assertEquals(true, file.size() <= 1024 * 1024)
	}

	/** FNAME is zero-terminated; a header that never terminates is refused. */
	@Test
	fun `an endless gzip header is refused`() {
		val header = byteArrayOf(0x1f, 0x8b.toByte(), 8, 0x08, 0, 0, 0, 0, 0, 0)
		val (sink, _) = chain(1024, ByteArrayOutputStream())
		sink.write(header)
		assertThrows(IOException::class.java) { sink.write(ByteArray(128 * 1024) { 'a'.code.toByte() }) }
	}
}
