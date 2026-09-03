package dev.rhr.rhr_connector

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager

/**
 * Detects phone shakes via the accelerometer. Fires [onShake] when the
 * device is shaken hard enough (acceleration magnitude exceeds a
 * threshold, with a cooldown between detections).
 *
 * Runs inside the TunnelKeeperService's process — survives guest kernel
 * swaps, backgrounding, and everything else because it's native.
 */
class ShakeDetector(
	private val context: Context,
	private val onShake: () -> Unit,
) {
	private val sensorManager =
		context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
	private var accelX = 0f
	private var accelY = 0f
	private var accelZ = 0f
	private var lastShakeAt = 0L

	companion object {
		// m/s² — gravity is ~9.8, a shake produces 25-40+ on the delta
		private const val SHAKE_THRESHOLD = 18f
		private const val COOLDOWN_MS = 800L
	}

	private val listener = object : SensorEventListener {
		override fun onSensorChanged(event: SensorEvent) {
			val x = event.values[0]
			val y = event.values[1]
			val z = event.values[2]
			val deltaX = x - accelX
			val deltaY = y - accelY
			val deltaZ = z - accelZ
			accelX = x
			accelY = y
			accelZ = z
			val magnitude =
				deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ
			if (magnitude > SHAKE_THRESHOLD * SHAKE_THRESHOLD) {
				val now = System.currentTimeMillis()
				if (now - lastShakeAt > COOLDOWN_MS) {
					lastShakeAt = now
					onShake()
				}
			}
		}

		override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
	}

	fun start() {
		val accel = sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
		if (accel != null) {
			sensorManager.registerListener(
				listener, accel, SensorManager.SENSOR_DELAY_GAME)
		}
	}

	fun stop() {
		sensorManager.unregisterListener(listener)
	}
}
