package dev.rhr.rhr_player

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.util.Log
import android.os.SystemClock
import kotlin.math.sqrt

/**
 * Native dev overlay: shake to reveal a draggable bubble, tap it to see the
 * live connection. Deliberately native rather than Flutter — in hosted mode a
 * guest hot restart swaps the entire Dart kernel (a Flutter-drawn overlay
 * would vanish with it), and in connector mode the foreground app is a
 * different process with no rhr code in it at all.
 *
 * The same view tree serves both modes; only the WINDOW differs, which is what
 * [host] abstracts:
 *
 *  - [ActivityOverlayHost] adds it to the player's own Activity. No permission
 *    needed, but only visible while the player is foreground — right for
 *    hosted mode, where the guest runs inside this very Activity.
 *  - [SystemOverlayHost] puts it in a TYPE_APPLICATION_OVERLAY window so it
 *    floats above the tester's own app — required for connector mode, at the
 *    cost of the "Display over other apps" permission.
 *
 * Design language: dark translucent surfaces, rounded corners, the rhr violet
 * (#7C4DFF) as the single accent, generous padding. Meant to read as a polished
 * product chrome, not a debug widget.
 */
class DevOverlay(
	// A Context, not an Activity: in connector mode the overlay belongs to a
	// foreground service and there is no Activity of ours on screen.
	private val activity: Context,
	private val host: OverlayHost,
) : SensorEventListener {

	constructor(activity: Activity) : this(activity, ActivityOverlayHost(activity))

	/** Views must be touched on the main thread, Activity or not. */
	private val ui = Handler(Looper.getMainLooper())

	private val density = activity.resources.displayMetrics.density
	private fun dp(v: Int): Int = (v * density).toInt()
	private fun dpf(v: Float): Float = v * density

	// ---- palette ----
	private val violet = Color.parseColor("#7C4DFF")
	private val violetSoft = Color.parseColor("#9E7BFF")
	private val ink = Color.parseColor("#F3F1FA")
	private val inkDim = Color.parseColor("#A79FC4")
	private val surface = Color.parseColor("#F21A1330")   // near-opaque card
	private val surfaceHi = Color.parseColor("#2E2350")
	private val trackDim = Color.parseColor("#3A2E63")

	private fun rounded(color: Int, radius: Float): GradientDrawable =
		GradientDrawable().apply {
			setColor(color)
			cornerRadius = radius
		}

	private fun statusBarHeight(): Int {
		val id = activity.resources.getIdentifier(
			"status_bar_height", "dimen", "android")
		return if (id > 0) activity.resources.getDimensionPixelSize(id) else dp(24)
	}

	// Live safe-area insets (status bar / notch on top, nav bar / gesture pill on
	// bottom).
	//
	// These MUST NOT be read from `root`: in connector mode the bubble lives in
	// its own window and `root` is never attached to anything, so
	// rootWindowInsets is null and the old fallback quietly returned a made-up
	// 16dp. On this phone the real nav bar is 135px, so the bottom "hot corner"
	// sat ~68px too low, under the nav bar. WindowManager knows the true insets
	// whether or not any of our views are attached.
	private fun systemBarInsets(): android.graphics.Insets? {
		if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
		val wm = activity.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
			?: return null
		return wm.currentWindowMetrics.windowInsets
			.getInsets(android.view.WindowInsets.Type.systemBars())
	}

	/**
	 * Full screen size in pixels, from the same source as the insets.
	 * resources.displayMetrics can exclude system bars, which would make the
	 * bubble's clamp disagree with the window it actually lives in.
	 */
	private fun screenSize(): Pair<Int, Int> {
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
			val wm = activity.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
			wm?.currentWindowMetrics?.bounds?.let { return Pair(it.width(), it.height()) }
		}
		val m = activity.resources.displayMetrics
		return Pair(m.widthPixels, m.heightPixels)
	}

	private fun safeTop(): Int =
		systemBarInsets()?.top
			?: root.rootWindowInsets?.let {
				@Suppress("DEPRECATION") it.systemWindowInsetTop
			}
			?: statusBarHeight()

	private fun safeBottom(): Int =
		systemBarInsets()?.bottom
			?: root.rootWindowInsets?.let {
				@Suppress("DEPRECATION") it.systemWindowInsetBottom
			}
			?: dp(16)

	// ---- interaction polish ----
	private fun haptic(view: View, strong: Boolean = false) {
		val c = if (strong && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
			HapticFeedbackConstants.CONFIRM else HapticFeedbackConstants.KEYBOARD_TAP
		view.performHapticFeedback(c)
	}

	// ---- animation ----
	//
	// Every animation here is a plain Handler-driven tween. Nothing may sit on
	// the Choreographer or on android.animation, because in connector mode the
	// player is a background process for the whole session, and background
	// processes get no animation frames:
	//
	//  - Android 13+ pauses every android.animation Animator after ~10 s in
	//    the background, and the opt-out API is hidden.
	//  - Samsung's Choreographer drops animation callbacks outright
	//    ("stop animation in background states" in logcat), which also stalls
	//    DynamicAnimation springs. Observed on Android 16: the shake added the
	//    bubble window, the pop-in never ticked, and it sat at alpha 0.
	//
	// Handler messages keep flowing, and a view that changes still invalidates
	// and traverses, so the tween draws. Even if it did not, every state
	// transition below is timed by the same Handler, so nothing depends on a
	// frame arriving. One tween per view: a new one replaces the old.

	private val tweens = HashMap<View, Runnable>()

	/**
	 * Runs [apply] with an eased 0..1 over [durationMs], then [onEnd]. Starting
	 * a new tween on the same view cancels the old one, whose onEnd never runs.
	 */
	private fun tween(
		view: View,
		durationMs: Long,
		ease: (Float) -> Float = ::easeOut,
		onEnd: (() -> Unit)? = null,
		apply: (Float) -> Unit,
	) {
		cancelTween(view)
		val start = SystemClock.uptimeMillis()
		val step = object : Runnable {
			override fun run() {
				val t = ((SystemClock.uptimeMillis() - start).toFloat() / durationMs)
					.coerceIn(0f, 1f)
				apply(ease(t))
				if (t < 1f) {
					ui.postDelayed(this, FRAME_MS)
				} else {
					if (tweens[view] === this) tweens.remove(view)
					onEnd?.invoke()
				}
			}
		}
		tweens[view] = step
		step.run()
	}

	private fun cancelTween(view: View) {
		tweens.remove(view)?.let { ui.removeCallbacks(it) }
	}

	private fun lerp(from: Float, to: Float, t: Float) = from + (to - from) * t

	/** Tween [view]'s alpha and uniform scale from where they are to the targets. */
	private fun tweenTo(
		view: View, alpha: Float, scale: Float, durationMs: Long,
		ease: (Float) -> Float = ::easeOut, onEnd: (() -> Unit)? = null,
	) {
		val a0 = view.alpha; val s0 = view.scaleX
		tween(view, durationMs, ease, onEnd) { t ->
			view.alpha = lerp(a0, alpha, t)
			val sc = lerp(s0, scale, t)
			view.scaleX = sc; view.scaleY = sc
		}
	}

	private fun scaleTo(view: View, scale: Float) = tweenTo(view, view.alpha, scale, 90)

	// A sheet that slides up from translationY while fading in.
	private fun springIn(view: View, fromY: Float) {
		view.translationY = fromY
		view.alpha = 0f
		tween(view, 260, ::easeOutBack) { t ->
			view.alpha = t.coerceAtMost(1f)
			view.translationY = fromY * (1 - t)
		}
	}

	// Simple vector-ish glyphs drawn as text (no asset files needed). Uses a
	// monochrome emoji-free unicode set that renders consistently.
	private fun icon(glyph: String): TextView = TextView(activity).apply {
		text = glyph
		setTextColor(ink)
		textSize = 16f
		gravity = Gravity.CENTER
	}

	private lateinit var root: FrameLayout
	private lateinit var card: LinearLayout
	private lateinit var cardLabel: TextView
	private lateinit var cardPct: TextView
	private lateinit var bar: ProgressBar
	private lateinit var fab: TextView
	private var menu: View? = null

	private val sensors =
		activity.getSystemService(Context.SENSOR_SERVICE) as SensorManager?
	private val shake = ShakeDetector()

	// Bubble position in screen pixels. The single source of truth for both
	// hosts: a system overlay moves its window here, an Activity moves the
	// view's margins to the same place.
	private var fabX = 0
	private var fabY = 0
	private val fabSize get() = dp(46)

	// Whether the bubble is on screen is tracked by the state machine below,
	// never read off fab.visibility: in a system overlay the bubble is hidden
	// by REMOVING ITS WINDOW, which leaves the view's own visibility untouched.

	/**
	 * The "drop here to dismiss" target, shown at the bottom of the screen only
	 * while the bubble is being dragged — the chat-head convention. Lives in its
	 * own window like the bubble does, so it never touches the app underneath.
	 */
	private var dismissTarget: View? = null
	private val dismissSize get() = dp(64)

	fun attach() {
		root = host.createRoot(activity)
		host.add(root)
		// Back closes the panel rather than falling through to the app below.
		host.onBackPressed = { ui.post { closeMenu() } }

		buildProgressCard()
		buildFab()
		render()

		RhrSessionService.onUpdate = { ui.post { render() } }
		sensors?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)?.let {
			// GAME rate (~50 Hz): a shake is a 3-5 Hz oscillation, and the UI
			// rate (~15 Hz) is too coarse to see its direction reversals
			// reliably. Delivered on the main thread so the detector and the
			// bubble state are only ever touched from one thread.
			sensors.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME, ui)
		}
	}

	fun detach() {
		RhrSessionService.onUpdate = null
		sensors?.unregisterListener(this)
		ui.removeCallbacks(idleHide)
		cancelTween(fab)
		snap?.let { ui.removeCallbacks(it) }
		bubble = Bubble.HIDDEN
		// Tearing down mid-drag would otherwise strand the dismiss target on
		// screen with nothing left to remove it.
		hideDismissTarget()
		host.remove(root)
	}

	// ---- progress card (top, floating pill) ------------------------------

	private fun buildProgressCard() {
		card = LinearLayout(activity).apply {
			orientation = LinearLayout.VERTICAL
			background = rounded(surface, dpf(16f))
			elevation = dpf(8f)
			setPadding(dp(16), dp(12), dp(16), dp(14))
			clipToOutline = true
			outlineProvider = ViewOutlineProvider.BACKGROUND
		}

		val header = LinearLayout(activity).apply {
			orientation = LinearLayout.HORIZONTAL
			gravity = Gravity.CENTER_VERTICAL
		}
		// A small violet dot as an activity marker.
		val dot = View(activity).apply {
			background = rounded(violet, dpf(4f))
		}
		header.addView(dot, LinearLayout.LayoutParams(dp(8), dp(8)).apply {
			rightMargin = dp(8)
		})
		cardLabel = TextView(activity).apply {
			setTextColor(ink)
			textSize = 12.5f
			typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
			letterSpacing = 0.01f
		}
		header.addView(
			cardLabel,
			LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
		cardPct = TextView(activity).apply {
			setTextColor(violetSoft)
			textSize = 12.5f
			typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
		}
		header.addView(cardPct)
		card.addView(header, LinearLayout.LayoutParams(
			ViewGroup.LayoutParams.MATCH_PARENT,
			ViewGroup.LayoutParams.WRAP_CONTENT))

		bar = ProgressBar(activity, null, android.R.attr.progressBarStyleHorizontal).apply {
			max = 1000
			// Rounded, violet-on-dim track.
			val track = rounded(trackDim, dpf(3f))
			val prog = android.graphics.drawable.ClipDrawable(
				rounded(violet, dpf(3f)),
				Gravity.START,
				android.graphics.drawable.ClipDrawable.HORIZONTAL)
			progressDrawable = android.graphics.drawable.LayerDrawable(
				arrayOf(track, prog)).apply {
				setId(0, android.R.id.background)
				setId(1, android.R.id.progress)
			}
		}
		card.addView(bar, LinearLayout.LayoutParams(
			ViewGroup.LayoutParams.MATCH_PARENT, dp(6)).apply {
			topMargin = dp(10)
		})

		// GONE, not merely empty. A View defaults to VISIBLE, and this one is
		// MATCH_PARENT wide — left visible in a system overlay window it is an
		// invisible full-width touch target that swallows the tester's taps
		// across the whole screen. render() shows it when there is progress to
		// report (and never at all in connector mode, see showCard).
		card.visibility = View.GONE

		val lp = FrameLayout.LayoutParams(
			ViewGroup.LayoutParams.MATCH_PARENT,
			ViewGroup.LayoutParams.WRAP_CONTENT,
			Gravity.TOP)
		lp.leftMargin = dp(12)
		lp.rightMargin = dp(12)
		root.addView(card, lp)
		// Position below the notch/status bar once insets are available.
		root.post {
			lp.topMargin = safeTop() + dp(10)
			card.layoutParams = lp
		}
	}

	// ---- floating action button ------------------------------------------

	private fun buildFab() {
		fab = TextView(activity).apply {
			text = "rhr"
			setTextColor(Color.WHITE)
			textSize = 13f
			typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
			gravity = Gravity.CENTER
			background = GradientDrawable().apply {
				shape = GradientDrawable.OVAL
				colors = intArrayOf(violetSoft, violet)
				orientation = GradientDrawable.Orientation.TL_BR
				gradientType = GradientDrawable.LINEAR_GRADIENT
			}
			elevation = dpf(6f)
			outlineProvider = ViewOutlineProvider.BACKGROUND
		}
		fabX = dp(16)
		fabY = statusBarHeight() + dp(72)
		fab.visibility = View.GONE   // hidden until a shake reveals it
		// In an Activity the bubble lives in the shared root; in a system
		// overlay showChild() gives it its own window instead, so it must not
		// be pre-parented there.
		if (!host.transient) {
			val lp = FrameLayout.LayoutParams(fabSize, fabSize, Gravity.TOP or Gravity.START)
			lp.leftMargin = fabX
			lp.topMargin = fabY
			root.addView(fab, lp)
		}

		var downX = 0f; var downY = 0f; var startL = 0; var startT = 0
		var moved = false
		fab.setOnTouchListener { v, e ->
			when (e.action) {
				MotionEvent.ACTION_DOWN -> {
					when (bubble) {
						// A window on its way out does not take touches; the
						// tester was aiming at whatever is underneath by now.
						Bubble.HIDDEN, Bubble.HIDING -> return@setOnTouchListener false
						// Tapped mid pop-in: land it and carry on, so a quick
						// tester never has to wait out the animation.
						Bubble.SHOWING -> settleVisible()
						Bubble.VISIBLE -> {}
					}
					ui.removeCallbacks(idleHide)   // never vanish under a finger
					snap?.let { ui.removeCallbacks(it) }   // grabbed mid-snap: finger wins
					downX = e.rawX; downY = e.rawY
					startL = fabX; startT = fabY; moved = false
					scaleTo(v, 0.9f)
					true
				}
				MotionEvent.ACTION_MOVE -> {
					val dx = (e.rawX - downX).toInt(); val dy = (e.rawY - downY).toInt()
					if (kotlin.math.abs(dx) > dp(6) || kotlin.math.abs(dy) > dp(6)) {
						if (!moved) showDismissTarget()   // first real movement
						moved = true
					}
					// Moves the bubble's own window, which is what keeps the
					// touchable area the size of the bubble and no larger.
					moveFab(startL + dx, startT + dy)
					if (moved) {
						// Grow the target and shrink the bubble as they meet, so
						// the drop point is obvious before letting go.
						val over = overDismissTarget()
						dismissTarget?.let { scaleTo(it, if (over) 1.25f else 1f) }
						scaleTo(v, if (over) 0.7f else 0.9f)
					}
					true
				}
				MotionEvent.ACTION_UP -> {
					scaleTo(v, 1f)
					if (!moved) {
						toggleMenu()   // the panel keeps the bubble up while open
					} else if (overDismissTarget()) {
						// Dropped on the target: gone at once, no waiting out
						// the idle timer.
						haptic(v, strong = true)
						hideDismissTarget()
						hide()
						// The next reveal should come back where the bubble used
						// to rest, not on the spot where it was thrown away.
						fabX = startL; fabY = startT
					} else {
						hideDismissTarget()
						snapToCorner()
						armIdleHide(IDLE_MS)
					}
					true
				}
				MotionEvent.ACTION_CANCEL -> {
					scaleTo(v, 1f)
					hideDismissTarget()
					armIdleHide(IDLE_MS)
					true
				}
				else -> false
			}
		}
	}

	// ---- bubble lifecycle ---------------------------------------------------
	//
	// One explicit state machine. The two ways this used to go wrong were both
	// races between an asynchronous callback and a state change it did not
	// know about: a fade-out's end action removing a window that a fresh shake
	// had just re-shown, and a hide timer posted on a view that was not
	// attached yet. So:
	//
	//  - every state change goes through transition(), which bumps `epoch`;
	//  - every animation end action captures the epoch it started under and
	//    does nothing if a transition happened in the meantime;
	//  - the idle timer lives on the main Handler, never on the view, and
	//    transition() always cancels it.
	//
	// Whatever order shakes, taps, timers and animation callbacks arrive in,
	// the bubble is in exactly one of these states and only the newest intent
	// can act on it.

	private enum class Bubble { HIDDEN, SHOWING, VISIBLE, HIDING }

	private var bubble = Bubble.HIDDEN
	private var epoch = 0

	private fun transition(to: Bubble) {
		bubble = to
		epoch++
		ui.removeCallbacks(idleHide)
	}

	private val idleHide = Runnable {
		// Nothing to check here: it is only ever armed in VISIBLE with the
		// panel closed, and transition() and a finger-down both cancel it.
		hide()
	}

	private fun armIdleHide(delayMs: Long) {
		ui.removeCallbacks(idleHide)
		// While the panel is open the bubble stays; closeMenu() re-arms this.
		if (bubble == Bubble.VISIBLE && menu == null) ui.postDelayed(idleHide, delayMs)
	}

	/**
	 * A shake: bring the bubble up, or keep it up a while longer if it is
	 * already there. Never opens the panel; that is a tap on the bubble.
	 *
	 * Not private so a debug build can reach it from `rhr://shake` — a physical
	 * phone cannot have accelerometer samples injected, which would otherwise
	 * leave the bubble, the dev menu and the restart button the only part of
	 * the player no automated check can drive.
	 */
	fun reveal() {
		when (bubble) {
			Bubble.HIDDEN -> {
				// Own small window (system overlay) or plain visibility
				// (Activity). Either way nothing outside the bubble becomes
				// touchable.
				host.showChild(fab, fabX, fabY, fabSize, fabSize)
				fab.visibility = View.VISIBLE
				fab.alpha = 0f
				fab.scaleX = 0.4f; fab.scaleY = 0.4f
				popIn()
			}
			// Caught on the way out: the window is still there, so turn the
			// animation around from wherever it got to. showChild() only
			// re-positions here, in case the resting spot changed meanwhile.
			Bubble.HIDING -> {
				host.showChild(fab, fabX, fabY, fabSize, fabSize)
				popIn()
			}
			Bubble.SHOWING -> {}
			Bubble.VISIBLE -> armIdleHide(IDLE_MS)
		}
		// Feedback goes through the bubble, not `root`: in connector mode root
		// is never attached, and haptics on a detached view are dropped. The
		// post lands once the bubble's window is attached.
		fab.post { haptic(fab, strong = true) }
	}

	private fun popIn() {
		transition(Bubble.SHOWING)
		val started = epoch
		tweenTo(fab, alpha = 1f, scale = 1f, durationMs = 240, ease = ::easeOutBack) {
			if (epoch != started) return@tweenTo
			transition(Bubble.VISIBLE)
			armIdleHide(IDLE_MS)
		}
	}

	/** Skips the rest of the pop-in; used when the tester touches it early. */
	private fun settleVisible() {
		cancelTween(fab)
		fab.alpha = 1f
		fab.scaleX = 1f; fab.scaleY = 1f
		transition(Bubble.VISIBLE)
	}

	/** Shrinks the bubble away and, once gone, removes its window. */
	private fun hide() {
		when (bubble) {
			Bubble.HIDDEN, Bubble.HIDING -> return
			Bubble.SHOWING, Bubble.VISIBLE -> {}
		}
		transition(Bubble.HIDING)
		val started = epoch
		tweenTo(fab, alpha = 0f, scale = 0.4f, durationMs = 160) {
			if (epoch != started) return@tweenTo
			remove()
		}
	}

	/** Takes the bubble off screen right now, animation or not. */
	private fun remove() {
		transition(Bubble.HIDDEN)
		cancelTween(fab)
		// Removing the window (not just the view) is what hands every touch
		// back to the app underneath.
		host.hideChild(fab)
	}

	/** Builds the dismiss target lazily; it exists only during a drag. */
	private fun dismissTargetView(): View {
		dismissTarget?.let { return it }
		val v = TextView(activity).apply {
			text = "✕"
			setTextColor(Color.WHITE)
			textSize = 22f
			gravity = Gravity.CENTER
			background = GradientDrawable().apply {
				shape = GradientDrawable.OVAL
				setColor(Color.parseColor("#CC2A2140"))
			}
			elevation = dpf(4f)
			outlineProvider = ViewOutlineProvider.BACKGROUND
		}
		dismissTarget = v
		return v
	}

	private fun dismissTargetPosition(): Pair<Int, Int> {
		val (w, h) = screenSize()
		return Pair(
			(w - dismissSize) / 2,
			h - dismissSize - safeBottom() - dp(28),
		)
	}

	private fun showDismissTarget() {
		val v = dismissTargetView()
		val (x, y) = dismissTargetPosition()
		host.showChild(v, x, y, dismissSize, dismissSize)
		v.alpha = 0f
		v.scaleX = 1f; v.scaleY = 1f
		tweenTo(v, alpha = 1f, scale = 1f, durationMs = 120)
	}

	private fun hideDismissTarget() {
		val v = dismissTarget ?: return
		host.hideChild(v)
	}

	/** True when the bubble's centre is over the dismiss target. */
	private fun overDismissTarget(): Boolean {
		if (dismissTarget == null) return false
		val (tx, ty) = dismissTargetPosition()
		val cx = fabX + fabSize / 2
		val cy = fabY + fabSize / 2
		val tcx = tx + dismissSize / 2
		val tcy = ty + dismissSize / 2
		val dx = (cx - tcx).toFloat()
		val dy = (cy - tcy).toFloat()
		// A generous radius: dropping "near enough" should count, the way it
		// does in every chat-head implementation.
		return sqrt(dx * dx + dy * dy) < dismissSize
	}

	/** Moves the bubble to a screen position, clamped inside the safe area. */
	private fun moveFab(x: Int, y: Int) {
		val (w, h) = screenSize()
		fabX = x.coerceIn(0, w - fabSize)
		fabY = y.coerceIn(safeTop(), h - fabSize - safeBottom())
		if (host.transient) {
			host.showChild(fab, fabX, fabY, fabSize, fabSize)
		} else {
			val p = fab.layoutParams as FrameLayout.LayoutParams
			p.leftMargin = fabX
			p.topMargin = fabY
			fab.layoutParams = p
		}
	}

	/**
	 * Hot corners: let go of the bubble and it springs to the nearest corner,
	 * the way a chat head does. Animated in screen space so it works whether the
	 * bubble is a window (connector mode) or a view (hosted mode).
	 */
	private fun snapToCorner() {
		val (w, h) = screenSize()
		val margin = dp(16)
		val targetX = if (fabX + fabSize / 2 < w / 2) margin else w - fabSize - margin
		val targetY = if (fabY + fabSize / 2 < h / 2) safeTop() + dp(56)
			else h - fabSize - safeBottom() - dp(24)

		val fromX = fabX
		val fromY = fabY
		snap?.let { ui.removeCallbacks(it) }
		val start = SystemClock.uptimeMillis()
		val step = object : Runnable {
			override fun run() {
				val t = easeOut(((SystemClock.uptimeMillis() - start).toFloat() / 220)
					.coerceIn(0f, 1f))
				moveFab(lerp(fromX.toFloat(), targetX.toFloat(), t).toInt(),
					lerp(fromY.toFloat(), targetY.toFloat(), t).toInt())
				if (t < 1f) ui.postDelayed(this, FRAME_MS) else snap = null
			}
		}
		snap = step
		step.run()
	}

	/** The in-flight corner snap, so a new grab can stop it. */
	private var snap: Runnable? = null

	// ---- shake ------------------------------------------------------------

	override fun onSensorChanged(e: SensorEvent) {
		if (!shake.onSample(e.timestamp, e.values[0], e.values[1], e.values[2])) return
		Log.i(TAG, "shake")
		reveal()
	}

	override fun onAccuracyChanged(s: Sensor?, a: Int) {}

	// ---- dev menu ---------------------------------------------------------

	private fun toggleMenu() {
		if (menu != null) { closeMenu(); return }

		// Full-screen scrim that closes on tap-outside.
		val scrim = FrameLayout(activity).apply {
			setBackgroundColor(Color.parseColor("#99000000"))
			setOnClickListener { closeMenu() }
			alpha = 0f
		}
		tweenTo(scrim, alpha = 1f, scale = 1f, durationMs = 150)

		val sheet = LinearLayout(activity).apply {
			orientation = LinearLayout.VERTICAL
			background = rounded(surface, dpf(22f))
			elevation = dpf(16f)
			setPadding(dp(22), dp(22), dp(22), dp(20))
			clipToOutline = true
			outlineProvider = ViewOutlineProvider.BACKGROUND
			// Swallow taps so they don't fall through to the scrim.
			setOnClickListener { }
		}

		// Swipe down to dismiss. The sheet already draws a grabber, so the
		// gesture is the one people will try first; without it the handle is
		// decoration that lies about what the sheet does.
		attachSwipeToDismiss(sheet)

		// Grabber
		sheet.addView(View(activity).apply {
			background = rounded(surfaceHi, dpf(2f))
		}, LinearLayout.LayoutParams(dp(36), dp(4)).apply {
			gravity = Gravity.CENTER_HORIZONTAL
			bottomMargin = dp(16)
		})

		// Title row: "rhr" chip + "dev menu"
		val titleRow = LinearLayout(activity).apply {
			orientation = LinearLayout.HORIZONTAL
			gravity = Gravity.CENTER_VERTICAL
		}
		titleRow.addView(TextView(activity).apply {
			text = "rhr"
			setTextColor(Color.WHITE)
			textSize = 12f
			typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
			background = rounded(violet, dpf(8f))
			setPadding(dp(10), dp(4), dp(10), dp(4))
		})
		titleRow.addView(TextView(activity).apply {
			text = "  dev menu"
			setTextColor(ink)
			textSize = 16f
			typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
		})
		sheet.addView(titleRow)

		// Status card
		val statusCard = LinearLayout(activity).apply {
			orientation = LinearLayout.VERTICAL
			background = rounded(surfaceHi, dpf(14f))
			setPadding(dp(16), dp(14), dp(16), dp(14))
		}
		fun row(k: String, v: String, mono: Boolean = false) {
			val r = LinearLayout(activity).apply {
				orientation = LinearLayout.HORIZONTAL
			}
			r.addView(TextView(activity).apply {
				text = k
				setTextColor(inkDim)
				textSize = 12.5f
			}, LinearLayout.LayoutParams(dp(74), ViewGroup.LayoutParams.WRAP_CONTENT))
			r.addView(TextView(activity).apply {
				text = v
				setTextColor(ink)
				textSize = 12.5f
				if (mono) typeface = Typeface.MONOSPACE
				maxLines = 1
			}, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
			statusCard.addView(r, LinearLayout.LayoutParams(
				ViewGroup.LayoutParams.MATCH_PARENT,
				ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(3); bottomMargin = dp(3) })
		}
		val st = RhrSessionService.status
		val stColor = when (st) {
			"connected" -> Color.parseColor("#4ADE80")
			"rejected" -> Color.parseColor("#F87171")
			"retrying", "closed", "waiting_dev" -> Color.parseColor("#FBBF24")
			else -> inkDim
		}
		// status row with colored dot
		val statusLine = LinearLayout(activity).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
		statusLine.addView(TextView(activity).apply {
			text = "status"; setTextColor(inkDim); textSize = 12.5f
		}, LinearLayout.LayoutParams(dp(74), ViewGroup.LayoutParams.WRAP_CONTENT))
		statusLine.addView(View(activity).apply { background = rounded(stColor, dpf(3f)) },
			LinearLayout.LayoutParams(dp(7), dp(7)).apply { rightMargin = dp(7) })
		statusLine.addView(TextView(activity).apply {
			text = st; setTextColor(ink); textSize = 12.5f
			typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
		})
		statusCard.addView(statusLine, LinearLayout.LayoutParams(
			ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(3); bottomMargin = dp(3) })
		// Status and session only. The VM URI and cache size answer questions a
		// developer has and a tester does not, and this sheet belongs to
		// whoever is holding the phone.
		row("session", RhrSessionService.currentCode.ifEmpty { "—" })
		sheet.addView(statusCard, LinearLayout.LayoutParams(
			ViewGroup.LayoutParams.MATCH_PARENT,
			ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(16) })

		// Actions
		sheet.addView(iconRow("↻", "Reconnect", primary = true) {
			activity.startService(
				Intent(activity, RhrSessionService::class.java).putExtra("cmd", "kick"))
			closeMenu()
		}, LinearLayout.LayoutParams(
			ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(16) })

		// Pause, not Stop: ending a session while the phone stays available just
		// lets the next recovery loop take it again a second later, which reads
		// as the button not working. This is what actually gives the phone back.
		val isPaused = RhrSessionService.status == "paused"
		sheet.addView(
			iconRow(
				if (isPaused) "▶" else "⏸",
				if (isPaused) "Resume — let developers connect" else "Pause — keep this phone to myself",
				primary = false,
			) {
				activity.startService(
					Intent(activity, RhrSessionService::class.java)
						.putExtra("cmd", if (isPaused) "resume" else "pause"))
				closeMenu()
			},
			LinearLayout.LayoutParams(
				ViewGroup.LayoutParams.MATCH_PARENT,
				ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(6) })

		sheet.addView(iconRow("✕", "Disconnect — back to lobby", primary = false) {
			// Stop the tunnel, then restart the process cleanly into the lobby.
			// A guest kernel owns the Dart VM, so only a fresh process re-runs the
			// lobby's main(). The previous approach (killProcess + AlarmManager)
			// read as a crash and could be blocked by background-start limits.
			// Instead: launch a fresh root Activity task, then end THIS process
			// once it's on its way — Android brings up the new task, which cold-
			// starts the engine into the lobby.
			activity.startService(
				Intent(activity, RhrSessionService::class.java).putExtra("cmd", "stop"))
			// This action bypasses the lobby's Dart-side _disconnect(), so clear
			// the shared_preferences key here as well. Use commit(), not apply():
			// this process exits below and an asynchronous write can be lost.
			activity.getSharedPreferences("FlutterSharedPreferences", Activity.MODE_PRIVATE)
				.edit()
				.remove("flutter.rhr_session_code")
				.commit()
			closeMenu()
			val launch = activity.packageManager
				.getLaunchIntentForPackage(activity.packageName)!!
			// makeRestartActivityTask clears the task and starts fresh — the
			// canonical "restart my app" intent.
			val restart = Intent.makeRestartActivityTask(launch.component)
			restart.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK)
			activity.startActivity(restart)
			// Let the new task come up, then quietly end this process so the
			// stale guest engine is gone (no visible crash — the app is already
			// foregrounding the fresh lobby task).
			// Only meaningful when we are an Activity; the process exit below
			// is what actually clears the stale guest engine either way.
			(activity as? Activity)?.finishAffinity()
			Runtime.getRuntime().exit(0)
		}, LinearLayout.LayoutParams(
			ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(10) })

		sheet.addView(TextView(activity).apply {
			text = "Close"
			setTextColor(inkDim)
			textSize = 13f
			gravity = Gravity.CENTER
			setPadding(0, dp(14), 0, dp(4))
			setOnClickListener { closeMenu() }
		}, LinearLayout.LayoutParams(
			ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

		// Bottom-anchored sheet
		val sheetLp = FrameLayout.LayoutParams(
			ViewGroup.LayoutParams.MATCH_PARENT,
			ViewGroup.LayoutParams.WRAP_CONTENT,
			Gravity.BOTTOM)
		sheetLp.leftMargin = dp(12); sheetLp.rightMargin = dp(12)
		sheetLp.bottomMargin = safeBottom() + dp(12)
		scrim.addView(sheet, sheetLp)
		// The panel is SUPPOSED to capture touches — it has a scrim, and tapping
		// outside the sheet closes it. So a full-screen window is right here,
		// and it exists only while the panel is open.
		if (host.transient) {
			host.showModal(scrim)
		} else {
			root.addView(scrim, FrameLayout.LayoutParams(
				ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
		}
		sheet.post { springIn(sheet, sheet.height.toFloat().coerceAtLeast(dpf(200f))) }
		menu = scrim
	}

	private fun iconRow(
		glyph: String, label: String, primary: Boolean, onTap: () -> Unit
	): LinearLayout = LinearLayout(activity).apply {
		orientation = LinearLayout.HORIZONTAL
		gravity = Gravity.CENTER_VERTICAL
		background = if (primary) rounded(violet, dpf(14f))
			else GradientDrawable().apply {
				setColor(Color.TRANSPARENT); cornerRadius = dpf(14f)
				setStroke(dp(1), surfaceHi)
			}
		setPadding(dp(16), dp(14), dp(16), dp(14))
		isClickable = true
		val fg = if (primary) Color.WHITE else ink
		addView(icon(glyph).apply { setTextColor(fg) },
			LinearLayout.LayoutParams(dp(24), ViewGroup.LayoutParams.WRAP_CONTENT).apply {
				rightMargin = dp(12) })
		addView(TextView(activity).apply {
			text = label; setTextColor(fg); textSize = 15f
			typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
		}, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
		setOnClickListener {
			haptic(it, strong = true)
			it.scaleX = 0.97f; it.scaleY = 0.97f
			scaleTo(it, 1f)
			onTap()
		}
	}

	/**
	 * Drag the panel down to dismiss it, the way any bottom sheet behaves.
	 *
	 * Past roughly a third of its height (or on a fast flick) it closes;
	 * anything less springs back, so a mis-swipe never loses the panel. The
	 * sheet is dragged with a plain translation rather than a layout change —
	 * cheaper per frame, and it cannot disturb the window geometry that keeps
	 * touches passing through to the app underneath.
	 */
	private fun attachSwipeToDismiss(sheet: View) {
		var downY = 0f
		var startTranslation = 0f
		var dragging = false
		var lastY = 0f
		var lastT = 0L
		var velocity = 0f

		sheet.setOnTouchListener { v, e ->
			when (e.action) {
				MotionEvent.ACTION_DOWN -> {
					downY = e.rawY
					startTranslation = v.translationY
					lastY = e.rawY
					lastT = System.currentTimeMillis()
					velocity = 0f
					dragging = false
					// Don't claim the gesture yet: a tap on a button inside the
					// sheet must still reach it.
					false
				}
				MotionEvent.ACTION_MOVE -> {
					val dy = e.rawY - downY
					if (!dragging && dy > dp(8)) dragging = true
					if (dragging) {
						// Downward only; dragging up should not lift the sheet
						// off the bottom of the screen.
						v.translationY = (startTranslation + dy).coerceAtLeast(0f)
						val now = System.currentTimeMillis()
						val dt = (now - lastT).coerceAtLeast(1L)
						velocity = (e.rawY - lastY) / dt * 1000f
						lastY = e.rawY
						lastT = now
					}
					dragging
				}
				MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
					if (!dragging) return@setOnTouchListener false
					val far = v.translationY > v.height / 3f
					val flung = velocity > dpf(900f)
					val from = v.translationY
					if (far || flung) {
						tween(v, 160, onEnd = { closeMenu() }) { t ->
							v.translationY = lerp(from, v.height.toFloat(), t)
						}
					} else {
						tween(v, 200) { t -> v.translationY = lerp(from, 0f, t) }
					}
					true
				}
				else -> false
			}
		}
	}

	private fun closeMenu() {
		menu?.let { m ->
			tweenTo(m, alpha = 0f, scale = 1f, durationMs = 140) {
				if (host.transient) host.hideModal(m) else root.removeView(m)
			}
		}
		menu = null
		// Panel closed: the bubble may idle away again, a little sooner than
		// after a shake since the tester has just been looking at it.
		armIdleHide(IDLE_AFTER_PANEL_MS)
	}

	// ---- render -----------------------------------------------------------

	private fun render() {
		val phase = RhrSessionService.progressPhase
		val done = RhrSessionService.progressDone
		val total = RhrSessionService.progressTotal
		when (phase) {
			"assets" -> {
				showCard()
				bar.isIndeterminate = false
				val pct = if (total > 0) (done * 1000 / total) else 0
				bar.progress = pct
				cardLabel.text = "Syncing assets"
				cardPct.text = "${pct / 10}%"
				cardPct.visibility = View.VISIBLE
			}
			"updating" -> {
				showCard()
				bar.isIndeterminate = false
				// done/total are APK byte counts — multiply as Long or an
				// ~80 MB transfer overflows Int.
				val pct = if (total > 0) (done.toLong() * 1000 / total).toInt() else 0
				bar.progress = pct
				cardLabel.text = "Updating player"
				cardPct.text = "${pct / 10}%"
				cardPct.visibility = View.VISIBLE
			}
			"syncing" -> {
				showCard()
				bar.isIndeterminate = true
				cardLabel.text = "Syncing your app…"
				cardPct.visibility = View.GONE
			}
			"awaiting_restart" -> {
				showCard()
				bar.isIndeterminate = false
				bar.progress = bar.max
				cardLabel.text = if (RhrSessionService.phaseStalled)
					"App synced — awaiting Hot Restart (taking a while — check the developer's terminal)"
				else
					"App synced — awaiting Hot Restart"
				cardPct.visibility = View.GONE
			}
			"restarting" -> {
				showCard()
				bar.isIndeterminate = true
				cardLabel.text = if (RhrSessionService.phaseStalled)
					"Restart is taking a while — check the developer's terminal"
				else
					"Restarting your app…"
				cardPct.visibility = View.GONE
			}
			"reloading" -> {
				showCard()
				bar.isIndeterminate = true
				cardLabel.text = if (RhrSessionService.phaseStalled)
					"Reload is taking a while — check the developer's terminal"
				else
					"Reloading…"
				cardPct.visibility = View.GONE
			}
			else -> {
				val st = RhrSessionService.status
				when (st) {
					// Waiting for a developer is the RESTING state, not an
					// event: a phone sits in it for hours between sessions. A
					// card here covered the tester's own app the whole time,
					// which is the opposite of what an overlay is for. The
					// bubble still carries the status for anyone who wants it.
					"connected", "idle", "waiting_dev" -> hideCard()
					"rejected" -> {
						showCard()
						bar.isIndeterminate = true
						cardLabel.text = "Session not found — check the code, retrying…"
						cardPct.visibility = View.GONE
					}
					"retrying", "closed" -> {
						showCard()
						bar.isIndeterminate = true
						cardLabel.text = "Can't reach relay — retrying…"
						cardPct.visibility = View.GONE
					}
					else -> {
						showCard()
						bar.isIndeterminate = true
						cardLabel.text = "Connection: $st…"
						cardPct.visibility = View.GONE
					}
				}
			}
		}
	}

	// The card only ever shows in hosted mode, with the player's Activity in
	// front, so plain Animators are safe here (see the animation note above).
	private fun showCard() {
		// Over the tester's OWN app, nothing may appear uninvited — the whole
		// contract is "you see nothing until you shake". In the player's own
		// Activity the status card is welcome chrome; floating above someone
		// else's UI it is an intrusion, so connector mode suppresses it and
		// surfaces the same state inside the shake-summoned panel instead.
		if (host.transient) return
		if (card.visibility != View.VISIBLE) {
			card.visibility = View.VISIBLE
			card.alpha = 0f
			card.translationY = -dpf(12f)
			card.animate().alpha(1f).translationY(0f).setDuration(180).start()
		}
	}

	private fun hideCard() {
		if (card.visibility == View.VISIBLE) {
			card.animate().alpha(0f).translationY(-dpf(12f)).setDuration(160)
				.withEndAction { card.visibility = View.GONE }.start()
		}
	}

	private companion object {
		const val TAG = "rhr_overlay"
		/** Tween step; ~60 Hz is plenty for chrome this small. */
		const val FRAME_MS = 16L

		fun easeOut(t: Float): Float = 1 - (1 - t) * (1 - t)

		/** Overshoots a little past 1 and settles, the chat-head pop. */
		fun easeOutBack(t: Float): Float {
			val c = 1.70158f
			val u = t - 1
			return 1 + (c + 1) * u * u * u + c * u * u
		}
		/** How long the bubble lingers over the tester's app after a shake. */
		const val IDLE_MS = 5_000L
		/** Shorter linger after the panel closes: the tester just used it. */
		const val IDLE_AFTER_PANEL_MS = 3_000L
	}
}
