package dev.rhr.rhr_player

import android.app.Activity
import android.content.Context
import android.graphics.PixelFormat
import android.os.Build
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout

/**
 * Where a [DevOverlay]'s view tree lives.
 *
 * The overlay itself is identical in both modes — same bubble, same shake,
 * same connection panel. Only the window differs, and that difference is
 * forced by what is on screen: in hosted mode the guest app runs inside the
 * player's own Activity, while in connector mode the tester is looking at a
 * completely different process.
 */
interface OverlayHost {
	/**
	 * The container the overlay builds into. The system host returns a
	 * pass-through root so it cannot steal the tester's touches.
	 */
	fun createRoot(context: Context): FrameLayout

	fun add(root: View)
	fun remove(root: View)

	/**
	 * Show [child] at ([x], [y]) with the given size.
	 *
	 * In an Activity the view simply becomes visible inside the shared root.
	 * In a system overlay it gets its OWN window of exactly that size, so no
	 * touch outside it is ever routed to us.
	 */
	fun showChild(child: View, x: Int, y: Int, width: Int, height: Int, touchable: Boolean = true) {}

	/** Counterpart to [showChild]. */
	fun hideChild(child: View) {}

	/** Show a full-screen, deliberately touch-capturing view (the panel). */
	fun showModal(view: View) {}

	/** Counterpart to [showModal]. */
	fun hideModal(view: View) {}

	/** Invoked when the system back key reaches an open modal. */
	var onBackPressed: (() -> Unit)?

	/** True for system windows above a separate debug app. */
	val transient: Boolean
}

/** Hosted mode: the player's own Activity. No permission required. */
class ActivityOverlayHost(private val activity: Activity) : OverlayHost {
	// The Activity handles its own back key; nothing to route here.
	override var onBackPressed: (() -> Unit)? = null

	// Our own screen: status chrome is welcome here.
	override val transient = false

	// A plain root is fine: this window IS our Activity, which already owns
	// the touches it receives.
	override fun createRoot(context: Context) = FrameLayout(context)

	override fun add(root: View) {
		activity.addContentView(
			root,
			FrameLayout.LayoutParams(
				ViewGroup.LayoutParams.MATCH_PARENT,
				ViewGroup.LayoutParams.MATCH_PARENT))
	}

	override fun remove(root: View) {
		(root.parent as? ViewGroup)?.removeView(root)
	}

	// Inside our own Activity every piece already lives in the shared root, so
	// showing and hiding is just visibility — the Activity owns the touches
	// either way.
	override fun showChild(child: View, x: Int, y: Int, width: Int, height: Int, touchable: Boolean) {
		child.visibility = View.VISIBLE
	}

	override fun hideChild(child: View) {
		child.visibility = View.GONE
	}
}


/**
 * Connector mode: floating windows above whatever app the tester is using.
 *
 * Modelled on how chat heads have always done this. The mistake worth naming,
 * because two earlier attempts here made it: do NOT add one full-screen window
 * and try to make parts of it transparent to touch. Android decides touch
 * routing per WINDOW, before any view sees the event, so a full-screen window
 * is either greedy (it eats taps meant for the app below) or inert (the bubble
 * itself cannot be tapped). View-level hit testing cannot undo that, and
 * flipping FLAG_NOT_TOUCHABLE on the whole window just swaps one failure for
 * the other.
 *
 * The fix is geometry, not flags: give each piece of chrome its OWN window,
 * sized to its content. A 46dp bubble occupies a 46dp window, so every pixel
 * outside it belongs to the app underneath and is never routed here at all.
 * Dragging moves the WINDOW (via updateViewLayout) rather than a margin.
 *
 * Two windows are used:
 *  - the bubble: small, touchable, added only while visible.
 *  - the panel: full-screen and touchable, but added ONLY while the panel is
 *    open, which is exactly when it should capture taps (it has a scrim).
 */
class SystemOverlayHost(private val context: Context) : OverlayHost {
	override var onBackPressed: (() -> Unit)? = null

	override val transient = true

	// Content-sized windows mean no stray touch surface, so the root can be a
	// plain container.
	override fun createRoot(context: Context) = FrameLayout(context)

