package dev.rhr.rhr_player

import android.content.Context
import org.json.JSONException
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/**
 * The phone's side of the account service: reading and redeeming invites.
 *
 * Native rather than Dart because joining sends the installation secret, and
 * the Dart in this process is whatever a developer last hot-restarted into
 * it. The service is the one baked into this build (RhrConfig), never one an
 * invite names: a crafted QR must not be able to collect the secret.
 *
 * Blocking calls; run them off the main thread.
 */
object AccountClient {
	sealed interface Outcome {
		data class Ok(val body: JSONObject) : Outcome
		data class Refused(val reason: String) : Outcome
	}

	/** Whose account [invite] joins, as the service knows it. */
	fun previewInvite(context: Context, invite: String): Outcome =
		request(context, "GET",
			"/device/invite?token=${URLEncoder.encode(invite, "UTF-8")}", null)

	/** Redeems [invite], registering this installation's secret on first use. */
	fun join(context: Context, invite: String): Outcome =
		request(context, "POST", "/device/join", JSONObject()
			.put("invite", invite)
			.put("installationId", InstallationIdentity.id(context))
			.put("secret", InstallationIdentity.secret(context))
			// What the developer will see this phone called in their device
			// list. A starting point the account owner can rename.
			.put("label", "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}".trim()))

	private fun request(
		context: Context,
		method: String,
		path: String,
		body: JSONObject?,
	): Outcome {
		val connection = try {
			URL(RhrConfig.accountService(context) + path).openConnection() as HttpURLConnection
		} catch (_: IOException) {
			return Outcome.Refused("Could not reach the account service.")
		}
		return try {
			connection.requestMethod = method
			connection.connectTimeout = 10_000
			connection.readTimeout = 15_000
			if (body != null) {
				connection.doOutput = true
				connection.setRequestProperty("Content-Type", "application/json")
				connection.outputStream.use { it.write(body.toString().toByteArray()) }
			}
			val status = connection.responseCode
			val stream = if (status in 200..299) connection.inputStream else connection.errorStream
			val text = stream?.bufferedReader()?.use { it.readText() }.orEmpty()
			val json = try { JSONObject(text) } catch (_: JSONException) { null }
			when {
				status in 200..299 && json != null -> Outcome.Ok(json)
				else -> Outcome.Refused(
					json?.optString("error")?.takeIf { it.isNotBlank() }
						?: "The account service refused this invite.")
			}
		} catch (_: IOException) {
			Outcome.Refused("Could not reach the account service.")
		} finally {
			connection.disconnect()
		}
	}
}
