package dev.rhr.rhr_player

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Drives the QA fault injection from adb, so an automated test does not have
 * to reach it through the UI.
 *
 *     adb shell am broadcast -a dev.rhr.DEBUG_FAULT --es name phase-building
 *
 * The same faults are reachable by tapping the lobby footer seven times, and
 * that is how a person uses them. A test should not: seven taps have to all
 * land to count, nothing on screen says how many did, and a flow that loses
 * one ends up somewhere it cannot describe. The first recorded QA flow failed
 * that way on a cold run, which is what this exists to stop.
 *
 * Never in the manifest. The host registers it at runtime, and only in a
 * build that opted into fault injection: the player's MainActivity does so
 * through AdbReceivers, which also requires the sender to hold DUMP so only
 * adb's shell can reach it. A debuggable flag is no gate, because the
 * published player is itself a debug build.
 */
class DebugFaultReceiver : BroadcastReceiver() {
	override fun onReceive(context: Context, intent: Intent) {
		if (intent.action != ACTION) return
		val name = intent.getStringExtra("name") ?: return
		Log.i(TAG, "fault from broadcast: $name")
		RhrSessionService.debugInjectFault(name)
	}

	companion object {
		const val ACTION = "dev.rhr.DEBUG_FAULT"
		private const val TAG = "rhr_debug_fault"
	}
}
