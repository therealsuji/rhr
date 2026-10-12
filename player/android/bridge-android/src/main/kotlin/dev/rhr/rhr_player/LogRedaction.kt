package dev.rhr.rhr_player

/**
 * What the service may write to logcat about its secrets.
 *
 * Logcat ends up in bug reports, screen recordings of `adb logcat`, and QA
 * artifacts. A session code is a bearer token for the phone, and a VM service
 * URI carries the VM's auth token in its path; either one in a log is enough
 * to take over a running app. Logs keep only what tells sessions apart.
 */
internal object LogRedaction {
	private const val SESSION_PREFIX = 8
	private val uriAuthority = Regex("^([A-Za-z][A-Za-z0-9+.-]*://[^/]*)")

	/** "rhr-abcd-efgh-jkmn" -> "rhr-abcd…", "dev-<installation id>" -> "dev-AbCd…". */
	fun session(code: String): String =
		if (code.length > SESSION_PREFIX) code.take(SESSION_PREFIX) + "…" else "…"

	/** "http://127.0.0.1:41235/Xy9_token=/" -> "http://127.0.0.1:41235/…". */
	fun vmUri(uri: String): String =
		uriAuthority.find(uri)?.let { it.groupValues[1] + "/…" } ?: "…"
}
