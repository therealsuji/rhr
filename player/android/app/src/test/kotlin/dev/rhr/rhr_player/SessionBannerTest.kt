package dev.rhr.rhr_player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Replays the phase sequences the CLI actually sends and asserts what the
 * tester reads.
 *
 * Each sequence below is taken from a real path through `rhr attach`, cited
 * by file and function, not invented. The bugs these cover were all seen on
 * a phone first: a progress bar that stopped at 54% and stayed there through
 * the install and into the next screen, a lobby that said "Connecting…" after
 * a session had been deliberately stopped, and a transfer that called itself
 * an install for the whole minute it was streaming.
 */
class SessionBannerTest {

	/**
	 * One control message, as the service applies it: phase plus the byte
	 * counters that ride along with it.
	 */
	private data class Progress(
		val phase: String,
		val done: Long = 0,
		val total: Long = 0,
		val message: String = "",
	)

	/** The phone's view after applying [messages] in order. */
	private fun replay(
		messages: List<Progress>,
		status: String = "connected",
		foreignApp: Boolean = false,
		stalled: Boolean = false,
	): SessionBanner {
		val last = messages.lastOrNull() ?: Progress("")
		return SessionBanner.of(
			phase = last.phase,
			status = status,
			done = last.done,
			total = last.total,
			message = last.message,
			stalled = stalled,
			foreignApp = foreignApp,
		)
	}

	// ---- the transfer itself ----------------------------------------------

	/**
	 * The bug that started this. `PlayerUpdateSender.send` counts gzipped
	 * wire bytes into `sent` but reports the UNCOMPRESSED apk length as the
	 * total, so an APK that compresses to ~55% reports 55% when the last
	 * byte lands. The bar then sits there, because nothing else ever moves
	 * it.
	 *
	 * The contract this pins: whatever the two numbers are, they are the
	 * same currency, and a finished transfer reads 100%.
	 */
	@Test
	fun `a finished transfer reads one hundred percent`() {
		val apkBytes = 101_216_775L
		val wireBytes = 55_669_226L // what gzip actually put on the wire

		// What the CLI used to send: wire bytes against apk total.
		val mixedCurrency = SessionBanner.of(
			phase = "updating", status = "connected",
			done = wireBytes, total = apkBytes)
		assertNotEquals(
			"a completed transfer that reports 55% is the stuck-bar bug",
			1000, mixedCurrency.progress)

		// What it must send: both counts in the same currency.
		val honest = SessionBanner.of(
			phase = "updating", status = "connected",
			done = wireBytes, total = wireBytes)
		assertEquals(1000, honest.progress)
	}

	/** An ~80 MB transfer times 1000 overflows Int. It must not. */
	@Test
	fun `large transfers do not overflow`() {
		val half = SessionBanner.of(
			phase = "updating", status = "connected",
			done = 48_000_000L, total = 96_000_000L)
		assertEquals(500, half.progress)
	}

	@Test
	fun `progress is clamped to the bar`() {
		// A gzip stream that compressed WORSE than the source still must not
		// paint past the end of the bar.
		val over = SessionBanner.of(
			phase = "updating", status = "connected",
			done = 120L, total = 100L)
		assertEquals(1000, over.progress)
	}

	/**
	 * Streaming is not installing. The tester watched "Installing your app"
	 * for the whole ~60 s of transfer, which is both wrong and unhelpful —
	 * it hides the step that may actually need their tap.
	 */
	@Test
	fun `transfer and install are different states`() {
		val sending = SessionBanner.of(
			phase = "updating", status = "connected",
			done = 1, total = 2, foreignApp = true)
		val installing = SessionBanner.of(
			phase = "installing", status = "connected", foreignApp = true)

		assertFalse(
			"a transfer must not claim to be an install",
			sending.label.contains("Installing"))
		assertTrue(installing.label.contains("Installing"))
		assertNotEquals(sending.label, installing.label)
	}

	/** Both payload kinds name what is actually moving. */
	@Test
	fun `the label names the payload`() {
		val app = SessionBanner.of(
			phase = "updating", status = "connected", done = 1, total = 2,
			foreignApp = true)
		val player = SessionBanner.of(
			phase = "updating", status = "connected", done = 1, total = 2,
			foreignApp = false)
		assertTrue(app.label.contains("your app"))
		assertTrue(player.label.contains("player"))
	}

	// ---- whole sequences, as the CLI sends them ---------------------------

	/**
	 * The app-payload path: a project with native code gets its own APK.
	 * `_updatePlayerOverTheWire` sends "building", then "updating" per 256 KB,
	 * and the device adds the install states it alone can see.
	 *
	 * Every one of these must be visible — this is minutes of a tester's life
	 * and the whole point is that the phone explains itself.
	 */
	@Test
	fun `the app update sequence is legible at every step`() {
		val wire = 55_669_226L
		val sequence = listOf(
			Progress("outdated"),
			Progress("building"),
			Progress("updating", done = 0, total = wire),
			Progress("updating", done = wire / 2, total = wire),
			Progress("updating", done = wire, total = wire),
			Progress("installing"),
			Progress("installed"),
		)

		for (i in sequence.indices) {
			val banner = replay(sequence.take(i + 1), foreignApp = true)
			assertTrue(
				"step ${i + 1} (${sequence[i].phase}) told the tester nothing",
				banner.isVisible && banner.label.isNotBlank())
		}

		// And it ends finished, not stuck part-way.
		val end = replay(sequence, foreignApp = true)
		assertEquals(1000, end.progress)
	}

