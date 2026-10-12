package dev.rhr.rhr_player

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.IntentFilter
import android.os.Build

/**
 * Registers the QA hooks that adb drives with `am broadcast`.
 *
 * Two gates, because either alone leaves a hole on a tester's phone:
 *
 *  - The build. Nothing is registered unless the APK was built with
 *    `-PrhrFaultInjection=true` (BuildConfig.RHR_FAULT_INJECTION). Checking
 *    FLAG_DEBUGGABLE is not enough: the published player is a debug build.
 *  - The sender. An adb broadcast comes from outside this app, so the
 *    receiver has to be exported, and an exported receiver hears every app
 *    on the phone. Requiring DUMP of the sender narrows that to adb's shell
 *    user (and root): DUMP is a signature|privileged|development permission,
 *    so no installed app can hold it unless someone with adb grants it.
 *
 *     flutter build apk --debug -P rhrFaultInjection=true
 *     adb shell am broadcast -a dev.rhr.DEBUG_FAULT --es name phase-building
 */
internal object AdbReceivers {
	private const val SENDER_PERMISSION = Manifest.permission.DUMP

	/** False, and nothing registered, unless this build opted in. */
	fun register(context: Context, receiver: BroadcastReceiver, action: String): Boolean {
		if (!BuildConfig.RHR_FAULT_INJECTION) return false
		val filter = IntentFilter(action)
		if (Build.VERSION.SDK_INT >= 33) {
			context.registerReceiver(
				receiver, filter, SENDER_PERMISSION, null, Context.RECEIVER_EXPORTED)
		} else {
			context.registerReceiver(receiver, filter, SENDER_PERMISSION, null)
		}
		return true
	}
}
