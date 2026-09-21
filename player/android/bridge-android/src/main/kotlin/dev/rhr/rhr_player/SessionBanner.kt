package dev.rhr.rhr_player

/**
 * What the tester should be told, right now, in one place.
 *
 * The phone has two surfaces that answer the same question — the native
 * overlay card and the Flutter lobby — and they used to answer it with two
 * hand-written `when` blocks over the same inputs. They disagreed: the lobby
 * had no idea phases existed, so a build that takes minutes left it on
 * "Connecting…", and both mapped some real statuses to a default arm that
 * claimed a connection was being made when nothing was running at all.
 *
 * So the decision lives here instead, as a pure function of the state the
 * session already publishes. It has no Android types in it, which is the
 * point: the orders the CLI really sends can be replayed against it in a
 * plain JUnit test, and a banner that lies is a failing assertion rather
 * than something you have to catch on a phone.
 */
data class SessionBanner(
	/** The line the tester reads. */
	val label: String,
	/** Per-mille (0..1000) when the work has a known size, else null. */
	val progress: Int?,
	/** How the bar should behave, and whether there should be one. */
	val style: Style,
	/** Why it ended badly, when it did. Already folded into [label]. */
	val failure: String = "",
) {
	enum class Style {
		/** Nothing to say: the resting state. No card. */
		HIDDEN,

		/** Work of unknown length is in flight. */
		BUSY,

		/** Work with a known size; [progress] is set. */
		DETERMINATE,

		/** Waiting on a person, not on work. */
		WAITING,

		/** It failed, and [failure] says why. */
		FAILED,
	}

	val isVisible: Boolean get() = style != Style.HIDDEN

	companion object {
		/**
		 * Decide from the phase the developer reports and the connection
		 * status underneath it.
		 *
		 * A phase always wins over a status: the socket being merely
		 * "connected" says nothing useful while an APK is streaming over it.
		 * An empty phase falls through to the connection itself.
		 *
		 * [done] and [total] are wire bytes and must be the SAME currency —
		 * see the note in the "updating" arm, which is where they were not.
		 */
		fun of(
			phase: String,
			status: String,
			done: Long = 0,
			total: Long = 0,
			message: String = "",
			stalled: Boolean = false,
			foreignApp: Boolean = false,
		): SessionBanner = when (phase) {
			"ready" -> SessionBanner("Your app is running", null, Style.HIDDEN)
			"checking", "launching" -> SessionBanner(message, null, Style.BUSY)
			"setup", "approval" -> SessionBanner(message, null, Style.WAITING)
			"preparation_failed" -> SessionBanner(message, null, Style.FAILED, failure = message)

			"assets" -> SessionBanner(
				"Syncing assets", perMille(done, total), Style.DETERMINATE)

			// Bytes are moving. This is NOT the install — saying "Installing"
			// here left the tester reading "Installing your app 54%" for the
			// whole minute of transfer, and then reading it still, unchanged,
			// long after the install had actually finished.
			"updating" -> SessionBanner(
				if (foreignApp) "Sending your app" else "Sending player update",
				perMille(done, total),
				Style.DETERMINATE)

			// The bytes landed and the system installer has them. Short, but
			// it is the step the tester may have to tap through, so it gets
			// its own state instead of hiding inside the transfer's.
			"installing" -> SessionBanner(
				if (foreignApp) "Installing your app" else "Installing the update",
				null,
				Style.BUSY)

			// Waiting on a tap on Android's install sheet.
			"install_confirm" -> SessionBanner(
				"Confirm the install on this phone", null, Style.WAITING)

			"installed" -> SessionBanner(
				if (foreignApp) "Your app is installed" else "Update installed",
				1000,
				Style.DETERMINATE)

			"outdated" -> SessionBanner(
				"Out of date — waiting for the developer", null, Style.WAITING)

			"building" -> SessionBanner(
				if (stalled) "Still building — check the developer's terminal"
				else message.ifEmpty { "Developer is building an update…" },
				null,
				Style.BUSY)

			"update_failed" -> SessionBanner(
				if (message.isEmpty()) "Update failed — check the developer's terminal"
				else "Update failed: $message",
				0,
				Style.FAILED,
				failure = message)

			"syncing" -> SessionBanner("Syncing your app…", null, Style.BUSY)

			"awaiting_restart" -> SessionBanner(
				if (stalled)
					"App synced — awaiting Hot Restart (taking a while — " +
						"check the developer's terminal)"
				else "App synced — awaiting Hot Restart",
				1000,
				Style.DETERMINATE)

			"restarting" -> SessionBanner(
				if (stalled) "Restart is taking a while — check the developer's terminal"
				else "Restarting your app…",
				null,
				Style.BUSY)

			"reloading" -> SessionBanner(
				if (stalled) "Reload is taking a while — check the developer's terminal"
				else "Reloading…",
				null,
				Style.BUSY)

			else -> ofStatus(status)
		}

		/**
		 * No phase in flight: describe the connection.
		 *
		 * Every status the service can publish is named here. The old
		 * default arm said "Connecting…" for all of them, which meant a
		 * session that had been deliberately stopped — nothing dialing,
		 * nothing queued — still told the tester it was connecting, forever.
		 */
		private fun ofStatus(status: String): SessionBanner = when (status) {
			// The resting state. A phone sits here for hours between
			// sessions and must not be covered by a card to do it.
			"connected", "waiting_dev", "idle", "" -> SessionBanner(
				restingLabel(status), null, Style.HIDDEN)

			"rejected" -> SessionBanner(
				"Session not found — check the code, retrying…", null, Style.WAITING)

			"retrying", "closed" -> SessionBanner(
				"Can't reach relay — retrying…", null, Style.BUSY)

			"paused" -> SessionBanner(
				"Paused — this phone is not accepting developers", null, Style.WAITING)

			// The loop ended on its own. Nothing is retrying, so do not
			// imply that something is.
			"stopped" -> SessionBanner(
				"Session ended — reconnect to start again", null, Style.WAITING)

			else -> SessionBanner("Connection: $status…", null, Style.BUSY)
		}

		/**
		 * The lobby shows a line even when the overlay shows no card, so the
		 * resting states still need words. [SessionBanner.isVisible] is what
		 * decides whether a card appears; this is only what it would say.
		 */
		private fun restingLabel(status: String): String = when (status) {
			"connected" -> "Phone connected"
			"waiting_dev" -> "Waiting for developer"
			"idle" -> "Not connected"
			else -> "Ready to connect"
		}

		/**
		 * Per-mille, clamped. Long arithmetic throughout: an ~80 MB transfer
		 * times 1000 overflows Int, which is a real bug this code has had.
		 */
		private fun perMille(done: Long, total: Long): Int =
			if (total <= 0) 0
			else ((done * 1000 / total).coerceIn(0, 1000)).toInt()
	}
}
