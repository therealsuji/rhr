package dev.rhr.rhr_player

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.View

/**
 * The "your coding agent is on this phone right now" edge light.
 *
 * Drawn at the display edge and never over the middle: the agent reads the
 * screen through screenshots and the tree, so the glow must not hide a label
 * or move a control.
 *
 * [Edge.ALL] fills a view in the player's own Activity, where the guest app
 * and the player share one window. Connector mode gives each edge its own
 * window (see [RhrSessionService]) because one full-screen window would count
 * as an obscuring overlay for every touch on the display, and an app that
 * filters obscured touches would silently drop the agent's taps.
 */
class AgentGlow(context: Context, private val edge: Edge) : View(context) {

	enum class Edge { ALL, TOP, BOTTOM, LEFT, RIGHT }

	private val density = resources.displayMetrics.density
	private val falloff = FALLOFF_DP * density

	// A bright 1.5 dp lip at the glass, then a short haze. Stops are fractions
	// of [falloff], so the lip stays crisp at any density.
	private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
	private val shaders = HashMap<Edge, Shader>()

	private val ui = Handler(Looper.getMainLooper())
	private var fade: Runnable? = null

	/**
	 * Fades the light in or out. A plain Handler tween, not an Animator: Samsung
	 * drops Choreographer callbacks and Android pauses Animators for background
	 * processes, and the player is in the background for a whole connector
	 * session. There is no continuous pulse for the same reason: a breathing
	 * overlay would keep the display composing for as long as the agent works.
	 */
	fun glow(on: Boolean) {
		val from = alpha
		val to = if (on) 1f else 0f
		if (from == to && fade == null) return
		fade?.let(ui::removeCallbacks)
		val started = SystemClock.uptimeMillis()
		val duration = if (on) FADE_IN_MS else FADE_OUT_MS
		val step = object : Runnable {
			override fun run() {
				val t = ((SystemClock.uptimeMillis() - started).toFloat() / duration)
					.coerceIn(0f, 1f)
				alpha = from + (to - from) * (1 - (1 - t) * (1 - t))
				if (t < 1f) {
					ui.postDelayed(this, FRAME_MS)
				} else {
					fade = null
				}
			}
		}
		fade = step
		step.run()
	}

	override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
		super.onSizeChanged(w, h, oldw, oldh)
		// Gradients are built against the size they were measured for.
		shaders.clear()
	}

	override fun onDetachedFromWindow() {
		fade?.let(ui::removeCallbacks)
		fade = null
		super.onDetachedFromWindow()
	}

	override fun onDraw(canvas: Canvas) {
		val w = width.toFloat()
		val h = height.toFloat()
		if (w <= 0f || h <= 0f) return
		for (e in edges()) {
			paint.shader = shaders.getOrPut(e) { shader(e, w, h) }
			when (e) {
				Edge.TOP -> canvas.drawRect(0f, 0f, w, falloff, paint)
				Edge.BOTTOM -> canvas.drawRect(0f, h - falloff, w, h, paint)
				Edge.LEFT -> canvas.drawRect(0f, 0f, falloff, h, paint)
				Edge.RIGHT -> canvas.drawRect(w - falloff, 0f, w, h, paint)
				Edge.ALL -> {}
			}
		}
	}

	private fun edges(): List<Edge> =
		if (edge == Edge.ALL) listOf(Edge.TOP, Edge.BOTTOM, Edge.LEFT, Edge.RIGHT)
		else listOf(edge)

	private fun shader(e: Edge, w: Float, h: Float): Shader {
		val colors = intArrayOf(LIP, HAZE, Color.TRANSPARENT)
		val stops = floatArrayOf(0f, 0.10f, 1f)
		return when (e) {
			Edge.TOP -> LinearGradient(0f, 0f, 0f, falloff, colors, stops, Shader.TileMode.CLAMP)
			Edge.BOTTOM -> LinearGradient(0f, h, 0f, h - falloff, colors, stops, Shader.TileMode.CLAMP)
			Edge.LEFT -> LinearGradient(0f, 0f, falloff, 0f, colors, stops, Shader.TileMode.CLAMP)
			Edge.RIGHT -> LinearGradient(w, 0f, w - falloff, 0f, colors, stops, Shader.TileMode.CLAMP)
			Edge.ALL -> error("ALL draws through its four edges")
		}
	}

	companion object {
		/** How far the light reaches in from the glass, in dp. */
		const val FALLOFF_DP = 18f

		private const val FADE_IN_MS = 180L

		/** How long the light takes to leave; a host waits this long to remove it. */
		const val FADE_OUT_MS = 320L
		private const val FRAME_MS = 16L

		/** The bright lip at the very edge. */
		private val LIP = Color.parseColor("#E6D2C4FF")

		/** The brand violet, soft enough that text under it stays readable. */
		private val HAZE = Color.parseColor("#8C7C4DFF")
	}
}
