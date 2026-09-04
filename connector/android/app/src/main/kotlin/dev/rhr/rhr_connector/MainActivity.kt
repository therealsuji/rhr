package dev.rhr.rhr_connector

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import dev.rhr.rhr_player.RhrSessionService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
	private val main = Handler(Looper.getMainLooper())
	private lateinit var channel: MethodChannel

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)
		channel = MethodChannel(
			flutterEngine.dartExecutor.binaryMessenger, "rhr/connector")
		channel.setMethodCallHandler { call, result ->
			when (call.method) {
				"setupState" -> {
					// `connected` pings the live ADB connection — keep the
					// socket I/O off the platform main thread.
					Thread {
						val state = setupState()
						main.post { result.success(state) }
					}.start()
				}
				"openWirelessDebugging" -> {
					// Deep-link to the exact screen: Developer options →
					// Wireless debugging (where pairing + the port live).
					startActivity(Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS))
					result.success(null)
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
				"listApps" -> result.success(listConnectableApps())
				"connectTarget" -> {
					val pkg = call.argument<String>("package")
					val relay = call.argument<String>("relay")
					val code = call.argument<String>("code")
					if (pkg == null || relay == null || code == null) {
						result.error("args", "missing package/relay/code", null)
					} else {
						// Foreground priority first: launching the target
						// pushes the connector to the background, and OEMs
						// kill backgrounded processes mid-discovery.
						try {
							startForegroundService(
								android.content.Intent(this, TunnelKeeperService::class.java)
									.putExtra("code", code)
									.putExtra("label", pkg))
						} catch (e: Exception) {
							Log.w(AdbConnection.TAG, "FGS deferred: $e")
						}
						Thread {
							val vmUri = runCatching {
								ShellVm.discoverVmUriBlocking(
									pkg, applicationContext, 30_000
								) { msg -> main.post { channel.invokeMethod("progress", msg) } }
							}.getOrElse {
								main.post {
									result.error("no_vm", "discovery failed: $it", null)
								}
								return@Thread
							}
							main.post {
								if (vmUri == null) {
									result.error(
										"no_vm",
										"no VM service line found for $pkg — is it a debug build?",
										null)
								} else {
									try {
										startForegroundService(
											android.content.Intent(this, RhrSessionService::class.java)
												.putExtra("cmd", "start")
												.putExtra("relayUrl", relay)
												.putExtra("code", code)
												.putExtra("vmUri", vmUri)
												.putExtra("watchVm", false)
												.putExtra("preferDirect", true))
									} catch (e: Exception) {
										Log.w(AdbConnection.TAG, "FGS deferred: $e")
									}
									result.success(vmUri)
								}
							}
						}.start()
					}
				}
				"startPairing" -> {
					// ONE-TIME pairing: the notification service runs the
					// flow; the result arrives later as 'pairingDone'.
					PairingNotificationService.onResult = { ok ->
						main.post { channel.invokeMethod("pairingDone", ok) }
					}
					try {
						startForegroundService(
							android.content.Intent(this, PairingNotificationService::class.java))
					} catch (e: Exception) {
						PairingNotificationService.onResult = null
						Log.w(AdbConnection.TAG, "pairing service start deferred: $e")
					}
					result.success(null)
				}
				else -> result.notImplemented()
			}
		}
	}

	private fun setupState(): Map<String, Boolean> = mapOf(
		"paired" to AdbConnection.paired(this),
		"connected" to AdbConnection.connected(this),
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
