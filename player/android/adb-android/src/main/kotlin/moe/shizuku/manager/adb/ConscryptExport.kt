package moe.shizuku.manager.adb

import android.util.Log
import java.net.Socket
import javax.net.ssl.SSLSocket

/**
 * Conscrypt's TLS keying-material export (RFC 5705/8446) — the ADB pairing
 * protocol derives the SPAKE2 password from it.
 *
 * This code was vendored with a COMPILE-TIME call to the static helper
 * `com.android.org.conscrypt.Conscrypt.exportKeyingMaterial(SSLSocket,
 * String, byte[], int)`. That signature no longer exists on newer platform
 * images (Android 16: NoSuchMethodError at runtime — a crash AFTER the TLS
 * handshake succeeded, killing the whole process mid-pairing). The static
 * helper was always a thin unwrap-and-delegate over an instance method on
 * the Conscrypt socket, so resolve whatever variant the RUNNING platform
 * actually has, via reflection, in this order:
 *
 *   1. instance method on the socket (walking up its class hierarchy):
 *      exportKeyingMaterial(String, byte[], int) / (String, byte[]) / (String)
 *   2. static Conscrypt.exportKeyingMaterial(Socket, String, byte[], int)
 *      / (Socket, String, byte[])
 *
 * Fails with a clear (catchable) exception when none exists — never an
 * Error that can take the process down.
 */
object ConscryptExport {
	private const val TAG = "AdbPairClient"

	fun exportKeyingMaterial(
		socket: SSLSocket, label: String, context: ByteArray?, length: Int,
	): ByteArray {
		// (a) Instance methods on the (platform) Conscrypt socket classes.
		var c: Class<*>? = socket.javaClass
		while (c != null && c != Any::class.java) {
			for (m in c.declaredMethods) {
				if (m.name != "exportKeyingMaterial") continue
				val p = m.parameterTypes
				try {
					m.isAccessible = true
					when {
						p.size == 3 && p[0] == String::class.java &&
							p[1] == ByteArray::class.java &&
							p[2] == Int::class.javaPrimitiveType ->
							return m.invoke(socket, label, context, length) as ByteArray

						p.size == 2 && p[0] == String::class.java &&
							p[1] == ByteArray::class.java ->
							return m.invoke(socket, label, context) as ByteArray

						p.size == 1 && p[0] == String::class.java ->
							return m.invoke(socket, label) as ByteArray
					}
				} catch (e: IllegalAccessException) {
					Log.w(TAG, "exportKeyingMaterial instance call blocked: $e")
				} catch (e: java.lang.reflect.InvocationTargetException) {
					Log.w(TAG, "exportKeyingMaterial(${p.joinToString()}) threw: ${e.targetException}")
				}
			}
			c = c.superclass
		}

		// (b) Static exportKeyingMaterial helpers — bundled Conscrypt
		// first (guaranteed shape), then the platform one (older images).
		for (name in listOf("org.conscrypt.Conscrypt", "com.android.org.conscrypt.Conscrypt")) {
			val conscrypt = try {
				Class.forName(name)
			} catch (_: ClassNotFoundException) {
				continue
			}
			for (m in conscrypt.declaredMethods) {
				if (m.name != "exportKeyingMaterial") continue
				val p = m.parameterTypes
				try {
					m.isAccessible = true
					when {
						p.size == 4 && Socket::class.java.isAssignableFrom(p[0]) &&
							p[1] == String::class.java && p[2] == ByteArray::class.java &&
							p[3] == Int::class.javaPrimitiveType ->
							return m.invoke(null, socket, label, context, length) as ByteArray

						p.size == 3 && Socket::class.java.isAssignableFrom(p[0]) &&
							p[1] == String::class.java && p[2] == ByteArray::class.java ->
							return m.invoke(null, socket, label, context) as ByteArray
					}
				} catch (e: IllegalAccessException) {
					Log.w(TAG, "exportKeyingMaterial static call blocked: $e")
				}
			}
		}

		throw IllegalStateException(
			"Conscrypt.exportKeyingMaterial is unavailable on this platform " +
				"(socket=${socket.javaClass.name}) — ADB pairing cannot run here")
	}
}
