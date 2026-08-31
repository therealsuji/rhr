package dev.rhr.rhr_connector

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import dev.rhr.rhr_player.RhrSessionService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import rikka.shizuku.Shizuku

class MainActivity : FlutterActivity() {
	private val main = Handler(Looper.getMainLooper())
	private lateinit var channel: MethodChannel

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)
		channel = MethodChannel(
			flutterEngine.dartExecutor.binaryMessenger, "rhr/connector")
		channel.setMethodCallHandler { call, result ->
			when (call.method) {
				"setupState" -> result.success(shizukuState())
				"installShizuku" -> {
					ShizukuGate.installFromAssets(this)
					result.success(null)
				}
				"openShizuku" -> {
					ShizukuGate.openManager(this)
					result.success(null)
				}
				"requestPermission" -> {
					ShizukuGate.requestPermission(this)
					result.success(null)
				}
				"listApps" -> result.success(listConnectableApps())
				"launchApp" -> {
					val pkg = call.argument<String>("package")
					val ok = pkg != null && ShellVm.launch(pkg, applicationContext)
					result.success(ok)
				}
				"connectTarget" -> {
					val pkg = call.argument<String>("package")
					val relay = call.argument<String>("relay")
					val code = call.argument<String>("code")
					if (pkg == null || relay == null || code == null) {
						result.error("args", "missing package/relay/code", null)
					} else {
						// Foreground priority FIRST: launching the target
						// pushes the connector to the background, and Samsung
						// kills backgrounded processes mid-discovery.
						startForegroundService(
							android.content.Intent(this, TunnelKeeperService::class.java))
						// Discovery can take up to ~30 s (cold start + log
						// tail): run it off-main, deliver on main. The tunnel
						// itself then runs in the NATIVE RhrSessionService
						// (bridge-android) — it survives the connector being
						// backgrounded, exactly like the player's.
						Thread {
							val uri = ShellVm.discoverVmUriBlocking(
								pkg, applicationContext, 30_000
							) { msg -> main.post { channel.invokeMethod("progress", msg) } }
							main.post {
								if (uri == null) {
									result.error(
										"no_vm",
										"no VM service line found for $pkg — is it a debug build?",
										null)
									return@post
								}
								startForegroundService(
									android.content.Intent(this, RhrSessionService::class.java)
										.putExtra("cmd", "start")
										.putExtra("relayUrl", relay)
										.putExtra("code", code)
										.putExtra("vmUri", uri))
								result.success(uri)
							}
						}.start()
					}
				}
				else -> result.notImplemented()
			}
		}
		// Keep the permission result fresh for Dart's setupState polling.
		Shizuku.addRequestPermissionResultListener { _, _ ->
			main.post { channel.invokeMethod("setupChanged", null) }
		}
	}

	private fun shizukuState(): Map<String, Boolean> = mapOf(
		"managerInstalled" to ShizukuGate.isManagerInstalled(this),
		"serverRunning" to ShizukuGate.isServerRunning(),
		"permission" to ShizukuGate.hasPermission(),
	)

	/** Third-party launcher apps, minus our own family — the target picker. */
	private fun listConnectableApps(): List<Map<String, String>> {
		val pm = packageManager
		return pm.getInstalledPackages(PackageManager.GET_META_DATA)
			.filter { info ->
				val appInfo = info.applicationInfo
				appInfo != null && (appInfo.flags and ApplicationInfo.FLAG_SYSTEM) == 0
			}
			.filter { it.packageName != packageName &&
				!it.packageName.startsWith("dev.rhr.") }
			.mapNotNull { info ->
				val appInfo = info.applicationInfo ?: return@mapNotNull null
				val label = appInfo.loadLabel(pm)?.toString() ?: return@mapNotNull null
				mapOf(
					"package" to info.packageName,
					"label" to label,
					"debuggable" to
						((appInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0).toString(),
				)
			}
			.sortedBy { it["label"]?.lowercase() ?: "" }
	}

}
