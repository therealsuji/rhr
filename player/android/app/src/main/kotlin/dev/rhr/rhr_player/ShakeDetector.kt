package dev.rhr.rhr_player

import kotlin.math.sqrt

/**
 * Turns raw accelerometer samples into "the tester shook the phone".
 *
 * Pure Kotlin with no Android dependencies, so the gesture can be unit-tested
 * with synthetic samples; a physical device cannot have sensor data injected.
 *
 * A shake is a back-and-forth motion, so the detector looks for direction
 * reversals, not a single hard sample. Setting the phone down, a tap on the
 * case, or a bump in a pocket produce one spike; a shake produces several
 * spikes that alternate in direction within well under a second.
 *
 *  1. Gravity is removed with a low-pass filter (the standard Android recipe),
 *     leaving linear acceleration. Without this a phone held still already
 *     reads 1g and the threshold is meaningless once the phone is tilted.
 *  2. Any sample whose linear acceleration exceeds [threshold] is "strong".
 *     A strong sample pointing roughly opposite to the previous strong sample
 *     (negative dot product) counts as one reversal.
 *  3. [reversalsNeeded] reversals within [windowNs] of the first strong sample
 *     is a shake. The detector then ignores everything for [cooldownNs], so
 *     one physical shake, however vigorous, reports exactly once.
 */
class ShakeDetector(
	/** Linear acceleration, m/s^2, a sample must reach to count. */
	private val threshold: Float = 9f,
	/** Direction reversals that make a shake. 3 is one full back-and-forth-and-back. */
	private val reversalsNeeded: Int = 3,
	/** How long the reversals may take, from the first strong sample. */
	private val windowNs: Long = 700_000_000L,
	/** Silence after a report so one shake never fires twice. */
	private val cooldownNs: Long = 1_000_000_000L,
) {
	private val gravity = FloatArray(3)
	private var hasGravity = false

	// The gesture in progress: direction of the last strong sample, when the
	// first one arrived, and how many reversals since.
	private val lastDir = FloatArray(3)
	private var gestureStartNs = 0L
	private var reversals = 0
	private var inGesture = false

	private var lastFiredNs = Long.MIN_VALUE

	/**
	 * Feed one accelerometer sample (device axes, m/s^2, sensor timestamp in
	 * nanoseconds). Returns true exactly when a shake completes.
	 */
	fun onSample(tNs: Long, x: Float, y: Float, z: Float): Boolean {
		if (!hasGravity) {
			gravity[0] = x; gravity[1] = y; gravity[2] = z
			hasGravity = true
		} else {
			gravity[0] = GRAVITY_ALPHA * gravity[0] + (1 - GRAVITY_ALPHA) * x
			gravity[1] = GRAVITY_ALPHA * gravity[1] + (1 - GRAVITY_ALPHA) * y
			gravity[2] = GRAVITY_ALPHA * gravity[2] + (1 - GRAVITY_ALPHA) * z
		}
		val lx = x - gravity[0]
		val ly = y - gravity[1]
		val lz = z - gravity[2]

		// Written as an addition: with lastFiredNs at Long.MIN_VALUE the
		// subtraction would overflow and read as "still cooling down" forever.
		if (tNs < lastFiredNs + cooldownNs) return false
		if (inGesture && tNs - gestureStartNs > windowNs) inGesture = false

		val magnitude = sqrt(lx * lx + ly * ly + lz * lz)
		if (magnitude < threshold) return false

		if (!inGesture) {
			inGesture = true
			gestureStartNs = tNs
			reversals = 0
		} else if (lx * lastDir[0] + ly * lastDir[1] + lz * lastDir[2] < 0f) {
			reversals++
		}
		lastDir[0] = lx; lastDir[1] = ly; lastDir[2] = lz

		if (reversals < reversalsNeeded) return false
		inGesture = false
		lastFiredNs = tNs
		return true
	}

	private companion object {
		// Weight of the previous gravity estimate. 0.8 is the value Android's
		// own sensor documentation uses for isolating gravity from a raw
		// accelerometer stream.
		const val GRAVITY_ALPHA = 0.8f
	}
}
