package dev.rhr.rhr_player

import android.os.Handler
import android.os.Looper

/**
 * The tester's yes or no before a developer's app is installed on this phone.
 *
 * A developer in a session can stream any APK at the player and name any
 * package for it. Android only shows its own install sheet the first time a
 * package arrives from this installer; after that the player is the
 * installer of record and updates go through silently. So the player asks
 * first, every time, naming the package, before it accepts a single byte.
 *
 * One question at a time. The [DevOverlay] paints it on whichever surface is
 * up (the player's Activity, or the system overlay above the tester's app),
 * and the first answer from any of them wins.
 *
 * A yes covers those exact bytes for the rest of the session: when the
 * connection drops mid-transfer, the CLI sends the same APK again, and asking
 * again for something already allowed only trains people to tap through.
 */
object InstallConsent {
	/** How the question ended. */
	enum class Answer { ALLOWED, DECLINED, UNANSWERED }

	/**
	 * How long the question stays up before it is taken down unanswered,
	 * which installs nothing, like a no, but is reported as its own thing:
	 * nobody saw it is not the tester refused. The CLI gives
	 * up on an unanswered transfer sooner than this (see "ready" in
	 * cli/lib/player_update.dart); an answer after that reaches nobody, and
	 * the developer's next run asks again.
	 */
	private const val TIMEOUT_MS = 60_000L

	class Request(
		val packageName: String,
		internal val approval: String,
		internal val onAnswer: (Answer) -> Unit,
	)

	@Volatile var pending: Request? = null
		private set

	/** What the tester allowed: session, package and APK digest. */
	private val allowed = mutableSetOf<String>()

	/** The key a yes is remembered under. */
	fun approval(session: String, packageName: String, sha256: String) =
		"$session|$packageName|$sha256"

	/** Whether the tester already allowed [approval] in this process. */
	fun alreadyAllowed(approval: String): Boolean = synchronized(this) { approval in allowed }

	private val main = Handler(Looper.getMainLooper())

	/** Puts the question up, replacing any earlier one. [onAnswer] runs on the main thread. */
	fun ask(packageName: String, approval: String, onAnswer: (Answer) -> Unit): Request {
		val request = Request(packageName, approval, onAnswer)
		synchronized(this) { pending = request }
		main.postDelayed({ answer(request, Answer.UNANSWERED) }, TIMEOUT_MS)
		redraw()
		return request
	}

	/** The tester's answer, or the timeout's. Only the first one counts. */
	fun answer(request: Request, answer: Answer) {
		synchronized(this) {
			if (pending !== request) return
			pending = null
			if (answer == Answer.ALLOWED) this.allowed += request.approval
		}
		redraw()
		request.onAnswer(answer)
	}

	/** Takes the question down without an answer; the asker already moved on. */
	fun withdraw(request: Request) {
		synchronized(this) {
			if (pending !== request) return
			pending = null
		}
		redraw()
	}

	// The overlays already redraw on every session change; a question is one.
	private fun redraw() = RhrSessionService.updateListeners.forEach { it() }
}
