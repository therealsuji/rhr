package dev.rhr.rhr_player

import android.content.Context
import android.net.Uri
import android.util.Base64
import okhttp3.OkHttpClient
import okhttp3.Request
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager

/**
 * How the phone dials a relay: which relays it may use, how it trusts them,
 * and what it proves to them.
 */
internal object RelayDial {
	/**
	 * Whether the phone may use [relay]. `wss` anywhere; plain `ws` only on
	 * loopback, where the session code never crosses a network. Mirrors
	 * isAllowedRelay in bridge/lib/session_link.dart.
	 */
	fun allowed(relay: String): Boolean {
		val uri = Uri.parse(relay)
		val host = uri.host ?: return false
		if (uri.userInfo != null || uri.fragment != null) return false
		return when (uri.scheme) {
			"wss" -> true
			"ws" -> host == "127.0.0.1" || host == "localhost" || host == "::1"
			else -> false
		}
	}

	/**
	 * The client for [relay]. A relay addressed by IP is the developer's own
	 * LAN relay, which no CA can vouch for, so the session link's [pin] (the
	 * SHA-256 of its certificate) is the only thing it is trusted on. Without
	 * a pin such a relay gets the system's trust, and fails unless it really
	 * has a CA-issued certificate for that address.
	 */
	fun client(base: OkHttpClient, relay: String, pin: String?): OkHttpClient {
		val host = Uri.parse(relay).host ?: return base
		if (pin == null || !isIpLiteral(host)) return base
		val trust = PinnedTrust(pin)
		val tls = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trust), null) }
		return base.newBuilder()
			.sslSocketFactory(tls.socketFactory, trust)
			// The certificate names no address; the pin is what proves this is
			// the relay the link meant, so only the host itself is checked.
			.hostnameVerifier { verified, _ -> verified == host }
			.build()
	}

	/**
	 * The upgrade request for [code] on [relay].
	 *
	 * On its own account rendezvous the phone proves it is the installation
	 * the name was derived from; the relay refuses the device end otherwise,
	 * so nobody can sit on the rendezvous and receive what a developer sends.
	 * The secret goes only to the account service this build trusts.
	 */
	fun request(context: Context, relay: String, code: String): Request {
		val builder = Request.Builder().url("$relay/s/$code/device")
		if (code.startsWith("dev-") && isAccountService(context, relay)) {
			builder.header("x-rhr-installation-secret", InstallationIdentity.secret(context))
		}
		return builder.build()
	}

	private fun isAccountService(context: Context, relay: String): Boolean {
		val service = Uri.parse(RhrConfig.accountService(context))
		val candidate = Uri.parse(relay)
		return candidate.scheme == "wss" && service.scheme == "https" &&
			candidate.host == service.host && candidate.port == service.port
	}

	private fun isIpLiteral(host: String): Boolean =
		host.contains(':') || host.matches(Regex("""\d{1,3}(\.\d{1,3}){3}"""))

	private class PinnedTrust(private val pin: String) : X509TrustManager {
		override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
			val leaf = chain.firstOrNull()
				?: throw CertificateException("relay presented no certificate")
			val digest = MessageDigest.getInstance("SHA-256").digest(leaf.encoded)
			val actual = Base64.encodeToString(
				digest, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
			if (!MessageDigest.isEqual(actual.toByteArray(), pin.toByteArray())) {
				throw CertificateException("relay certificate does not match the session link")
			}
		}

		override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) =
			throw CertificateException("relay connections do not accept client certificates")

		override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
	}
}
