package dev.rhr.rhr_player

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.os.Build
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * Downloads an APK from a GitHub release and hands it to Android's installer:
 * the player's own updates, and RHR Agent.
 *
 * What makes a download trustworthy is not where it came from but what it
 * is: the package the caller expects, signed with the player's own key, and
 * (for the player) the digest the release published. Blocking calls; run
 * them off the main thread.
 */
internal object ReleaseApk {
	private const val RELEASES = "https://github.com/therealsuji/rhr/releases/download"

	fun url(version: String, name: String) = URL("$RELEASES/v$version/$name")

	/**
	 * Downloads [url] into [to], or returns why it could not. A [to] left by
	 * an earlier attempt is continued from where it stopped when the server
	 * allows, so a dropped connection costs only what was not yet received.
	 * [onProgress] gets bytes received and the total, when known.
	 */
	fun download(
		url: URL,
		to: File,
		maxBytes: Long,
		onProgress: (done: Long, total: Long) -> Unit = { _, _ -> },
	): String? {
		val have = if (to.exists()) to.length() else 0L
		val connection = url.openConnection() as HttpURLConnection
		connection.connectTimeout = 15_000
		connection.readTimeout = 30_000
		if (have > 0) connection.setRequestProperty("Range", "bytes=$have-")
		try {
			val resumed = when (connection.responseCode) {
				206 -> true
				200 -> false
				// The bytes we have are already the whole file.
				416 -> return null
				404 -> return "Not found: ${url.path.substringAfterLast('/')}"
				else -> return "GitHub answered ${connection.responseCode}. Try again later."
			}
			val start = if (resumed) have else 0L
			val total = connection.contentLengthLong.let { if (it >= 0) start + it else -1L }
			if (total > maxBytes) return "The download is larger than expected."
			var done = start
			onProgress(done, total)
			connection.inputStream.use { input ->
				FileOutputStream(to, resumed).use { output ->
					val buffer = ByteArray(64 * 1024)
					while (true) {
						val read = input.read(buffer)
						if (read < 0) break
						done += read
						if (done > maxBytes) return "The download is larger than expected."
						output.write(buffer, 0, read)
						onProgress(done, total)
					}
				}
			}
			return if (total >= 0 && done != total) "The download stopped early. Try again." else null
		} finally {
			connection.disconnect()
		}
	}

	/** The digest the release lists for [name] in its SHA256SUMS, or null. */
	fun publishedSha256(version: String, name: String): String? {
		val connection = url(version, "SHA256SUMS").openConnection() as HttpURLConnection
		connection.connectTimeout = 15_000
		connection.readTimeout = 15_000
		return try {
			if (connection.responseCode != 200) return null
			connection.inputStream.bufferedReader().useLines { lines ->
				lines.map { it.trim().split(Regex("\\s+")) }
					.firstOrNull { it.size == 2 && it[1].removePrefix("*") == name }
					?.first()?.lowercase()
			}
		} finally {
			connection.disconnect()
		}
	}

	fun sha256(file: File): String {
		val digest = MessageDigest.getInstance("SHA-256")
		file.inputStream().use { input ->
			val buffer = ByteArray(64 * 1024)
			while (true) {
				val read = input.read(buffer)
				if (read < 0) break
				digest.update(buffer, 0, read)
			}
		}
		return digest.digest().joinToString("") { "%02x".format(it) }
	}

	fun archiveInfo(context: Context, apk: File): PackageInfo? =
		context.packageManager.getPackageArchiveInfo(apk.path, signingFlags())

	fun ownInfo(context: Context): PackageInfo =
		context.packageManager.getPackageInfo(context.packageName, signingFlags())

	/** Whether [info] is signed with exactly the player's own key. */
	fun signedLikePlayer(context: Context, info: PackageInfo): Boolean =
		certificates(info).let { it.isNotEmpty() && it == certificates(ownInfo(context)) }

	@Suppress("DEPRECATION")
	fun versionCode(info: PackageInfo): Long =
		if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

	/**
	 * Hands [apk] to Android's installer for [packageName]. Android answers
	 * [receiver] with the result, starting with the confirmation sheet the
	 * user has to tap.
	 */
	fun commit(context: Context, apk: File, packageName: String, receiver: Intent) {
		val installer = context.packageManager.packageInstaller
		val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
			.apply {
				setAppPackageName(packageName)
				setSize(apk.length())
			}
		val sessionId = installer.createSession(params)
		installer.openSession(sessionId).use { session ->
			session.openWrite("update.apk", 0, apk.length()).use { out ->
				apk.inputStream().use { it.copyTo(out) }
				session.fsync(out)
			}
			val pending = PendingIntent.getBroadcast(
				context,
				sessionId,
				receiver,
				PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
			)
			session.commit(pending.intentSender)
		}
	}

	@Suppress("DEPRECATION")
	private fun signingFlags(): Int =
		if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES
		else PackageManager.GET_SIGNATURES

	/** SHA-256 of each signing certificate, as a set to compare. */
	@Suppress("DEPRECATION")
	private fun certificates(info: PackageInfo): Set<String> {
		val signatures = if (Build.VERSION.SDK_INT >= 28) {
			info.signingInfo?.apkContentsSigners
		} else {
			info.signatures
		} ?: return emptySet()
		val sha = MessageDigest.getInstance("SHA-256")
		return signatures.map { signature ->
			sha.digest(signature.toByteArray()).joinToString("") { "%02x".format(it) }
		}.toSet()
	}
}
