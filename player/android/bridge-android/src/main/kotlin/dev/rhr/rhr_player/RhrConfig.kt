package dev.rhr.rhr_player

import android.content.Context

/**
 * Library configuration, read from the HOST app's string resources so a
 * wrapped app needs zero code: everything is baked at build time (by
 * `rhr wrap`'s init script) as resValue entries.
 *
 * Resource names (all optional; blanks mean "not provided"):
 *   rhr_flutter_version / rhr_framework_revision / rhr_engine_revision /
 *   rhr_dart_sdk_version / rhr_channel / rhr_android_plugins_json
 *       — the compatibility report announced in the session hello. The player
 *         mirrors its BuildConfig identity into these via resValue; wrapped
 *         apps get the project's pinned SDK identity baked by the CLI.
 *   rhr_host          — "player" (default) or "app" (wrapped app; the dev-side
 *                       gate treats this as exact-match-by-construction).
 *   rhr_relay_url     — relay to dial for auto-start. Blank => the host drives
 *                       sessions itself (the player's lobby does), and
 *                       RhrBridgeInit no-ops.
 *   rhr_session_code  — pairing code for auto-start.
 *   rhr_prefer_direct — "true" to offer the WebRTC direct payload path.
 *
 * Lookups are by name (getIdentifier) because these resources live in the
 * host app, not in the library's own R class.
 */
object RhrConfig {
	private fun res(ctx: Context, name: String): String {
		val id = ctx.resources.getIdentifier(name, "string", ctx.packageName)
		return if (id == 0) "" else try {
			ctx.resources.getString(id)
		} catch (_: Exception) {
			""
		}
	}

	fun flutterVersion(ctx: Context): String = res(ctx, "rhr_flutter_version")
	fun frameworkRevision(ctx: Context): String = res(ctx, "rhr_framework_revision")
	fun engineRevision(ctx: Context): String = res(ctx, "rhr_engine_revision")
	fun dartSdkVersion(ctx: Context): String = res(ctx, "rhr_dart_sdk_version")
	fun channel(ctx: Context): String = res(ctx, "rhr_channel")
	fun androidPluginsJson(ctx: Context): String = res(ctx, "rhr_android_plugins_json")

	/** "player" for the rhr player itself, "app" for a wrapped host app. */
	fun hostKind(ctx: Context): String = res(ctx, "rhr_host").ifBlank { "player" }

	/** Non-blank turns RhrBridgeInit into an auto-start session bootstrap. */
	fun autoRelayUrl(ctx: Context): String = res(ctx, "rhr_relay_url")
	fun sessionCode(ctx: Context): String = res(ctx, "rhr_session_code")
	fun preferDirect(ctx: Context): Boolean = res(ctx, "rhr_prefer_direct") == "true"
}
