package dev.rhr.rhr_player

import android.content.Context
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
	companion object {
		// Keep the guest engine alive when Android destroys only the Activity
		// (for example, after the tester swipes the task away while the native
		// foreground session service keeps this process alive). The next Activity
		// instance reattaches to this engine instead of booting a second lobby.
		private var sessionEngine: FlutterEngine? = null
	}

	private var overlay: DevOverlay? = null

	override fun onCreate(savedInstanceState: Bundle?) {
		super.onCreate(savedInstanceState)
		// The library owns the tunnel; the player owns the over-the-wire
		// self-update (PackageInstaller). Registered before any session can
		// start so an update arriving mid-session always has a handler.
		RhrSessionService.updateHandlerFactory = { ctx, sendText, sendBinary ->
			RhrPlayerUpdater(ctx, sendText, sendBinary)
		}
	}

	override fun provideFlutterEngine(context: Context): FlutterEngine? = sessionEngine

	override fun shouldDestroyEngineWithHost(): Boolean = false

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
								.putExtra("preferDirect", call.argument<Boolean>("preferDirect") ?: false))
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
						result.success(null)
					}
					"status" -> result.success(RhrSessionService.status)
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
	}
}
