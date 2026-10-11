package dev.rhr.rhr_player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicReference
import java.util.zip.GZIPOutputStream
import kotlin.concurrent.thread
import kotlin.random.Random

class DevFsDeltaTest {
	private fun gzip(bytes: ByteArray): ByteArray =
		ByteArrayOutputStream().also { out -> GZIPOutputStream(out).use { it.write(bytes) } }.toByteArray()

	private fun sha(bytes: ByteArray) =
		MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

	/** Two identical whole-file uploads at once, as overlapping retries send. */
	@Test
	fun identicalUploadsAtOnceBothRebuild() {
		val content = Random(1).nextBytes(4 * 1024 * 1024)
		val body = gzip(content)
		val head = DevFsDelta.Head(
			"PUT / HTTP/1.1",
			mapOf(DevFsDelta.CONTENT_SHA to sha(content), "content-length" to "${body.size}"),
			0,
		)
		repeat(20) { round ->
			val store = Files.createTempDirectory("rhr-bases").toFile()
			try {
				val start = CountDownLatch(1)
				val results = List(2) { AtomicReference<Any?>() }
				val workers = results.map { result ->
					thread {
						start.await()
						result.set(runCatching { DevFsDelta.rebuild(store, head, body) }
							.fold({ it ?: "null (asked for the whole file)" }, { it }))
					}
				}
				start.countDown()
				workers.forEach { it.join() }
				for (result in results) {
					val value = result.get()
					assertNotNull("round $round", value)
					assert(value is DevFsDelta.Forward) { "round $round: $value" }
				}
				assertEquals(sha(content), sha(File(store, sha(content)).readBytes()))
			} finally {
				store.deleteRecursively()
			}
		}
	}
}
