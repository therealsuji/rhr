package dev.rhr.rhr_player

import android.content.Context
import android.util.Base64
import java.security.SecureRandom

/**
 * This player installation's identity, as far as the account service is
 * concerned.
 *
 * An INSTALLATION, deliberately, not a phone. Hardware identifiers are a
 * privacy problem, they are increasingly restricted on modern Android, and
 * they promise something this system cannot honour — that this is "the same
 * physical device forever". Reinstalling or clearing app data yields a new
 * identity and requires joining again, which is a rule that can be explained
 * in one sentence and is always true.
 *
 * The id names the installation and travels in the clear; the secret proves
 * the installation is the one it claims to be, and never leaves the device
 * except as a proof. Both are generated on first use and then fixed.
 */
object InstallationIdentity {
	private const val PREFS = "rhr_identity"
	private const val KEY_ID = "installation_id"
	private const val KEY_SECRET = "installation_secret"

	/** 256 bits, the same strength as the pair secret it will authenticate. */
	private const val SECRET_BYTES = 32

	/** Long enough to be unguessable, short enough to log without wrapping. */
	private const val ID_BYTES = 16

	/**
	 * Stable public identifier for this installation.
	 *
	 * Safe to log and to send: it says which installation is speaking, not that
	 * the speaker is genuine.
	 */
	fun id(context: Context): String = value(context, KEY_ID, ID_BYTES)

	/**
	 * Secret this installation authenticates with.
	 *
	 * Private app storage rather than the Android keystore: the tunnel this
	 * guards already grants VM-service access to anything running as this app,
	 * so a keystore-backed key would raise the bar against an attacker who has
	 * already cleared a higher one. Revisit if the threat model changes.
	 */
	fun secret(context: Context): String = value(context, KEY_SECRET, SECRET_BYTES)

	/** True once this installation has an identity, without creating one. */
	fun exists(context: Context): Boolean =
		prefs(context).contains(KEY_ID)

	/**
	 * Discards this identity, so the next use mints a fresh one.
	 *
	 * Leaving every account is the tester's way of saying they are done with
	 * this machine; keeping the identity afterwards would let a stale
	 * membership on some server still name them.
	 */
	fun reset(context: Context) {
		prefs(context).edit().remove(KEY_ID).remove(KEY_SECRET).apply()
	}

	private fun value(context: Context, key: String, bytes: Int): String {
		val preferences = prefs(context)
		preferences.getString(key, null)?.let { return it }
		// Synchronised so two callers on first launch cannot mint two identities
		// and have one silently win.
		synchronized(this) {
			preferences.getString(key, null)?.let { return it }
			val fresh = ByteArray(bytes).also { SecureRandom().nextBytes(it) }
			val encoded = Base64.encodeToString(
				fresh, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
			preferences.edit().putString(key, encoded).apply()
			return encoded
		}
	}

	private fun prefs(context: Context) =
		context.applicationContext.getSharedPreferences(
			PREFS, Context.MODE_PRIVATE)
}
