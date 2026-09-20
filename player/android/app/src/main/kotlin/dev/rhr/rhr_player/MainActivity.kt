package dev.rhr.rhr_player

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import dev.rhr.adb.AdbConnection
import dev.rhr.adb.PairingNotificationService
import dev.rhr.adb.ShellVm
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
	private val main = Handler(Looper.getMainLooper())
	private lateinit var connector: MethodChannel

	/** Resumed once the POST_NOTIFICATIONS prompt is answered, either way. */
	private var pendingAfterNotificationPrompt: (() -> Unit)? = null

	companion object {
		private const val REQ_POST_NOTIFICATIONS = 4801

		// Keep the guest engine alive when Android destroys only the Activity
		// (for example, after the tester swipes the task away while the native
		// foreground session service keeps this process alive). The next Activity
		// instance reattaches to this engine instead of booting a second lobby.
		private var sessionEngine: FlutterEngine? = null
	}

	private var overlay: DevOverlay? = null

	/** An `rhr://` invitation this launch carried, until Dart collects it. */
	private var pendingInvite: String? = null

	override fun onCreate(savedInstanceState: Bundle?) {
		super.onCreate(savedInstanceState)
		readInvite(intent)
		// The library owns the tunnel; the player owns the over-the-wire
		// self-update (PackageInstaller). Registered before any session can
		// start so an update arriving mid-session always has a handler.
		RhrSessionService.updateHandlerFactory = { ctx, sendText, sendBinary ->
			RhrPlayerUpdater(ctx, sendText, sendBinary)
		}
	}

	override fun provideFlutterEngine(context: Context): FlutterEngine? = sessionEngine

	override fun shouldDestroyEngineWithHost(): Boolean = false

	override fun onNewIntent(intent: Intent) {
		super.onNewIntent(intent)
		// A link that arrives while the player is already open.
		readInvite(intent)
		if (pendingInvite != null) {
			connector.invokeMethod("inviteArrived", pendingInvite)
			pendingInvite = null
		}
	}

	/**
	 * Pulls an invitation payload out of an `rhr://join?...` link.
	 *
	 * The same JSON a QR carries, so both arrive at one consent screen — the
	 * difference is only how it reached the phone.
	 */
	private fun readInvite(intent: Intent?) {
		val data = intent?.data ?: return
		if (data.scheme != "rhr" || data.host != "join") return
		pendingInvite = data.getQueryParameter("payload")
	}

	override fun onPostResume() {
		super.onPostResume()
		// Attach the native dev overlay above the Flutter surface once the
		// content view exists. Idempotent-guarded so config changes don't stack.
		if (overlay == null) {
			overlay = DevOverlay(this).also { it.attach() }
		}
	}

	override fun onDestroy() {
		overlay?.detach()
		overlay = null
		super.onDestroy()
	}

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		sessionEngine = flutterEngine
		super.configureFlutterEngine(flutterEngine)
		MethodChannel(
			flutterEngine.dartExecutor.binaryMessenger, "rhr/session")
			.setMethodCallHandler { call, result ->
				when (call.method) {
					"start" -> {
						val relayUrls = call.argument<List<String>>("relayUrls")
							?.filter { it.isNotBlank() }
							?: emptyList()
						startForegroundService(
							Intent(this, RhrSessionService::class.java)
								.putExtra("cmd", "start")
								.putExtra("relayUrl", call.argument<String>("relayUrl"))
								.putStringArrayListExtra("relayUrls", ArrayList(relayUrls))
								.putExtra("code", call.argument<String>("code"))
								.putExtra("vmUri", call.argument<String>("vmUri"))
								.putExtra("preferDirect", call.argument<Boolean>("preferDirect") ?: true))
						result.success(null)
					}
					"kick" -> {
						startService(
							Intent(this, RhrSessionService::class.java)
								.putExtra("cmd", "kick"))
						result.success(null)
					}
					"stop" -> {
						startService(
							Intent(this, RhrSessionService::class.java)
								.putExtra("cmd", "stop"))
						// No session, nothing for the bubble to report.
						OverlayService.stop(this)
						result.success(null)
					}
					"status" -> result.success(RhrSessionService.status)
					// The lobby used to render the raw status and nothing
					// else, so it had no idea phases existed: a build that
					// takes minutes left it saying "Connecting…", and so did
					// a session that had been deliberately stopped. It asks
					// for the decided banner now — the same one the native
					// overlay paints, from the same pure function.
					"banner" -> {
						val banner = SessionBanner.of(
							phase = RhrSessionService.progressPhase,
							status = RhrSessionService.status,
							done = RhrSessionService.progressDone.toLong(),
							total = RhrSessionService.progressTotal.toLong(),
							message = RhrSessionService.progressMessage,
							stalled = RhrSessionService.phaseStalled,
							foreignApp = RhrSessionService.updatingForeignApp,
						)
						result.success(
							mapOf(
								"label" to banner.label,
								"progress" to banner.progress,
								"style" to banner.style.name,
								"visible" to banner.isVisible,
								"status" to RhrSessionService.status,
							))
					}
					"debug/fault" -> {
						// QA fault injection. Hidden behind the
						// lobby's debug sheet; no-op names are harmless.
						RhrSessionService.debugInjectFault(
							call.argument<String>("name") ?: "clear")
						result.success(null)
					}
					else -> result.notImplemented()
				}
			}
		configureConnectorChannel(flutterEngine)
	}

	/**
	 * Connector mode: instead of hosting a guest project, tunnel an ALREADY
	 * INSTALLED debug app on this phone. The heavy lifting (pairing, mDNS
	 * port discovery, shell) lives in the adb-android module.
	 *
	 * Pairing is per-app by design: the RSA key adbd trusts sits in this
	 * app's private storage, so the player pairs once on its own.
	 */
	private fun configureConnectorChannel(flutterEngine: FlutterEngine) {
		connector = MethodChannel(
			flutterEngine.dartExecutor.binaryMessenger, "rhr/connector")
		connector.setMethodCallHandler { call, result ->
			when (call.method) {
				"setupState" -> {
					// `connected` does a real ADB roundtrip — keep it off the
					// platform main thread.
					Thread {
						val state = mapOf(
							"paired" to AdbConnection.paired(this),
							"connected" to AdbConnection.connected(this),
							// Connector mode talks to this phone's own adbd,
							// which only listens while Wireless debugging is
							// on — and the tester turns it off by rebooting,
							// or by Android turning it off for them. Without
							// this the screen could only say "Paired, but not
							// connected", which names the symptom and not the
							// one switch that fixes it.
							"wirelessDebugging" to wirelessDebuggingEnabled(),
						)
						main.post { result.success(state) }
					}.start()
				}
				"openWirelessDebugging" -> {
					startActivity(
						Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS))
					result.success(null)
				}
				"startPairing" -> {
					// The whole pairing UI IS a notification with an inline
					// code field. Without POST_NOTIFICATIONS (runtime-granted
					// since Android 13) the service starts, posts, and is
					// silently suppressed — the user sees nothing at all and
					// the flow looks broken. Ask first, start after.
					ensureNotificationPermission {
						PairingNotificationService.onResult = { ok ->
							main.post { connector.invokeMethod("pairingDone", ok) }
						}
						try {
							startForegroundService(
								Intent(this, PairingNotificationService::class.java))
							result.success(null)
						} catch (e: Exception) {
							PairingNotificationService.onResult = null
							result.error(
								"pairing", "could not start pairing: ${e.message}", null)
						}
					}
				}
				"connectAdb" -> {
					Thread {
						val ok = try {
							AdbConnection.ensureConnected(this)
						} catch (e: Exception) {
							Log.w(AdbConnection.TAG, "adb connect failed: $e")
							false
						}
						main.post { result.success(ok) }
					}.start()
				}
				"listApps" -> {
					// Walking every installed package touches the package manager
					// and, for apps with uncompressed libraries, real disk IO. On
					// the platform main thread that froze the route push animation.
					Thread {
						val apps = listConnectableApps()
						main.post { result.success(apps) }
					}.start()
				}
				"connectTarget" -> connectTarget(call, result)
				// The shake-to-open bubble needs "Display over other apps" to
				// draw above the tester's own app. There is no runtime prompt
				// for it — only a settings screen the user has to visit.
				// Who this installation is, for joining an account. The secret
				// deliberately stays native: Dart is replaced wholesale by a guest
				// hot restart, so anything a guest could read is not a secret.
				// An invitation that arrived as a link rather than a QR, if this
				// launch carried one. Consumed once: a relaunch must not
				// re-offer a join the tester already answered.
				"pendingInvite" -> {
					result.success(pendingInvite)
					pendingInvite = null
				}
				"installationId" -> result.success(InstallationIdentity.id(this))
				// Proves this installation is itself. The id alone is public —
				// it appears in device listings — so anything that acts on a
				// membership has to carry this too.
				"installationSecret" -> result.success(
					InstallationIdentity.secret(this))
				// What the developer will see this phone called in their device
				// list. A starting point the account owner can rename, not an
				// identifier — the installation id is what identifies it.
				"deviceLabel" -> result.success(
					"${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}".trim())
				"overlayGranted" -> result.success(SystemOverlayHost.granted(this))
				"requestOverlay" -> {
					startActivity(SystemOverlayHost.permissionIntent(this))
					result.success(null)
				}
				else -> result.notImplemented()
			}
		}
	}

	private fun connectTarget(
		call: io.flutter.plugin.common.MethodCall,
		result: MethodChannel.Result,
	) {
		val pkg = call.argument<String>("package")
		val relay = call.argument<String>("relay")
		val code = call.argument<String>("code")
		if (pkg == null || relay == null || code == null) {
			result.error("args", "missing package/relay/code", null)
			return
		}
		val relayUrls = call.argument<List<String>>("relayUrls")
			?.filter { it.isNotBlank() }
			?: listOf(relay)
		Thread {
			// Launching the target pushes the player to the background, and
			// discovery can take tens of seconds; the session service is a
			// foreground service so OEM process killing does not cut it short.
			val vmUri = runCatching {
				ShellVm.discoverVmUriBlocking(pkg, applicationContext, 30_000) { msg ->
					main.post { connector.invokeMethod("progress", msg) }
				}
			}.getOrElse {
				main.post { result.error("no_vm", "discovery failed: $it", null) }
				return@Thread
			}
			main.post {
				if (vmUri == null) {
					result.error(
						"no_vm",
						"no VM service found for $pkg — is it a debug build?",
						null)
					return@post
				}
				try {
					startForegroundService(
						Intent(this, RhrSessionService::class.java)
							.putExtra("cmd", "start")
							.putExtra("relayUrl", relay)
							.putStringArrayListExtra("relayUrls", ArrayList(relayUrls))
							.putExtra("code", code)
							.putExtra("vmUri", vmUri)
							// The target owns its VM service, not this app, so
							// the service must not re-derive the URI from our
							// own logcat.
							.putExtra("watchVm", false)
							.putExtra("preferDirect", true))
					// The tester is about to be looking at THEIR app, not this
					// one, so the in-Activity overlay is no longer reachable.
					// The system-window one takes over — when permitted.
					if (SystemOverlayHost.granted(this)) OverlayService.start(this)
					result.success(vmUri)
				} catch (e: Exception) {
					result.error("fgs", "could not start session: ${e.message}", null)
				}
			}
		}.start()
	}

	/**
	 * Runs [proceed] once notifications are permitted, prompting if needed.
	 *
	 * Below Android 13 the permission is install-time, so this is a straight
	 * pass-through. On 13+ a denial still calls [proceed]: the pairing service
	 * remains useful (its foreground notification is exempt from the
	 * suppression that hides ordinary ones), and blocking the flow outright
	 * would be worse than a degraded one.
	 */
	private fun ensureNotificationPermission(proceed: () -> Unit) {
		if (android.os.Build.VERSION.SDK_INT < 33) {
			proceed()
			return
		}
		val granted = checkSelfPermission(
			android.Manifest.permission.POST_NOTIFICATIONS,
		) == android.content.pm.PackageManager.PERMISSION_GRANTED
		if (granted) {
			proceed()
			return
		}
		pendingAfterNotificationPrompt = proceed
		requestPermissions(
			arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
			REQ_POST_NOTIFICATIONS,
		)
	}

	override fun onRequestPermissionsResult(
		requestCode: Int,
		permissions: Array<out String>,
		grantResults: IntArray,
	) {
		super.onRequestPermissionsResult(requestCode, permissions, grantResults)
		if (requestCode != REQ_POST_NOTIFICATIONS) return
		val proceed = pendingAfterNotificationPrompt
		pendingAfterNotificationPrompt = null
		proceed?.invoke()
	}

	/**
	 * Flutter apps installed by the user — the target picker.
	 *
	 * Only Flutter apps can be hot reloaded, so listing anything else just
	 * makes the user scroll past apps that could never work. Detection is by
	 * the presence of libflutter.so in the APK's native libraries, which every
	 * Flutter app ships and nothing else does.
	 */
	private fun listConnectableApps(): List<Map<String, String>> {
		val pm = packageManager
		return pm.getInstalledApplications(0)
			.filter { (it.flags and ApplicationInfo.FLAG_SYSTEM) == 0 }
			.filter {
				it.packageName != packageName && !it.packageName.startsWith("dev.rhr.")
			}
			.mapNotNull { appInfo ->
				if (!isFlutterApp(appInfo)) return@mapNotNull null
				val label = appInfo.loadLabel(pm)?.toString() ?: return@mapNotNull null
				mapOf(
					"package" to appInfo.packageName,
					"label" to label,
					"debuggable" to
						((appInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0).toString(),
				)
			}
			.sortedBy { it["label"]?.lowercase() ?: "" }
	}

	/**
	 * True when the app bundles the Flutter engine.
	 *
	 * nativeLibraryDir holds the libraries the installer extracted for this
	 * device's ABI, so this sees what actually landed on the phone. An app that
	 * ships its libraries uncompressed inside the APK has an empty directory,
	 * so fall back to scanning the APK entries before concluding "not Flutter".
	 */
	private fun isFlutterApp(appInfo: ApplicationInfo): Boolean {
		val libDir = appInfo.nativeLibraryDir?.let { java.io.File(it) }
		if (libDir != null && libDir.isDirectory) {
			val names = libDir.list()
			if (names != null && names.isNotEmpty()) {
				return names.any { it.equals("libflutter.so", ignoreCase = true) }
			}
		}
		return apkContainsFlutterLib(appInfo.sourceDir)
	}

	/**
	 * Whether Wireless debugging is on, which connector mode needs.
	 *
	 * `adb_wifi_enabled` is the setting the Developer options toggle writes.
	 * It is readable without a permission, but it is not a documented
	 * constant, so treat an unreadable value as "no answer" rather than as
	 * "off" — claiming the switch is off when it might be on sends the
	 * tester somewhere that looks already correct.
	 */
	private fun wirelessDebuggingEnabled(): Boolean? = try {
		when (Settings.Global.getInt(contentResolver, "adb_wifi_enabled", -1)) {
			1 -> true
			0 -> false
			else -> null
		}
	} catch (e: Exception) {
		Log.w(AdbConnection.TAG, "could not read adb_wifi_enabled: $e")
		null
	}

	/** Scans an APK's entry names for a bundled libflutter.so. */
	private fun apkContainsFlutterLib(sourceDir: String?): Boolean {
		if (sourceDir == null) return false
		return try {
			java.util.zip.ZipFile(sourceDir).use { zip ->
				zip.entries().asSequence().any { entry ->
					entry.name.startsWith("lib/") &&
						entry.name.endsWith("/libflutter.so")
				}
			}
		} catch (e: Exception) {
			// An unreadable APK is not evidence either way; leaving it out
			// beats showing a target that cannot work.
			Log.w(AdbConnection.TAG, "could not inspect $sourceDir: $e")
			false
		}
	}
}