	private val windowManager =
		context.getSystemService(Context.WINDOW_SERVICE) as WindowManager

	/** Views currently added to the window manager, by the child they host. */
	private val windows = mutableMapOf<View, View>()

	override fun add(root: View) {
		// Nothing yet: children are given windows individually as they appear.
	}

	override fun remove(root: View) {
		windows.values.toList().forEach { detachWindow(it) }
		windows.clear()
	}

	/**
	 * Puts [child] on screen in its own window at [x], [y] (top-left, pixels).
	 * Re-positions instead of re-adding when the child is already showing, so
	 * a drag is a cheap layout update.
	 */
	override fun showChild(child: View, x: Int, y: Int, width: Int, height: Int, touchable: Boolean) {
		val existing = windows[child]
		if (existing != null) {
			val params = existing.layoutParams as WindowManager.LayoutParams
			params.x = x
			params.y = y
			runCatching { windowManager.updateViewLayout(existing, params) }
			return
		}
		(child.parent as? ViewGroup)?.removeView(child)
		val holder = FrameLayout(context).apply { addView(child) }
		val params = WindowManager.LayoutParams(
			width,
			height,
			WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
			// Progress passes touches through; the bubble remains interactive.
			WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
				WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
				(if (touchable) 0 else WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE),
			PixelFormat.TRANSLUCENT,
		).apply {
			gravity = Gravity.TOP or Gravity.START
			this.x = x
			this.y = y
			// Android permits touches through an untrusted overlay at this opacity.
			if (!touchable) alpha = 0.8f
		}
		windows[child] = holder
		addWindow(holder, params)
	}

	/** Takes [child] off screen; its window disappears with it. */
	override fun hideChild(child: View) {
		val holder = windows.remove(child) ?: return
		detachWindow(holder)
	}

	/**
	 * A full-screen, touchable window for the connection panel. Correct to be
	 * greedy: the panel has a scrim and tapping outside it should close the
	 * panel, not fall through to the app.
	 */
	override fun showModal(view: View) {
		if (windows.containsKey(view)) return
		(view.parent as? ViewGroup)?.removeView(view)
		// A focusable overlay receives the back key, and a panel that ignores
		// back is a trap: the tester's usual way out of a sheet does nothing.
		val holder = object : FrameLayout(context) {
			override fun dispatchKeyEvent(event: android.view.KeyEvent): Boolean {
				if (event.keyCode == android.view.KeyEvent.KEYCODE_BACK &&
					event.action == android.view.KeyEvent.ACTION_UP
				) {
					onBackPressed?.invoke()
					return true
				}
				return super.dispatchKeyEvent(event)
			}
		}.apply { addView(view) }
		val params = WindowManager.LayoutParams(
			WindowManager.LayoutParams.MATCH_PARENT,
			WindowManager.LayoutParams.MATCH_PARENT,
			WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
			WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
			PixelFormat.TRANSLUCENT,
		).apply { gravity = Gravity.TOP or Gravity.START }
		windows[view] = holder
		addWindow(holder, params)
	}

	// A rejected window (permission revoked mid-session, a bad token) used to
	// fail silently, which reads as "the shake did nothing". Keep it from
	// crashing the service, but say so.
	private fun addWindow(holder: View, params: WindowManager.LayoutParams) {
		runCatching { windowManager.addView(holder, params) }
			.onFailure { android.util.Log.w("rhr_overlay", "window rejected", it) }
	}

	override fun hideModal(view: View) = hideChild(view)

	private fun detachWindow(holder: View) {
		(holder as? ViewGroup)?.removeAllViews()
		runCatching { windowManager.removeView(holder) }
	}

	companion object {
		/**
		 * True when this app may draw over other apps. Always false until the
		 * user grants it on the settings screen [permissionIntent] opens —
		 * there is no runtime prompt for this one.
		 */
		fun granted(context: Context): Boolean =
			Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
				Settings.canDrawOverlays(context)

		/** The system screen where the user turns the permission on. */
		fun permissionIntent(context: Context) = android.content.Intent(
			Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
			android.net.Uri.parse("package:${context.packageName}"),
		)
	}
}
