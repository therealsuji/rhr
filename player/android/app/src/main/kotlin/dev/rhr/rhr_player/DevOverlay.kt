package dev.rhr.rhr_player

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import androidx.dynamicanimation.animation.SpringAnimation
import androidx.dynamicanimation.animation.SpringForce
import kotlin.math.sqrt

/**
 * Native dev overlay layered above the Flutter surface, INSIDE the player's own
 * Activity — the guest app runs in this same process via a kernel swap, so this
 * view sits above whatever Flutter renders. No SYSTEM_ALERT_WINDOW needed: it's
 * our own window.
 *
 * Design language: dark translucent surfaces, rounded corners, the rhr violet
 * (#7C4DFF) as the single accent, generous padding. Meant to read as a polished
 * product chrome, not a debug widget.
 */
class DevOverlay(private val activity: Activity) : SensorEventListener {

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
	// bottom). Read from the window; fall back to the status-bar dimen if the
	// insets aren't attached yet.
	private fun safeTop(): Int {
		val insets = root.rootWindowInsets ?: return statusBarHeight()
		return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
			insets.getInsets(android.view.WindowInsets.Type.systemBars()).top
		else @Suppress("DEPRECATION") insets.systemWindowInsetTop
	}
	private fun safeBottom(): Int {
		val insets = root.rootWindowInsets ?: return dp(16)
		return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
			insets.getInsets(android.view.WindowInsets.Type.systemBars()).bottom
		else @Suppress("DEPRECATION") insets.systemWindowInsetBottom
	}

