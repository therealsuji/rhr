package dev.rhr.rhr_player

import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.zip.Deflater
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream

/**
 * The player's half of the CLI's DevFS delta uploads (cli/lib/devfs_upload.dart
 * and devfs_delta.dart hold the format).
 *
 * The CLI rewrites Flutter's DevFS PUT into one carrying `rhr-content-sha256`
 * and, when it knows this phone kept an earlier file, `rhr-delta-base` with a
 * delta body. This rebuilds the file from that base, checks its hash, keeps it
 * as a future base, and produces the plain gzipped PUT the Dart VM expects.
 * A hot restart's 12 MB kernel upload becomes a few kilobytes on the tunnel.
 */
internal object DevFsDelta {
	const val CONTENT_SHA = "rhr-content-sha256"
	const val DELTA_BASE = "rhr-delta-base"
	private const val KEPT_BASES = 3
	private val MAGIC = byteArrayOf(0x52, 0x48, 0x52, 0x44, 0x01)
	private const val OP_COPY = 1
	private const val OP_INSERT = 2
	// Both hashes name files in the store, and they arrive off the tunnel:
	// anything but a SHA-256 in hex could reach outside it ("../").
	private val SHA256_HEX = Regex("^[0-9a-f]{64}$")

	/** The request head, once the bytes so far hold all of it. */
	class Head(val requestLine: String, val headers: Map<String, String>, val bodyStart: Int) {
		val contentLength: Int? get() = headers["content-length"]?.toIntOrNull()
		val isRhrUpload: Boolean get() = headers.containsKey(CONTENT_SHA)
	}

	fun parseHead(bytes: ByteArray, length: Int): Head? {
		var end = -1
		for (i in 0..length - 4) {
			if (bytes[i] == '\r'.code.toByte() && bytes[i + 1] == '\n'.code.toByte() &&
				bytes[i + 2] == '\r'.code.toByte() && bytes[i + 3] == '\n'.code.toByte()) {
				end = i
				break
			}
		}
		if (end < 0) return null
		val lines = String(bytes, 0, end, Charsets.ISO_8859_1).split("\r\n")
		val headers = lines.drop(1).filter { ':' in it }.associate {
			it.substringBefore(':').trim().lowercase() to it.substringAfter(':').trim()
		}
		return Head(lines.first(), headers, end + 4)
	}

	/** What to send the VM for a complete RHR upload, or null when this phone
	 *  lacks the base or the rebuilt file fails its hash: the CLI then resends
	 *  the whole file. */
	class Forward(val head: ByteArray, val body: File?, val inlineBody: ByteArray?)

	fun rebuild(storeDir: File, head: Head, body: ByteArray): Forward? {
		val sha = head.headers[CONTENT_SHA]?.takeIf { SHA256_HEX.matches(it) } ?: return null
		val baseSha = head.headers[DELTA_BASE]
		if (baseSha != null && !SHA256_HEX.matches(baseSha)) return null
		storeDir.mkdirs()
		val part = File(storeDir, "$sha.part")
		val digest = MessageDigest.getInstance("SHA-256")
		try {
			part.outputStream().buffered().use { out ->
				val sink = DigestingStream(out, digest)
				if (baseSha == null) {
					GZIPInputStream(body.inputStream()).use { it.copyTo(sink) }
				} else {
					val base = File(storeDir, baseSha)
					if (!base.exists()) return null
					RandomAccessFile(base, "r").use { applyDelta(it, GZIPInputStream(body.inputStream()), sink) }
				}
			}
			if (digest.digest().joinToString("") { "%02x".format(it) } != sha) return null
			val stored = File(storeDir, sha)
			if (!part.renameTo(stored)) return null
			stored.setLastModified(System.currentTimeMillis())
			prune(storeDir)
			// A whole-file upload is already the gzip the VM wants.
			if (baseSha == null) return Forward(vmHead(head, body.size.toLong()), null, body)
			val gz = File(storeDir, "$sha.gz")
			stored.inputStream().use { input ->
				object : GZIPOutputStream(gz.outputStream().buffered()) {
					init { def.setLevel(Deflater.BEST_SPEED) }
				}.use { input.copyTo(it) }
			}
			return Forward(vmHead(head, gz.length()), gz, null)
		} catch (_: Exception) {
			return null
		} finally {
			part.delete()
		}
	}

	/** The response that makes the CLI resend the whole file. */
	val missingBase: ByteArray =
		"HTTP/1.1 409 Conflict\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
			.toByteArray(Charsets.ISO_8859_1)

	private fun vmHead(head: Head, length: Long): ByteArray {
		val kept = head.headers.filterKeys {
			it != CONTENT_SHA && it != DELTA_BASE && it != "content-length" &&
				it != "transfer-encoding" && it != "connection"
		}
		val text = buildString {
			append(head.requestLine).append("\r\n")
			kept.forEach { (k, v) -> append(k).append(": ").append(v).append("\r\n") }
			append("content-length: ").append(length).append("\r\n")
			append("connection: close\r\n\r\n")
		}
		return text.toByteArray(Charsets.ISO_8859_1)
	}

	private fun applyDelta(base: RandomAccessFile, delta: InputStream, out: OutputStream) {
		val input = DataInputStream(delta.buffered())
		val magic = ByteArray(MAGIC.size)
		input.readFully(magic)
		require(magic.contentEquals(MAGIC)) { "not an RHR DevFS delta" }
		val buffer = ByteArray(64 * 1024)
		while (true) {
			val op = input.read()
			if (op < 0) return
			when (op) {
				OP_COPY -> {
					base.seek(input.readLong())
					var left = input.readInt().toLong() and 0xffffffffL
					while (left > 0) {
						val n = base.read(buffer, 0, minOf(left, buffer.size.toLong()).toInt())
						require(n > 0) { "delta copies past the end of its base" }
						out.write(buffer, 0, n)
						left -= n
					}
				}
				OP_INSERT -> {
					var left = input.readInt().toLong() and 0xffffffffL
					while (left > 0) {
						val n = input.read(buffer, 0, minOf(left, buffer.size.toLong()).toInt())
						require(n > 0) { "delta ends inside an insert" }
						out.write(buffer, 0, n)
						left -= n
					}
				}
				else -> error("unknown DevFS delta op $op")
			}
		}
	}

	/** Keep the newest few files; each is a whole program, tens of megabytes. */
	private fun prune(storeDir: File) {
		storeDir.listFiles { f -> f.isFile && f.name.length == 64 }
			?.sortedByDescending { it.lastModified() }
			?.drop(KEPT_BASES)
			?.forEach { it.delete() }
		storeDir.listFiles { f -> f.name.endsWith(".gz") }?.forEach {
			if (System.currentTimeMillis() - it.lastModified() > 60_000) it.delete()
		}
	}

	private class DigestingStream(
		private val out: OutputStream,
		private val digest: MessageDigest,
	) : OutputStream() {
		override fun write(b: Int) {
			digest.update(b.toByte())
			out.write(b)
		}
		override fun write(b: ByteArray, off: Int, len: Int) {
			digest.update(b, off, len)
			out.write(b, off, len)
		}
	}

	/** Collects one channel's bytes until the request is decided. */
	class Sniffer {
		val bytes = ByteArrayOutputStream()
		var head: Head? = null

		/** True once the first bytes show this is not a PUT at all. */
		fun notAPut(): Boolean {
			val b = bytes.toByteArray()
			val prefix = "PUT ".toByteArray()
			return b.size >= 4 && !b.copyOfRange(0, 4).contentEquals(prefix)
		}
	}
}
