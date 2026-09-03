package dev.rhr.rhr_connector

import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView

/**
 * A floating input overlay that appears ON TOP of the Wireless Debugging
 * settings screen. The user reads the 6-digit code from the system's
 * pairing dialog (visible behind this overlay) and types it here —
 * no app switching required.
 */
object PairingOverlay {
	private var overlayView: LinearLayout? = null
	private var windowManager: WindowManager? = null
	private var isShowing = false

	fun show(
		ctx: Context,
		onPair: (host: String, port: Int, code: String) -> Unit,
	) {
		if (isShowing) return
		isShowing = true
		windowManager = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager

		val layout = LinearLayout(ctx)
		layout.orientation = LinearLayout.VERTICAL
		layout.setPadding(48, 40, 48, 40)
		layout.background = GradientDrawable().apply {
			setColor(Color.argb(240, 20, 20, 35))
			cornerRadius = 40f
			setStroke(2, Color.argb(255, 100, 100, 200))
		}

		val title = TextView(ctx)
		title.text = "rhr — enter pairing code"
		title.setTextColor(Color.WHITE)
		title.textSize = 16f
		layout.addView(title)

		val hint = TextView(ctx)
		hint.text = "The 6-digit code is shown in the pairing dialog below"
		hint.setTextColor(Color.argb(255, 160, 160, 180))
		hint.textSize = 12f
		hint.setPadding(0, 8, 0, 12)
		layout.addView(hint)

		val codeInput = EditText(ctx)
		codeInput.hint = "6-digit code"
		codeInput.inputType = android.text.InputType.TYPE_CLASS_NUMBER
		codeInput.textSize = 20f
		codeInput.setTextColor(Color.WHITE)
		codeInput.background = GradientDrawable().apply {
			setColor(Color.argb(60, 255, 255, 255))
			cornerRadius = 16f
		}
		codeInput.setPadding(24, 16, 24, 16)
		layout.addView(codeInput)

		val portHint = TextView(ctx)
		portHint.text = "Pairing port (auto-detected or type it)"
		portHint.setTextColor(Color.argb(255, 160, 160, 180))
		portHint.textSize = 12f
		portHint.setPadding(0, 12, 0, 4)
		layout.addView(portHint)

		val portInput = EditText(ctx)
		portInput.hint = "port"
		portInput.inputType = android.text.InputType.TYPE_CLASS_NUMBER
		portInput.textSize = 14f
		portInput.setTextColor(Color.WHITE)
		portInput.background = GradientDrawable().apply {
			setColor(Color.argb(60, 255, 255, 255))
			cornerRadius = 16f
		}
		portInput.setPadding(24, 12, 24, 12)
		layout.addView(portInput)

		val pairBtn = Button(ctx)
		pairBtn.text = "Pair"
		pairBtn.setOnClickListener {
			val code = codeInput.text.toString().trim()
			val portText = portInput.text.toString().trim()
			if (code.length >= 6 && portText.isNotEmpty()) {
				hide()
				try {
					onPair("192.168.1.11", portText.toInt(), code)
				} catch (_: Exception) {}
			}
		}
		layout.addView(pairBtn)

		val cancelBtn = Button(ctx)
		cancelBtn.text = "Cancel"
		cancelBtn.setOnClickListener { hide() }
		layout.addView(cancelBtn)

		val params = WindowManager.LayoutParams(
			WindowManager.LayoutParams.MATCH_PARENT,
			WindowManager.LayoutParams.WRAP_CONTENT,
			WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
			WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
			PixelFormat.TRANSLUCENT,
		)
		params.gravity = Gravity.CENTER

		windowManager?.addView(layout, params)
		overlayView = layout
	}

	fun hide() {
		if (!isShowing) return
		overlayView?.let { view ->
			windowManager?.removeView(view)
			overlayView = null
		}
		isShowing = false
	}
}
