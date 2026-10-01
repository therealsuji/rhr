package dev.rhr.agent

import android.content.ContentProvider
import android.content.ContentValues
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import android.os.Process
import org.json.JSONObject

/**
 * Where the player passes device-control requests. It answers only an app
 * signed with this app's own key, which is how a phone's RHR player and its
 * RHR Agent recognize each other; nothing else on the phone gets control.
 *
 * Each request is its own binder call on purpose. Samsung freezes a
 * background process whenever no binder call is running in it, accessibility
 * service or not (seen on Android 16, 2026-10-01): a request loop on a socket
 * stalled a few seconds after the call that opened it.
 */
class AgentProvider : ContentProvider() {
	override fun onCreate() = true

	/** "request": [arg] is the request JSON; the answer is under "response". */
	override fun call(method: String, arg: String?, extras: Bundle?): Bundle? {
		if (method != "request") return null
		val context = context ?: return null
		if (context.packageManager.checkSignatures(Binder.getCallingUid(), Process.myUid()) !=
			PackageManager.SIGNATURE_MATCH) {
			throw SecurityException("RHR Agent only serves the RHR player signed with its key.")
		}
		val request = JSONObject(arg ?: "{}")
		val response = AgentService.running?.answer(request)
			?: JSONObject()
				.put("id", request.optInt("id"))
				.put("error", "accessibility_off")
				.put(
					"message",
					"RHR Agent is installed but off. On the phone, open RHR Agent and turn it on in " +
						"Settings > Accessibility > Installed apps.",
				)
		return Bundle().apply { putString("response", response.toString()) }
	}

	override fun query(uri: Uri, projection: Array<String>?, selection: String?, args: Array<String>?, sort: String?): Cursor? = null
	override fun getType(uri: Uri): String? = null
	override fun insert(uri: Uri, values: ContentValues?): Uri? = null
	override fun delete(uri: Uri, selection: String?, args: Array<String>?) = 0
	override fun update(uri: Uri, values: ContentValues?, selection: String?, args: Array<String>?) = 0
}
