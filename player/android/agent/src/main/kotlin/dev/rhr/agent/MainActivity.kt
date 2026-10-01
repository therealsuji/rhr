package dev.rhr.agent

import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.view.Gravity
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Walks the tester to the setting that turns RHR Agent on. Android binds the
 * service of an app only after it has been opened once, so the player sends
 * the tester here right after installing it.
 */
class MainActivity : Activity() {
	private lateinit var status: TextView
	private lateinit var restricted: Button
	private lateinit var enable: Button

	override fun onCreate(savedInstanceState: Bundle?) {
		super.onCreate(savedInstanceState)
		val padding = (24 * resources.displayMetrics.density).toInt()
		status = TextView(this).apply { textSize = 16f }
		// Android 13+ greys out the switch of a sideloaded accessibility app
		// until the tester allows restricted settings in its App info menu.
		restricted = Button(this).apply {
			text = getString(R.string.allow_restricted)
			setOnClickListener {
				startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
			}
		}
		enable = Button(this).apply {
			text = getString(R.string.turn_on)
			setOnClickListener { openServiceSettings() }
		}
		setContentView(LinearLayout(this).apply {
			orientation = LinearLayout.VERTICAL
			gravity = Gravity.CENTER_VERTICAL
			setPadding(padding, padding, padding, padding)
			addView(status)
			addView(restricted)
			addView(enable)
		})
	}

	override fun onResume() {
		super.onResume()
		val on = AgentService.running != null
		status.text = getString(if (on) R.string.status_on else R.string.status_off)
		restricted.visibility = if (on) Button.GONE else Button.VISIBLE
		enable.text = getString(if (on) R.string.turn_off else R.string.turn_on)
	}

	/**
	 * This service's own settings page where Android lets an app open it (the
	 * action is not in the public SDK), else the accessibility list.
	 */
	private fun openServiceSettings() {
		val details = Intent("android.settings.ACCESSIBILITY_DETAILS_SETTINGS")
			.putExtra(Intent.EXTRA_COMPONENT_NAME, ComponentName(this, AgentService::class.java).flattenToString())
		try {
			startActivity(details)
		} catch (_: Exception) {
			startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
		}
	}
}
