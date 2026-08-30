package dev.rhr.rhr_player

import android.app.Activity
import android.app.Application
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Zero-code entry point for wrapped apps. Runs at process start, before any
 * Activity; if the host baked rhr_relay_url + rhr_session_code resources, it
 * starts the session service, which dials out and awaits the developer.
 *
 * The player never bakes those resources, so this no-ops there and the
 * lobby keeps driving sessions explicitly.
 *
 * FGS-start rules: a cold process created for an Activity launch is NOT yet
 * foreground-eligible when ContentProviders run (verified on Android 16:
 * ForegroundServiceStartNotAllowedException). So the start is attempted
 * immediately (covers warm/adb-driven starts where it is allowed) and
 * otherwise deferred to the first Activity resume via lifecycle callbacks —
 * deterministic, no polling, and a background-spawned process simply waits
 * until the user actually opens the app.
 */
class RhrBridgeInit : ContentProvider() {
	override fun onCreate(): Boolean {
		val ctx = context ?: return true
		try {
			val relay = RhrConfig.autoRelayUrl(ctx)
			val code = RhrConfig.sessionCode(ctx)
			if (relay.isBlank() || code.isBlank()) return true // host-driven mode
			val app = ctx.applicationContext as? Application
			if (app == null) {
				tryStart(ctx, relay, code)
				return true
			}
			val done = AtomicBoolean(false)
			app.registerActivityLifecycleCallbacks(
				object : Application.ActivityLifecycleCallbacks {
					override fun onActivityResumed(activity: Activity) {
						if (!done.compareAndSet(false, true)) return
						app.unregisterActivityLifecycleCallbacks(this)
						tryStart(app, relay, code)
					}

					override fun onActivityCreated(
						activity: Activity, savedInstanceState: android.os.Bundle?,
					) {}

					override fun onActivityStarted(activity: Activity) {}

					override fun onActivityPaused(activity: Activity) {}

					override fun onActivityStopped(activity: Activity) {}

					override fun onActivitySaveInstanceState(
						activity: Activity, outState: android.os.Bundle,
					) {}

					override fun onActivityDestroyed(activity: Activity) {}
				})
			// Warm-process / adb-driven path: FGS start may already be allowed.
			tryStart(ctx, relay, code)
		} catch (e: Exception) {
			Log.w("rhr_service", "auto-start failed: $e")
		}
		return true
	}

	private fun tryStart(ctx: android.content.Context, relay: String, code: String) {
		try {
			ctx.startForegroundService(
				Intent(ctx, RhrSessionService::class.java)
					.putExtra("cmd", "start")
					.putExtra("relayUrl", relay)
					.putExtra("code", code)
					.putExtra("vmUri", "")
					.putExtra("preferDirect", RhrConfig.preferDirect(ctx))
			)
			Log.i("rhr_service", "auto-start from baked resources (code $code)")
		} catch (e: Exception) {
			// Expected on cold starts before the first resume; the lifecycle
			// callback retries once the app is visibly foreground.
			Log.i("rhr_service", "auto-start deferred to first resume: $e")
		}
	}

	override fun query(
		uri: Uri, projection: Array<String>?, selection: String?,
		selectionArgs: Array<String>?, sortOrder: String?,
	): Cursor? = null

	override fun getType(uri: Uri): String? = null

	override fun insert(uri: Uri, values: ContentValues?): Uri? = null

	override fun delete(uri: Uri, selection: String?, selectionArgs: Array<String>?): Int = 0

	override fun update(
		uri: Uri, values: ContentValues?, selection: String?,
		selectionArgs: Array<String>?,
	): Int = 0
}
