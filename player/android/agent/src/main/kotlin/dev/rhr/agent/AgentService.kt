package dev.rhr.agent

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Path
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.net.Uri
import android.os.Bundle
import android.util.Base64
import android.view.Display
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import java.io.ByteArrayOutputStream
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONObject

/**
 * The accessibility service behind device control. It acts only on requests
 * the player passes through [AgentProvider], and the player passes them only
 * while a developer's session is live. Between sessions it reads nothing and
 * does nothing.
 *
 * Coordinates are fractions of the screen (0–1), the same space as the frames
 * in a tree.
 */
class AgentService : AccessibilityService() {
	companion object {
		/** The bound service, or null while the tester has it turned off. */
		@Volatile
		var running: AgentService? = null
			private set

		/** Android refuses screenshots taken closer together than about 1/3 s. */
		private const val SCREENSHOT_ATTEMPTS = 4
		private const val SCREENSHOT_RETRY_MS = 350L
	}

	override fun onServiceConnected() {
		running = this
	}

	override fun onUnbind(intent: Intent?): Boolean {
		running = null
		return super.onUnbind(intent)
	}

	override fun onDestroy() {
		running = null
		super.onDestroy()
	}

	override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
	override fun onInterrupt() {}

	/**
	 * Performs one device-control request and returns its answer: the id
	 * echoed with a `result`, or an `error` code and a `message`.
	 */
	internal fun answer(request: JSONObject): JSONObject {
		val id = request.optInt("id")
		return try {
			JSONObject().put("id", id).put("result", perform(request))
		} catch (e: AgentError) {
			JSONObject().put("id", id).put("error", e.code).put("message", e.message)
		} catch (e: Exception) {
			JSONObject().put("id", id).put("error", "failed").put("message", e.toString())
		}
	}

	private fun perform(request: JSONObject): JSONObject = when (val op = request.optString("op")) {
		"info" -> info()
		"screenshot" -> screenshot(request.optDouble("scale", 0.5))
		"tree" -> tree()
		"tap" -> gesture(stroke(request.point("x", "y"), durationMs = 60))
		"long_press" -> gesture(stroke(request.point("x", "y"), durationMs = request.optLong("duration_ms", 800)))
		"swipe" -> gesture(
			stroke(request.point("x", "y"), request.point("to_x", "to_y"), request.optLong("duration_ms", 300)),
		)
		"set_text" -> setText(request.getString("text"))
		"global" -> global(request.getString("action"))
		"launch" -> launch(request)
		else -> throw AgentError("unknown_op", "RHR Agent does not know the operation \"$op\".")
	}

	private fun screenSize(): Rect = getSystemService(WindowManager::class.java).maximumWindowMetrics.bounds