	/**
	 * The player-payload path (version skew, no native code). Same shape,
	 * different words, and it ends the same way: finished.
	 */
	@Test
	fun `the player update sequence ends finished`() {
		val wire = 40_000_000L
		val end = replay(
			listOf(
				Progress("outdated"),
				Progress("building"),
				Progress("updating", done = wire, total = wire),
				Progress("installing"),
				Progress("installed"),
			),
		)
		assertEquals(1000, end.progress)
		assertTrue(end.label.contains("Update installed"))
	}

	// ---- every phase has an end -------------------------------------------

	/**
	 * The rule the tester's patience depends on: a bar that went up must come
	 * down. Each terminal message below is one the CLI or the service really
	 * sends, and each must leave the phone somewhere final — not frozen on
	 * the last percentage it happened to see.
	 */
	@Test
	fun `every terminal message ends the transfer`() {
		val wire = 55_669_226L
		val midTransfer = listOf(
			Progress("building"),
			Progress("updating", done = wire / 3, total = wire),
		)

		// _clearUpdatePhase(transport) — declined, or no terminal to ask on.
		val cleared = replay(midTransfer + Progress(""), status = "connected")
		assertFalse("a cleared phase must leave no card", cleared.isVisible)

		// _clearUpdatePhase(transport, failure: …) — the build or install died.
		val failed = replay(
			midTransfer + Progress("update_failed", message = "Gradle: no space left"))
		assertEquals(SessionBanner.Style.FAILED, failed.style)
		assertTrue(failed.label.contains("no space left"))

		// The device's own terminal states.
		val installed = replay(midTransfer + Progress("installed"), foreignApp = true)
		assertEquals(1000, installed.progress)
		assertNotEquals(SessionBanner.Style.FAILED, installed.style)

		// dev_gone / socket death: the service calls setProgress("", 0, 0).
		val devGone = replay(midTransfer + Progress(""), status = "waiting_dev")
		assertFalse(devGone.isVisible)

		// Disconnect: the phase clears and the session goes idle.
		val disconnected = replay(midTransfer + Progress(""), status = "idle")
		assertFalse(disconnected.isVisible)
	}

	/** A failure with no reason still has to say something actionable. */
	@Test
	fun `a failure without a message still points somewhere`() {
		val silent = SessionBanner.of(
			phase = "update_failed", status = "connected")
		assertEquals(SessionBanner.Style.FAILED, silent.style)
		assertTrue(silent.label.contains("developer's terminal"))
	}

	// ---- the connection underneath ----------------------------------------

	/**
	 * "Connecting…" forever, after "Stop and pick another app". The session
	 * was deliberately stopped and nothing was dialing, but both surfaces
	 * mapped every unrecognised status to a default arm that claimed a
	 * connection was in progress.
	 *
	 * Nothing may claim to be connecting unless something is.
	 */
	@Test
	fun `a stopped session does not claim to be connecting`() {
		for (status in listOf("idle", "stopped", "paused")) {
			val banner = SessionBanner.of(phase = "", status = status)
			assertFalse(
				"status '$status' still says: ${banner.label}",
				banner.label.contains("Connecting"))
		}
	}

	/** The states that genuinely are retrying may say so. */
	@Test
	fun `retrying states say they are retrying`() {
		for (status in listOf("retrying", "closed")) {
			val banner = SessionBanner.of(phase = "", status = status)
			assertTrue(banner.label.contains("retrying"))
		}
	}

	/**
	 * Resting is not an event. A phone waiting for a developer sits here for
	 * hours and must not be wearing a card while it does.
	 */
	@Test
	fun `resting states show no card`() {
		for (status in listOf("connected", "waiting_dev", "idle", "")) {
			assertFalse(
				"status '$status' put a card over the tester's app",
				SessionBanner.of(phase = "", status = status).isVisible)
		}
	}

	/**
	 * A phase outranks the status under it: an APK streaming over a socket
	 * says so, rather than reporting that the socket is fine.
	 */
	@Test
	fun `a live phase outranks the connection status`() {
		val banner = SessionBanner.of(
			phase = "building", status = "connected")
		assertTrue(banner.label.contains("building"))
	}

	// ---- stalls ------------------------------------------------------------

	/** A build that outran its budget says so instead of looking hung. */
	@Test
	fun `a stalled build points at the terminal`() {
		val moving = SessionBanner.of(
			phase = "building", status = "connected", stalled = false)
		val stuck = SessionBanner.of(
			phase = "building", status = "connected", stalled = true)
		assertNotEquals(moving.label, stuck.label)
		assertTrue(stuck.label.contains("developer's terminal"))
	}
}
