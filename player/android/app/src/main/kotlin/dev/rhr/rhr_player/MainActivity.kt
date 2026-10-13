package dev.rhr.rhr_player

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
	private val main = Handler(Looper.getMainLooper())
	private lateinit var connector: MethodChannel


	/** adb entry point for the QA faults; null unless the build opted in. */
	private var debugFaultReceiver: DebugFaultReceiver? = null

	companion object {
		// Keep the guest engine alive when Android destroys only the Activity
		// (for example, after the user swipes the task away while the native
		// foreground session service keeps this process alive). The next Activity
		// instance reattaches to this engine instead of booting a second lobby.
		private var sessionEngine: FlutterEngine? = null
	}

	private var overlay: DevOverlay? = null

	/** An `rhr://` invitation this launch carried, until Dart collects it. */
	private var pendingInvite: String? = null
	private var pendingSessionLink: String? = null

	override fun onCreate(savedInstanceState: Bundle?) {
		val reusedEngine = sessionEngine != null
		super.onCreate(savedInstanceState)
		readInvite(intent)
		if (reusedEngine) Handler(Looper.getMainLooper()).post { deliverSessionLink() }
		// The library owns the tunnel; the player owns the over-the-wire
		// self-update (PackageInstaller). Registered before any session can
		// start so an update arriving mid-session always has a handler.
		RhrSessionService.updateHandlerFactory = { ctx, sendText, sendBinary ->
			RhrPlayerUpdater(ctx, sendText, sendBinary)
		}
		RhrSessionService.runRequestHandler = RunPreparation::handle
		registerDebugFaultReceiver()
	}

	/**
	 * Lets adb drive the QA faults on a debug build. See [DebugFaultReceiver].
	 *
	 * On the Activity rather than the session service, because the service
	 * only exists while a session is running — and the resting lobby, where
	 * no service is alive, is exactly where a banner test starts. Registered
	 * there, every fault injected before the first connection reached
	 * nothing, while `am broadcast` still reported success.
	 *
	 * In code rather than the manifest so a published player has nothing to
	 * export; [AdbReceivers] decides whether this build may register it.
	 */
	private fun registerDebugFaultReceiver() {
		if (debugFaultReceiver != null) return
		val receiver = DebugFaultReceiver()
		if (AdbReceivers.register(this, receiver, DebugFaultReceiver.ACTION)) {
			debugFaultReceiver = receiver
		}
	}

	override fun provideFlutterEngine(context: Context): FlutterEngine? = sessionEngine

	override fun shouldDestroyEngineWithHost(): Boolean = false

	override fun onNewIntent(intent: Intent) {
		super.onNewIntent(intent)
		// A link that arrives while the player is already open.
		readInvite(intent)
		deliverSessionLink()
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
		if (data.scheme == "rhr" && data.host == "connect") {
			pendingSessionLink = data.toString()
			return
		}
		if (data.scheme != "rhr" || data.host != "join") return
		pendingInvite = data.getQueryParameter("payload")
	}

	private fun deliverSessionLink() {
		val link = pendingSessionLink ?: return
		val handler = Handler(Looper.getMainLooper())
		var answered = false
		val restoreLobby = Runnable {
			if (!answered && pendingSessionLink == link && !isFinishing && !isDestroyed) {
				answered = true
				// A guest may buffer the channel call forever because its kernel has no lobby handler.
				android.app.AlertDialog.Builder(this@MainActivity)
					.setTitle("Open RHR connection?")
					.setMessage("This leaves the running preview and returns to RHR to open the link.")
					.setNegativeButton("Stay here") { _, _ -> pendingSessionLink = null }
					.setPositiveButton("Open RHR") { _, _ ->
						val restart = Intent.makeRestartActivityTask(componentName)
						restart.action = Intent.ACTION_VIEW
						restart.data = android.net.Uri.parse(link)
						startService(Intent(this@MainActivity, RhrSessionService::class.java).putExtra("cmd", "stop"))
						startActivity(restart)
						finishAffinity()
						Runtime.getRuntime().exit(0)
					}.show()
			}
		}
		handler.postDelayed(restoreLobby, 2000)
		connector.invokeMethod("sessionLinkArrived", link, object : MethodChannel.Result {
			override fun success(result: Any?) {
				if (result == true) {
					answered = true
					handler.removeCallbacks(restoreLobby)
					if (pendingSessionLink == link) pendingSessionLink = null
				} else restoreLobby.run()
			}
			override fun error(code: String, message: String?, details: Any?) { restoreLobby.run() }
			override fun notImplemented() { restoreLobby.run() }
		})
	}

	override fun onPostResume() {
		super.onPostResume()
		OverlayService.setPlayerVisible(true)
		RhrSessionService.updateListeners.add(keepScreenOn)
		keepScreenOn()
		// Attach the native dev overlay above the Flutter surface once the
		// content view exists. Idempotent-guarded so config changes don't stack.
		if (overlay == null) {
			overlay = DevOverlay(this).also { it.attach() }
		}
	}

	override fun onPause() {
		RhrSessionService.updateListeners.remove(keepScreenOn)
		overlay?.detach()
		overlay = null
		OverlayService.setPlayerVisible(false)
		super.onPause()
	}

	// The session service's overlay holds the screen when the player may draw
	// over other apps. Without that permission, this keeps the player's own
	// screen on for the session, from the moment it starts connecting.
	private val keepScreenOn: () -> Unit = {
		runOnUiThread {
			if (RhrSessionService.holdsScreen)
				window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
			else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
		}
	}

	override fun onDestroy() {
		overlay?.detach()
		overlay = null
		debugFaultReceiver?.let {
			try { unregisterReceiver(it) } catch (_: IllegalArgumentException) {}
		}
		debugFaultReceiver = null
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
								.putExtra("relayPin", call.argument<String>("relayPin"))
								.putExtra("code", call.argument<String>("code"))
								.putExtra("vmUri", call.argument<String>("vmUri"))
								.putExtra("preferDirect", call.argument<Boolean>("preferDirect") ?: true))
						result.success(null)
					}
					"installSettings" -> {
						startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
							android.net.Uri.parse("package:$packageName")))
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
							foreignAppName = RhrSessionService.foreignAppName,
						)
						result.success(
							mapOf(
								"label" to banner.label,
								"progress" to banner.progress,
								"style" to banner.style.name,
								"visible" to banner.isVisible,
								"status" to RhrSessionService.status,
								"setupAction" to RunPreparation.setupAction,
								"setupMessage" to RunPreparation.setupMessage,
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
				// An invitation that arrived as a link rather than a QR, if this
				// launch carried one. Consumed once: a relaunch must not
				// re-offer a join the user already answered.
				"pendingInvite" -> {
					result.success(pendingInvite)
					pendingInvite = null
				}
				"pendingSessionLink" -> {
					result.success(pendingSessionLink)
					pendingSessionLink = null
				}
				// Who this installation is. Public: it names the phone's
				// rendezvous and appears in device listings.
				"installationId" -> result.success(InstallationIdentity.id(this))
				// The account service this build trusts, so the lobby can tell
				// the user when an invite was made for a different one.
				"accountService" -> result.success(RhrConfig.accountService(this))
				// Invites are read and redeemed here rather than in Dart. The
				// join carries the installation secret, and Dart is replaced
				// wholesale by a guest hot restart, so no Dart code ever sees it.
				"previewInvite" -> accountCall(result) {
					AccountClient.previewInvite(this, call.argument<String>("invite").orEmpty())
				}
				"joinAccount" -> accountCall(result) {
					AccountClient.join(this, call.argument<String>("invite").orEmpty())
				}
				// The shake-to-open bubble needs "Display over other apps" to
				// draw above the user's own app. There is no runtime prompt
				// for it — only a settings screen the user has to visit.
				"overlayGranted" -> result.success(SystemOverlayHost.granted(this))
				"requestOverlay" -> {
					startActivity(SystemOverlayHost.permissionIntent(this))
					result.success(null)
				}
				// Agent control, set up from the phone (see AgentSetup).
				"agentStatus" -> result.success(AgentSetup.status(this))
				"installAgent" -> Thread {
					val problem = AgentSetup.install(this)
					runOnUiThread { result.success(problem) }
				}.start()
				"openAgent" -> {
					AgentSetup.open(this)
					result.success(null)
				}
				else -> result.notImplemented()
			}
		}
	}

	/** Runs a blocking account request off the main thread, answering on it. */
	private fun accountCall(
		result: MethodChannel.Result,
		request: () -> AccountClient.Outcome,
	) {
		Thread {
			val answer = when (val outcome = request()) {
				is AccountClient.Outcome.Ok -> outcome.body.toString()
				is AccountClient.Outcome.Refused ->
					org.json.JSONObject().put("error", outcome.reason).toString()
			}
			main.post { result.success(answer) }
		}.start()
	}
}
