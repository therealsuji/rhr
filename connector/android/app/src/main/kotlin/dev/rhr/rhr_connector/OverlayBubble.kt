package dev.rhr.rhr_connector

import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/**
 * A floating bubble that overlays the target app's UI. Shows the rhr
 * session status and a disconnect button. Toggled by shake. Requires
 * SYSTEM_ALERT_WINDOW ("Display over other apps") — granted once in
 * settings.
 *
 * Uses TYPE_APPLICATION_OVERLAY so it floats above everything, including
 * the target app's bottom sheets and dialogs.
 */
class OverlayBubble(private val context: Context) {
	private var windowManager: WindowManager? = null
	private var overlayView: LinearLayout? = null
	var isShowing = false
		private set

	fun show(sessionCode: String, targetLabel: String, onDisconnect: () -> Unit) {
		if (isShowing) return
		isShowing = true

		windowManager = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager

		val layout = LinearLayout(context).apply {
			orientation = LinearLayout.VERTICAL
			setPadding(32, 24, 32, 24)
			background = GradientDrawable().apply {
				setColor(Color.argb(230, 20, 20, 30))
				cornerRadius = 32f
			}
		}

		val titleView = TextView(context).apply {
			text = "rhr connector"
			setTextColor(Color.argb(255, 140, 140, 255))
			textSize = 12f
		}
		layout.addView(titleView)

		val statusView = TextView(context).apply {
			text = "tunneling $targetLabel"
			setTextColor(Color.WHITE)
			textSize = 14f
			setPadding(0, 8, 0, 0)
		}
		layout.addView(statusView)

		val codeView = TextView(context).apply {
			text = sessionCode
			setTextColor(Color.argb(255, 180, 180, 200))
			textSize = 12f
			setPadding(0, 4, 0, 0)
		}
		layout.addView(codeView)

		val disconnectBtn = Button(context).apply {
			text = "Disconnect"
			textSize = 12f
			setOnClickListener {
				hide()
				onDisconnect()
			}
		}
		layout.addView(disconnectBtn)

		val params = WindowManager.LayoutParams(
			WindowManager.LayoutParams.WRAP_CONTENT,
			WindowManager.LayoutParams.WRAP_CONTENT,
			WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
			WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
			PixelFormat.TRANSLUCENT,
		).apply {
			gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
			x = 0
			y = 200
		}

		windowManager?.addView(layout, params)
		overlayView = layout
	}

	fun hide() {
		if (!isShowing) return
		overlayView?.let {
			windowManager?.removeView(it)
			overlayView = null
		}
		isShowing = false
	}
}
