package dev.rhr.rhr_player

import kotlin.math.PI
import kotlin.math.sin
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Synthetic accelerometer streams at 50 Hz (SENSOR_DELAY_GAME), gravity on z.
 * The numbers model what a phone reports in hand: a shake is a few hundred
 * milliseconds of 4 Hz oscillation along one axis at well over 1g.
 */
class ShakeDetectorTest {
	private val hz = 50
	private val stepNs = 1_000_000_000L / hz

	/** Feeds [seconds] of motion, returning how many shakes were reported. */
	private fun run(
		detector: ShakeDetector,
		seconds: Double,
		startNs: Long = 0L,
		motion: (tSec: Double) -> Float,
	): Int {
		var fired = 0
		val samples = (seconds * hz).toInt()
		for (i in 0 until samples) {
			val t = i.toDouble() / hz
			val ax = motion(t)
			if (detector.onSample(startNs + i * stepNs, ax, 0f, 9.81f)) fired++
		}
		return fired
	}

	private fun shake(amplitude: Float, freq: Double, from: Double, until: Double) =
		{ t: Double ->
			if (t in from..until) (amplitude * sin(2 * PI * freq * (t - from))).toFloat()
			else 0f
		}

	@Test
	fun `still phone never fires`() {
		assertEquals(0, run(ShakeDetector(), 5.0) { 0f })
	}

	@Test
	fun `one shake fires exactly once`() {
		// 1.5 s of vigorous shaking: many samples over threshold, one report.
		val fired = run(ShakeDetector(), 3.0, motion = shake(20f, 4.0, 0.5, 2.0))
		assertEquals(1, fired)
	}

	@Test
	fun `single bump is not a shake`() {
		// One half-cycle spike: hard, but no reversal.
		val fired = run(ShakeDetector(), 2.0, motion = shake(25f, 4.0, 0.5, 0.625))
		assertEquals(0, fired)
	}

	@Test
	fun `two separate shakes fire twice`() {
		val fired = run(ShakeDetector(), 6.0) { t ->
			shake(20f, 4.0, 0.5, 1.5)(t) + shake(20f, 4.0, 4.0, 5.0)(t)
		}
		assertEquals(2, fired)
	}

	@Test
	fun `tilting the phone slowly does not fire`() {
		// Gravity moving from z to x over two seconds: large change, no reversals.
		var fired = 0
		val d = ShakeDetector()
		val samples = 2 * hz
		for (i in 0 until samples) {
			val a = (i.toDouble() / samples) * PI / 2
			if (d.onSample(i * stepNs, (9.81 * sin(a)).toFloat(), 0f, (9.81 * kotlin.math.cos(a)).toFloat())) fired++
		}
		assertEquals(0, fired)
	}
}
