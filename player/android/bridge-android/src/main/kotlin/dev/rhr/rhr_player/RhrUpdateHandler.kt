package dev.rhr.rhr_player

import org.json.JSONObject

/**
 * Optional over-the-wire APK-update hook, implemented by the HOST app (the
 * player's RhrPlayerUpdater does PackageInstaller self-updates; a wrapped app
 * ships without one by default). The session service creates the handler
 * lazily through [RhrSessionService.updateHandlerFactory] when the dev side
 * starts an update transfer, wiring the live socket's send functions so the
 * handler can answer while the stream is in flight.
 */
interface RhrUpdateHandler {
	fun handleBegin(message: JSONObject)
	fun handleCommit(message: JSONObject)
	fun handleData(frame: ByteArray)
}