	// ---- interaction polish ----
	private fun haptic(view: View, strong: Boolean = false) {
		val c = if (strong && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
			HapticFeedbackConstants.CONFIRM else HapticFeedbackConstants.KEYBOARD_TAP
		view.performHapticFeedback(c)
	}

	// A View that spring-animates in from translationY + alpha (Expo-style pop).
	private fun springIn(view: View, fromY: Float) {
		view.translationY = fromY
		view.alpha = 0f
		view.animate().alpha(1f).setDuration(120).start()
		SpringAnimation(view, SpringAnimation.TRANSLATION_Y, 0f).apply {
			spring.stiffness = SpringForce.STIFFNESS_LOW
			spring.dampingRatio = SpringForce.DAMPING_RATIO_MEDIUM_BOUNCY
			start()
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
		activity.getSystemService(Activity.SENSOR_SERVICE) as SensorManager?
	private var lastShake = 0L

	fun attach() {
		root = FrameLayout(activity)
		activity.addContentView(
			root,
			FrameLayout.LayoutParams(
				ViewGroup.LayoutParams.MATCH_PARENT,
				ViewGroup.LayoutParams.MATCH_PARENT))

		buildProgressCard()
		buildFab()
		render()

		RhrSessionService.onUpdate = { activity.runOnUiThread { render() } }
		sensors?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)?.let {
			sensors.registerListener(this, it, SensorManager.SENSOR_DELAY_UI)
		}
	}

	fun detach() {
		RhrSessionService.onUpdate = null
		sensors?.unregisterListener(this)
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
		val lp = FrameLayout.LayoutParams(dp(46), dp(46), Gravity.TOP or Gravity.START)
		lp.leftMargin = dp(16)
		lp.topMargin = statusBarHeight() + dp(72)
		fab.visibility = View.GONE   // hidden until a shake reveals it
		root.addView(fab, lp)

		var downX = 0f; var downY = 0f; var startL = 0; var startT = 0
		var moved = false
		fab.setOnTouchListener { v, e ->
			val p = v.layoutParams as FrameLayout.LayoutParams
			when (e.action) {
				MotionEvent.ACTION_DOWN -> {
					downX = e.rawX; downY = e.rawY
					startL = p.leftMargin; startT = p.topMargin; moved = false
					v.animate().scaleX(0.9f).scaleY(0.9f).setDuration(80).start()
					true
				}
				MotionEvent.ACTION_MOVE -> {
					val dx = (e.rawX - downX).toInt(); val dy = (e.rawY - downY).toInt()
					if (kotlin.math.abs(dx) > dp(6) || kotlin.math.abs(dy) > dp(6)) moved = true
					p.leftMargin = (startL + dx)
					p.topMargin = (startT + dy)
						.coerceIn(safeTop(), root.height - v.height - safeBottom())
					v.layoutParams = p
					true
				}
				MotionEvent.ACTION_UP -> {
					v.animate().scaleX(1f).scaleY(1f).setDuration(120).start()
					if (!moved) {
						fab.removeCallbacks(hideFabRunnable)   // keep fab while panel open
						toggleMenu()
					} else {
						snapToCorner()
						fab.postDelayed(hideFabRunnable, 5000) // re-arm idle hide
					}
					true
				}
				else -> false
			}
		}
	}

	private val hideFabRunnable = Runnable { hideFab() }

	// Shake ONLY reveals the fab (never opens the panel). The panel opens solely
	// by tapping the fab. The fab auto-hides after a few idle seconds so it never
	// lingers over the tester's app.
	private fun revealFab() {
		fab.removeCallbacks(hideFabRunnable)
		fab.postDelayed(hideFabRunnable, 5000)
		if (fab.visibility == View.VISIBLE) return   // already shown; just extend
		fab.visibility = View.VISIBLE
		fab.scaleX = 0.4f; fab.scaleY = 0.4f; fab.alpha = 0f
		fab.animate().alpha(1f).setDuration(120).start()
		SpringAnimation(fab, SpringAnimation.SCALE_X, 1f).apply {
			spring.stiffness = SpringForce.STIFFNESS_LOW
			spring.dampingRatio = SpringForce.DAMPING_RATIO_MEDIUM_BOUNCY; start()
		}
		SpringAnimation(fab, SpringAnimation.SCALE_Y, 1f).apply {
			spring.stiffness = SpringForce.STIFFNESS_LOW
			spring.dampingRatio = SpringForce.DAMPING_RATIO_MEDIUM_BOUNCY; start()
		}
	}

	private fun hideFab() {
		if (menu != null) return   // don't hide while the panel is open
		fab.animate().alpha(0f).scaleX(0.4f).scaleY(0.4f).setDuration(160)
			.withEndAction { fab.visibility = View.GONE }.start()
	}

	// Snap the fab to the nearest of the four screen corners (hot corners).
	private fun snapToCorner() {
		val p = fab.layoutParams as FrameLayout.LayoutParams
		val w = root.width; val h = root.height
		if (w == 0 || h == 0) return
		val margin = dp(16)
		val cx = p.leftMargin + fab.width / 2
		val cy = p.topMargin + fab.height / 2
		val targetL = if (cx < w / 2) margin else w - fab.width - margin
		val targetT = if (cy < h / 2) safeTop() + dp(56)
			else h - fab.height - safeBottom() - dp(24)
		SpringAnimation(fab, object : androidx.dynamicanimation.animation.FloatPropertyCompat<View>("l") {
			override fun getValue(v: View) = (v.layoutParams as FrameLayout.LayoutParams).leftMargin.toFloat()
			override fun setValue(v: View, value: Float) {
				val q = v.layoutParams as FrameLayout.LayoutParams
				q.leftMargin = value.toInt(); v.layoutParams = q
			}
		}, targetL.toFloat()).apply {
			spring.stiffness = SpringForce.STIFFNESS_MEDIUM
			spring.dampingRatio = SpringForce.DAMPING_RATIO_LOW_BOUNCY; start()
		}
		SpringAnimation(fab, object : androidx.dynamicanimation.animation.FloatPropertyCompat<View>("t") {
			override fun getValue(v: View) = (v.layoutParams as FrameLayout.LayoutParams).topMargin.toFloat()
			override fun setValue(v: View, value: Float) {
				val q = v.layoutParams as FrameLayout.LayoutParams
				q.topMargin = value.toInt(); v.layoutParams = q
			}
		}, targetT.toFloat()).apply {
			spring.stiffness = SpringForce.STIFFNESS_MEDIUM
			spring.dampingRatio = SpringForce.DAMPING_RATIO_LOW_BOUNCY; start()
		}
	}

	// ---- shake ------------------------------------------------------------

	override fun onSensorChanged(e: SensorEvent) {
		val g = sqrt(
			(e.values[0] * e.values[0] +
				e.values[1] * e.values[1] +
				e.values[2] * e.values[2]).toDouble()) / SensorManager.GRAVITY_EARTH
		if (g > 2.7) {
			val now = System.currentTimeMillis()
			if (now - lastShake > 1200) {
				lastShake = now
				activity.runOnUiThread { haptic(root, strong = true); revealFab() }
			}
		}
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
			animate().alpha(1f).setDuration(150).start()
		}

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
		row("session", RhrSessionService.currentCode.ifEmpty { "—" })
		row("vm", RhrSessionService.currentVm.ifEmpty { "—" }, mono = true)
		val cacheMb = RhrSessionService.assetCacheSizeBytes() / (1024 * 1024)
		row("cache", "$cacheMb MB")
		sheet.addView(statusCard, LinearLayout.LayoutParams(
			ViewGroup.LayoutParams.MATCH_PARENT,
			ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(16) })

		// Recovery: wipe the cached per-project asset stores (next sync cold).
		sheet.addView(iconRow("✕", "Clear cached apps (next sync cold)", primary = false) {
			RhrSessionService.clearAssetCaches()
			closeMenu()
		}, LinearLayout.LayoutParams(
			ViewGroup.LayoutParams.MATCH_PARENT,
			ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(10) })

		// Deliberate fault injection — QA/state-machine testing only.
		sheet.addView(TextView(activity).apply {
			text = "Test faults"
			setTextColor(inkDim)
			textSize = 11f
			letterSpacing = 0.08f
			typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
			setPadding(0, dp(18), 0, dp(6))
		})
		fun faultRow(glyph: String, label: String, fault: String) {
			sheet.addView(iconRow(glyph, label, primary = false) {
				RhrSessionService.debugInjectFault(fault)
				closeMenu()
			}, LinearLayout.LayoutParams(
				ViewGroup.LayoutParams.MATCH_PARENT,
				ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(6) })
		}
		faultRow("↻", "Relay loss (close socket)", "relay-loss")
		faultRow("⚠", "Force retrying", "status-retrying")
		faultRow("✖", "Force rejected", "status-rejected")
		faultRow("◐", "Stall reload phase", "phase-reloading")
		faultRow("✓", "Reset state", "clear")

		// Actions
		sheet.addView(iconRow("↻", "Reconnect", primary = true) {
			activity.startService(
				Intent(activity, RhrSessionService::class.java).putExtra("cmd", "kick"))
			closeMenu()
		}, LinearLayout.LayoutParams(
			ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(16) })

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
			activity.finishAffinity()
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
		root.addView(scrim, FrameLayout.LayoutParams(
			ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
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
			it.animate().scaleX(0.97f).scaleY(0.97f).setDuration(70)
				.withEndAction { it.animate().scaleX(1f).scaleY(1f).setDuration(90).start() }
				.start()
			onTap()
		}
	}

	private fun closeMenu() {
		menu?.let { m ->
			m.animate().alpha(0f).setDuration(140).withEndAction {
				root.removeView(m)
			}.start()
		}
		menu = null
		// Panel closed → let the fab idle-hide again shortly.
		fab.removeCallbacks(hideFabRunnable)
		fab.postDelayed(hideFabRunnable, 3000)
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
					"connected", "idle" -> hideCard()
					"waiting_dev" -> {
						showCard()
						bar.isIndeterminate = true
						cardLabel.text = "Waiting for developer…"
						cardPct.visibility = View.GONE
					}
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

	private fun showCard() {
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
}
