package com.android.org.conscrypt

import javax.net.ssl.SSLSocket

/**
 * COMPILE-ONLY STUB of the platform's internal Conscrypt class (the real
 * one lives on the boot classpath of every Android device). Parent-first
 * delegation means the platform class always wins at runtime — this file
 * exists only so the vendored ADB pairing code compiles against the
 * hidden API it uses. Never called from this APK.
 */
object Conscrypt {
    @JvmStatic
    fun exportKeyingMaterial(
        socket: SSLSocket, label: String?, context: ByteArray?, length: Int,
    ): ByteArray = throw UnsupportedOperationException("platform class only")
}
