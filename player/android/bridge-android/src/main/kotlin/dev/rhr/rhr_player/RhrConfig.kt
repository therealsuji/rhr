package dev.rhr.rhr_player

import android.content.Context

/**
 * Library configuration, read from the HOST app's string resources. Both hosts
 * that ship this library — the player and the connector — bake these at build
 * time as resValue entries, so the library itself carries no identity.
 *
 * Resource names (all optional; blanks mean "not provided"):
 *   rhr_flutter_version / rhr_framework_revision / rhr_engine_revision /
 *   rhr_dart_sdk_version / rhr_channel / rhr_android_plugins_json
 *       — the compatibility report announced in the session hello, mirrored
 *         from the host's BuildConfig identity.
 *   rhr_host          — "player" (default) or "connector". The dev side gates
 *                       on the player's identity and skips the gate entirely
 *                       for the connector, which tunnels a third-party VM.
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

	/** "player" for the rhr player itself, "connector" for the connector. */
	fun hostKind(ctx: Context): String = res(ctx, "rhr_host").ifBlank { "player" }
}