	private fun info(): JSONObject {
		val size = screenSize()
		val display = getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)
		return JSONObject()
			.put("width", size.width())
			.put("height", size.height())
			.put("density", resources.displayMetrics.density.toDouble())
			.put("rotation", display.rotation * 90)
			.put("foreground", rootInActiveWindow?.packageName?.toString() ?: JSONObject.NULL)
	}

	private fun screenshot(scale: Double): JSONObject {
		require(scale > 0 && scale <= 1) { "scale must be in (0, 1]" }
		var lastFailure = 0
		repeat(SCREENSHOT_ATTEMPTS) { attempt ->
			if (attempt > 0) Thread.sleep(SCREENSHOT_RETRY_MS)
			val result = CompletableFuture<Any>()
			takeScreenshot(Display.DEFAULT_DISPLAY, mainExecutor, object : TakeScreenshotCallback {
				override fun onSuccess(screenshot: ScreenshotResult) { result.complete(screenshot) }
				override fun onFailure(errorCode: Int) { result.complete(errorCode) }
			})
			when (val outcome = result.get(5, TimeUnit.SECONDS)) {
				is ScreenshotResult -> return encode(outcome, scale)
				is Int -> {
					lastFailure = outcome
					if (outcome != ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT) return@repeat
				}
			}
		}
		throw AgentError("screenshot_failed", "Android refused the screenshot (error $lastFailure).")
	}

	private fun encode(shot: ScreenshotResult, scale: Double): JSONObject {
		val buffer = shot.hardwareBuffer
		val full = buffer.use {
			Bitmap.wrapHardwareBuffer(it, shot.colorSpace)?.copy(Bitmap.Config.ARGB_8888, false)
		} ?: throw AgentError("screenshot_failed", "The screenshot could not be read.")
		val scaled = if (scale == 1.0) full else Bitmap.createScaledBitmap(
			full, (full.width * scale).toInt().coerceAtLeast(1), (full.height * scale).toInt().coerceAtLeast(1), true,
		)
		// JPEG: a full phone screen as PNG is several times the bytes, and an
		// agent reading the screen loses nothing to it.
		val bytes = ByteArrayOutputStream().also { scaled.compress(Bitmap.CompressFormat.JPEG, 80, it) }.toByteArray()
		return JSONObject()
			.put("mime", "image/jpeg")
			.put("width", scaled.width)
			.put("height", scaled.height)
			.put("data", Base64.encodeToString(bytes, Base64.NO_WRAP))
	}

	/** Every window on screen, top-most first, system dialogs included. */
	private fun tree(): JSONObject {
		val size = screenSize()
		val out = JSONArray()
		for (window in windows.sortedByDescending { it.layer }) {
			val root = window.root ?: continue
			val json = JSONObject()
				.put("type", windowType(window.type))
				.put("package", root.packageName?.toString() ?: JSONObject.NULL)
				.put("nodes", JSONArray(UiTree.compact(copy(root), size.width(), size.height())))
			window.title?.let { json.put("title", it.toString()) }
			if (window.isActive) json.put("active", true)
			out.put(json)
		}
		return JSONObject().put("windows", out)
	}

	private fun windowType(type: Int) = when (type) {
		AccessibilityWindowInfo.TYPE_APPLICATION -> "application"
		AccessibilityWindowInfo.TYPE_INPUT_METHOD -> "keyboard"
		AccessibilityWindowInfo.TYPE_SYSTEM -> "system"
		AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY -> "accessibility_overlay"
		AccessibilityWindowInfo.TYPE_SPLIT_SCREEN_DIVIDER -> "split_screen_divider"
		AccessibilityWindowInfo.TYPE_MAGNIFICATION_OVERLAY -> "magnification_overlay"
		else -> "other"
	}

	private fun copy(node: AccessibilityNodeInfo): UiNode {
		val bounds = Rect().also(node::getBoundsInScreen)
		val children = (0 until node.childCount).mapNotNull { node.getChild(it) }
			.filter { it.isVisibleToUser }
			.map(::copy)
		return UiNode(
			className = node.className?.toString(),
			text = node.text?.toString(),
			description = node.contentDescription?.toString(),
			viewId = node.viewIdResourceName,
			left = bounds.left,
			top = bounds.top,
			right = bounds.right,
			bottom = bounds.bottom,
			clickable = node.isClickable,
			longClickable = node.isLongClickable,
			editable = node.isEditable,
			scrollable = node.isScrollable,
			checkable = node.isCheckable,
			checked = node.isChecked,
			focused = node.isFocused,
			enabled = node.isEnabled,
			children = children,
		)
	}

	private fun JSONObject.point(x: String, y: String): Pair<Float, Float> {
		val size = screenSize()
		val fx = getDouble(x)
		val fy = getDouble(y)
		if (fx !in 0.0..1.0 || fy !in 0.0..1.0) {
			throw AgentError("bad_point", "$x and $y are fractions of the screen, from 0 to 1.")
		}
		// A point at exactly 1 lies just off the screen's last pixel.
		return (fx * size.width()).toFloat().coerceAtMost(size.width() - 1f) to
			(fy * size.height()).toFloat().coerceAtMost(size.height() - 1f)
	}

	private fun stroke(
		from: Pair<Float, Float>,
		to: Pair<Float, Float> = from,
		durationMs: Long,
	): GestureDescription.StrokeDescription {
		val path = Path().apply {
			moveTo(from.first, from.second)
			lineTo(to.first, to.second)
		}
		return GestureDescription.StrokeDescription(path, 0, durationMs.coerceIn(1, 10_000))
	}

	private fun gesture(stroke: GestureDescription.StrokeDescription): JSONObject {
		val done = CompletableFuture<Boolean>()
		val sent = dispatchGesture(
			GestureDescription.Builder().addStroke(stroke).build(),
			object : GestureResultCallback() {
				override fun onCompleted(description: GestureDescription) { done.complete(true) }
				override fun onCancelled(description: GestureDescription) { done.complete(false) }
			},
			null,
		)
		if (!sent || !done.get(stroke.duration + 5_000, TimeUnit.MILLISECONDS)) {
			throw AgentError("gesture_cancelled", "Android cancelled the gesture.")
		}
		return JSONObject()
	}

	/** Types into the focused field; the agent taps the field first. */
	private fun setText(text: String): JSONObject {
		val field = windows.firstNotNullOfOrNull { it.root?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) }
			?.takeIf { it.isEditable }
			?: throw AgentError("no_text_field", "No text field has focus. Tap the field first.")
		val args = Bundle().apply {
			putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
		}
		if (!field.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) {
			throw AgentError("set_text_failed", "The focused field did not accept the text.")
		}
		return JSONObject()
	}

	private fun global(action: String): JSONObject {
		val code = when (action) {
			"back" -> GLOBAL_ACTION_BACK
			"home" -> GLOBAL_ACTION_HOME
			"recents" -> GLOBAL_ACTION_RECENTS
			"notifications" -> GLOBAL_ACTION_NOTIFICATIONS
			"quick_settings" -> GLOBAL_ACTION_QUICK_SETTINGS
			else -> throw AgentError(
				"unknown_action",
				"\"$action\" is not one of back, home, recents, notifications, quick_settings.",
			)
		}
		if (!performGlobalAction(code)) throw AgentError("action_failed", "Android refused \"$action\".")
		return JSONObject()
	}

	private fun launch(request: JSONObject): JSONObject {
		val intent = when {
			request.has("package") -> {
				val pkg = request.getString("package")
				packageManager.getLaunchIntentForPackage(pkg)
					?: throw AgentError("not_installed", "$pkg is not installed or has no launcher screen.")
			}
			request.has("url") -> Intent(Intent.ACTION_VIEW, Uri.parse(request.getString("url")))
			else -> throw AgentError("bad_request", "launch takes a package or a url.")
		}
		startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
		return JSONObject()
	}
}

/** A refusal the agent can act on, sent back as its [code] and [message]. */
private class AgentError(val code: String, message: String) : Exception(message)
