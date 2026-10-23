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

	/**
	 * A transfer cut short and resumed: the first stream stops part-way, and
	 * a fresh gzip of the rest is appended after the bytes already written.
	 */
	@Test
	fun `a resumed transfer ends with the whole APK and its digest`() {
		val apk = ByteArray(300_000) { (it * 7 % 251).toByte() }
		val kept = 120_000
		val file = ByteArrayOutputStream()
		val (first, _) = chain(apk.size.toLong(), file)
		first.write(gzip(apk.copyOf(kept)))
		first.close()

		val digest = MessageDigest.getInstance("SHA-256").apply { update(file.toByteArray()) }
		val counting = CountingSink(file, digest, apk.size.toLong(), start = kept.toLong())
		val rest = GzipSink(counting)
		rest.write(gzip(apk.copyOfRange(kept, apk.size)))
		rest.close()

		assertEquals(apk.size.toLong(), counting.written)
		assertEquals(apk.toList(), file.toByteArray().toList())
		assertEquals(
			MessageDigest.getInstance("SHA-256").digest(apk).toList(),
			digest.digest().toList(),
		)
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
