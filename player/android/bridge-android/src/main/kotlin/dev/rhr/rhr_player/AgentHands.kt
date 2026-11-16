package dev.rhr.rhr_player

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/**
 * What the phone does by itself while RHR Agent is on. Turning the agent on
 * means the user does not want to look at the phone, so a prompt RHR itself
 * raised is answered here, on the phone. It cannot depend on a coding agent
 * noticing the prompt, or on the computer's session still being alive.
 */
object AgentHands {
	private const val TAG = "rhr_agent_hands"
	private const val ANSWER_WAIT_MS = 120_000L
	private const val POLL_MS = 400L
	private const val AFTER_TAP_MS = 1_000L

	/** Whether RHR Agent can see and tap right now. Blocks on a binder call. */
	fun available(context: Context): Boolean = ask(context, JSONObject().put("op", "info")) != null

	/**
	 * Answers what Android puts in front of a committed install: its install
	 * sheet, then Play Protect if it objects. Does nothing if the agent is off,
	 * so they wait for the user as they always have. Stops when [stillWaiting]
	 * turns false.
	 */
	fun confirmInstall(context: Context, stillWaiting: () -> Boolean) {
		Thread({
			try {
				pressConfirm(context, stillWaiting)
			} catch (e: Exception) {
				Log.w(TAG, "could not answer the install sheet: $e")
			}
		}, "rhr-agent-install").start()
	}

	private fun pressConfirm(context: Context, stillWaiting: () -> Boolean) {
		val deadline = System.currentTimeMillis() + ANSWER_WAIT_MS
		// Android's sheet can be followed by Play Protect, so this watches until
		// the install is over rather than stopping after the first tap.
		while (System.currentTimeMillis() < deadline && stillWaiting()) {
			val tree = ask(context, JSONObject().put("op", "tree")) ?: return
			val tap = nextTap(tree.optJSONArray("windows") ?: JSONArray())
			if (tap == null) {
				Thread.sleep(POLL_MS)
				continue
			}
			ask(context, JSONObject().put("op", "tap").put("x", tap.first).put("y", tap.second))
			Thread.sleep(AFTER_TAP_MS)
		}
	}

	private fun nextTap(windows: JSONArray) = installButton(windows) ?: playProtectStep(windows)

	private fun ask(context: Context, request: JSONObject): JSONObject? =
		DeviceEndpoints.askAgent(context, request).optJSONObject("result")

	/** The center of the enabled confirm button on an install sheet in [windows]. */
	internal fun installButton(windows: JSONArray): Pair<Double, Double>? {
		for (w in 0 until windows.length()) {
			val window = windows.getJSONObject(w)
			if (!window.optString("package").contains("packageinstaller")) continue
			val nodes = window.optJSONArray("nodes") ?: continue
			val button = find(nodes) { it.optString("id").endsWith(":id/button1") }
				?: find(nodes) { it.optString("text").lowercase() in CONFIRM_LABELS }
				?: continue
			if (isDisabled(button)) continue
			return center(button)
		}
		return null
	}

	/**
	 * The next step past Play Protect's "App scan recommended" without
	 * uploading the app to Google: open "More details", then its "Install
	 * without scanning" link. English only.
	 */
	internal fun playProtectStep(windows: JSONArray): Pair<Double, Double>? {
		for (w in 0 until windows.length()) {
			val window = windows.getJSONObject(w)
			if (window.optString("package") != "com.android.vending") continue
			val nodes = window.optJSONArray("nodes") ?: continue
			if (find(nodes) { it.optString("text").startsWith("Google Play Protect") } == null) continue
			// The link has no node of its own. It is the last line of its text.
			find(nodes) { it.optString("text").endsWith(INSTALL_WITHOUT_SCAN) }?.let { text ->
				val frame = text.getJSONArray("frame")
				return Pair(
					frame.getDouble(0) + frame.getDouble(2) / 2,
					frame.getDouble(1) + frame.getDouble(3) - LAST_LINE_CENTER,
				)
			}
			find(nodes) { it.optString("text") == "Install anyway" }?.let { return center(it) }
			find(nodes) { it.optString("text") == "More details" }?.let { return center(it) }
		}
		return null
	}

	private const val INSTALL_WITHOUT_SCAN = "Install without scanning"

	/** Half a line of that dialog's body text, as a fraction of the screen. */
	private const val LAST_LINE_CENTER = 0.012

	private fun center(node: JSONObject): Pair<Double, Double> {
		val frame = node.getJSONArray("frame")
		return Pair(
			frame.getDouble(0) + frame.getDouble(2) / 2,
			frame.getDouble(1) + frame.getDouble(3) / 2,
		)
	}

	/** For sheets without Android's standard button id. English only. */
	private val CONFIRM_LABELS = setOf("update", "install")

	private fun find(nodes: JSONArray, matches: (JSONObject) -> Boolean): JSONObject? {
		for (i in 0 until nodes.length()) {
			val node = nodes.getJSONObject(i)
			if (matches(node)) return node
			find(node.optJSONArray("children") ?: continue, matches)?.let { return it }
		}
		return null
	}

	private fun isDisabled(node: JSONObject): Boolean {
		val flags = node.optJSONArray("flags") ?: return false
		return (0 until flags.length()).any { flags.getString(it) == "disabled" }
	}
}
