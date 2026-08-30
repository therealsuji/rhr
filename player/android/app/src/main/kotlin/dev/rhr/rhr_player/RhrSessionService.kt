package dev.rhr.rhr_player

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.FileObserver
import android.os.IBinder
import android.system.Os
import android.util.Log
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.json.JSONObject

/**
 * Native end of the rhr tunnel. Lives OUTSIDE the Dart world on purpose: a
 * guest app's hot restart swaps the entire Dart kernel and would kill any
 * Dart-side bridge (verified 2026-07-20). A foreground service also survives
 * Android's freezing of backgrounded apps.
 *
 * Protocol (mirror of bridge/lib/tunnel.dart):
 *   TEXT frames   = JSON control ({"t":"info","vm":<uri>} announced device->dev)
 *   BINARY frames = [1B op][4B channel BE][payload]; op 0=open 1=data 2=close
 *                   3=ack (payload = 4B consumed-byte count, flow control,
 *                   512KB window per channel)
 */
class RhrSessionService : Service() {
	companion object {
		private const val TAG = "rhr_service"
		private const val CHANNEL_ID = "rhr_session"
		private const val NOTIF_ID = 7411
		private const val OP_OPEN = 0
		private const val OP_DATA = 1
		private const val OP_CLOSE = 2
		private const val OP_ACK = 3
		private const val OP_UPDATE_DATA = 4
		private const val WINDOW_BYTES = 512 * 1024
		private const val LOW_WATER = WINDOW_BYTES / 2

		// Developer presence lease: while the CLI is attached it pings every 20s
		// (all dev frames are forwarded to us by the dumb relay). If we hear
		// nothing for this long, the developer is gone — surface "Waiting for
		// developer" and clear any progress that belonged to their connection.
		private const val DEV_LEASE_MS = 45_000L

		// The running service instance, so the dev-menu fault injector can reach
		// instance state (the live WebSocket) from a static context.
		@Volatile var current: RhrSessionService? = null

		// Total bytes of cached per-project asset stores (filesDir/assets).
		fun assetCacheSizeBytes(): Long {
			val assets = File(current?.filesDir ?: return 0L, "assets")
			if (!assets.exists()) return 0L
			var total = 0L
			assets.walkTopDown().forEach { if (it.isFile) total += it.length() }
			return total
		}

		// Wipe all cached per-project asset stores. The next sync is cold;
		// DevFS symlinks dangling into the deleted store are swept/re-created
		// on the next session start.
		fun clearAssetCaches() {
			val assets = File(current?.filesDir ?: return, "assets")
			if (assets.exists() && assets.deleteRecursively()) {
				Log.i(TAG, "cleared per-project asset caches")
			}
		}

		// Deliberate fault injection for QA / state-machine testing. Hidden
		// behind the dev menu's "Test faults" section; not reachable by normal
		// users. "relay-loss" is real (closes the live socket → genuine
		// onFailure/retry path); the others force a status/phase for UI checks.
		fun debugInjectFault(name: String) {
			when (name) {
				"clear" -> {
					setProgress("", 0, 0)
					status = if (current?.reconnectThread?.isAlive == true) "waiting_dev" else "idle"
				}
				"relay-loss" -> current?.ws?.close(4001, "fault: relay loss")
				"status-retrying" -> status = "retrying"
				"status-rejected" -> status = "rejected"
				"status-waiting" -> status = "waiting_dev"
				"status-connected" -> status = "connected"
				"phase-restarting" -> setProgress("restarting", 0, 0)
				"phase-awaiting-restart" -> setProgress("awaiting_restart", 0, 0)
				"phase-reloading" -> setProgress("reloading", 0, 0)
				"clear-cache" -> clearAssetCaches()
			}
			Log.i(TAG, "debug fault injected: $name")
		}

		// Latest status, readable by the lobby over the MethodChannel. Setting
		// it also nudges the native overlay to redraw the connection indicator.
		@Volatile var status: String = "idle"
			private set(value) {
				field = value
				onUpdate?.invoke()
			}

		// Latest session code / VM URI, surfaced in the native dev menu so the
		// tester can see them even after the guest app has taken the screen.
		@Volatile var currentCode: String = ""
			private set
		@Volatile var currentVm: String = ""
			private set

		// Latest transfer/lifecycle progress, pushed by the dev over the tunnel
		// ({"t":"progress",...}) or set locally (e.g. "restarting"). The native
		// overlay in MainActivity renders this above the Flutter surface — it
		// must be native because a guest kernel owns the Flutter UI after boot.
		//
		// phase: "" (idle) | "assets" | "syncing" | "awaiting_restart" |
		//        "restarting" | "reloading"
		@Volatile var progressPhase: String = ""
			private set
		@Volatile var progressDone: Int = 0
			private set
		@Volatile var progressTotal: Int = 0
			private set
		// True when an indeterminate phase ("restarting" etc.) has sat without
		// movement past its budget — a stalled operation, not silent progress.
		@Volatile var phaseStalled: Boolean = false
			private set(value) {
				field = value
				onUpdate?.invoke()
			}

		// When the current progress phase began, used for stall detection.
		@Volatile private var phaseSetAt = 0L
		// MainActivity registers here to be pinged whenever status/progress
		// changes, so the overlay redraws without polling. Called on any thread.
		@Volatile var onUpdate: (() -> Unit)? = null

		private fun setProgress(phase: String, done: Int, total: Int) {
			progressPhase = phase
			progressDone = done
			progressTotal = total
			if (phase.isEmpty()) {
				phaseSetAt = 0L
				phaseStalled = false
			} else {
				phaseSetAt = System.currentTimeMillis()
			}
			onUpdate?.invoke()
		}
	}

	// OkHttp handles keepalive (PING/PONG) and connection health itself — this
	// was the verified-working POC config. Let the library own reconnection
	// timing; do NOT hand-roll a keepalive loop on top (that raced onOpen and
	// spawned a reconnect storm).
	private val client =
		OkHttpClient.Builder().pingInterval(20, TimeUnit.SECONDS).build()
	private var ws: WebSocket? = null
	private val stopped = AtomicBoolean(false)
	private var relayUrls: List<String> = emptyList()
	@Volatile private var activeRelayUrl = ""
	private var sessionCode = ""
	private var vmUri = ""
	private var projectHint: String? = null
	private val sockets = ConcurrentHashMap<Int, Socket>()
	private val readers = ConcurrentHashMap<Int, Thread>()
	// Invariant: data frames can race the channel's TCP connect —
	// buffer them until the socket is ready, never drop them.
	private val pending = ConcurrentHashMap<Int, java.io.ByteArrayOutputStream>()
	// Per-channel unacked byte counts; readers block on the lock when full.
	private val unacked = ConcurrentHashMap<Int, Int>()
	private val flowLock = Object()
	private var reconnectThread: Thread? = null
	// A reconnect loop belongs to the session code it was created for. The
	// service can receive a new code while the old OkHttp callback is still
	// unwinding, so a boolean stopped flag alone is not enough: it gets reset
	// for the replacement session and lets the old loop dial the new code (or
	// block the new loop from starting).
	@Volatile private var sessionGeneration = 0L
	@Volatile private var reconnectGeneration: Long? = null
	private var vmWatchThread: Thread? = null
	// Optional direct payload path. This object deliberately lives beside the
	// relay WebSocket in the foreground service, never in the guest Flutter
	// engine, so hot restart cannot destroy the peer connection.
	private var directTransport: RhrDirectTransport? = null
	private var preferDirect = false
	// Over-the-wire player update receiver. Created on demand; must live in
	// this service (not the Dart world) because the install kills the process
	// and the transfer must survive guest hot-restarts.
	private var updater: RhrPlayerUpdater? = null
	// Last time we heard from the developer (any dev→device message, or a
	// relay dev_present). Drives the presence lease expiry.
	@Volatile private var lastDevActivity = 0L
	private var presenceWatchThread: Thread? = null
	private var devfsObserver: FileObserver? = null
	@Volatile private var vmUriLock = Object()
	private val assetStoreId: String by lazy {
		val preferences = getSharedPreferences("rhr_native", Context.MODE_PRIVATE)
		preferences.getString("asset_store_id", null) ?: UUID.randomUUID().toString().also {
			preferences.edit().putString("asset_store_id", it).apply()
		}
	}

	override fun onBind(intent: Intent?): IBinder? = null

	override fun onCreate() {
		super.onCreate()
		RhrSessionService.current = this
	}

	override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
		when (intent?.getStringExtra("cmd")) {
			"start" -> {
				val requestedRelay =
					intent.getStringExtra("relayUrl") ?: return START_NOT_STICKY
				val requestedRelays =
					(intent.getStringArrayListExtra("relayUrls") ?: arrayListOf(requestedRelay))
						.filter { it.isNotBlank() }
						.distinct()
						.ifEmpty { listOf(requestedRelay) }
				val requestedCode =
					intent.getStringExtra("code") ?: return START_NOT_STICKY
				val requestedVm =
					intent.getStringExtra("vmUri") ?: return START_NOT_STICKY
				val requestedDirect = intent.getBooleanExtra("preferDirect", false)
				val sameLiveSession = reconnectThread?.isAlive == true &&
					!stopped.get() && sessionCode == requestedCode
				if (sameLiveSession) {
					// Reopening the Activity creates a new FlutterEngine whose
					// Service.getInfo() may report a stale VM URI. The native service
					// survived and still owns the working tunnel, so do not replace its
					// endpoint during same-session auto-resume.
					Log.i(TAG, "[$sessionCode] preserving live VM URI $vmUri")
				} else {
					// Replace the old transport before adopting the new code. The old
					// reconnect thread may still be inside an OkHttp callback; the
					// generation check below makes that thread exit without touching
					// the replacement session's status or sockets.
					sessionGeneration += 1
					stopped.set(true)
					ws?.close(1000, "session replaced")
					directTransport?.close()
					directTransport = null
					reconnectThread?.interrupt()
					stopped.set(false)
					relayUrls = requestedRelays
					sessionCode = requestedCode
					vmUri = requestedVm
					preferDirect = requestedDirect
					currentCode = sessionCode
					currentVm = vmUri
					readySent = false // re-arm sync-ready for a genuinely new session
					stopped.set(false)
					sweepOrphanedDevfsDirs()
					watchForDevfsDirs()
					startVmUriWatch()
					startPresenceWatch()
					startReconnectLoop(sessionGeneration)
				}
				onUpdate?.invoke()
				startForeground(NOTIF_ID, buildNotification())
			}
			"kick" -> synchronized(flowLock) { flowLock.notifyAll() } // also wakes backoff
			"stop" -> {
				stopped.set(true)
				ws?.close(1000, "stopped")
				directTransport?.close()
				directTransport = null
				// Wake the reconnect thread NOW so it sees `stopped` and exits,
				// instead of sleeping up to 20s in its keepalive wait and
				// re-dialing in the meantime (the "still retrying after
				// Disconnect" bug). Interrupt breaks both the wait and backoff.
				reconnectThread?.interrupt()
				vmWatchThread?.interrupt()
				presenceWatchThread?.interrupt()
				status = "idle"
				stopSelf()
			}
		}
		return START_STICKY
	}

	override fun onDestroy() {
		stopped.set(true)
		ws?.close(1000, "service destroyed")
		directTransport?.close()
		directTransport = null
		devfsObserver?.stopWatching()
		if (RhrSessionService.current === this) RhrSessionService.current = null
		super.onDestroy()
	}

	// ---- live VM service URI discovery ------------------------------------
	//
	// The URI handed in at Connect goes stale the instant the guest app hot-
	// restarts: the Dart VM Service is re-created on a NEW port, and being
	// native we can't see it from the engine. So we tail our own process's
	// logcat for the "Dart VM Service ... listening on http://…" line the
	// engine prints on every (re)start, and re-announce the fresh URI to the
	// relay whenever it changes.

	private val vmLineRegex =
		Regex("""Dart VM [Ss]ervice.*?(http://127\.0\.0\.1:\d+/\S+/)""")

	private fun startVmUriWatch() {
		if (vmWatchThread?.isAlive == true) return
		vmWatchThread = Thread {
			val pid = android.os.Process.myPid()
			// First, scan the existing buffer for the most recent VM line — on
			// auto-resume the engine's "listening on" line may already have
			// been printed before this watcher starts (a live -T 1 tail would
			// miss it). Then switch to live tailing for future restarts.
			try {
				val dump = ProcessBuilder("logcat", "--pid=$pid", "-d", "-v", "brief")
					.redirectErrorStream(true).start()
				var latest: String? = null
				dump.inputStream.bufferedReader().forEachLine { line ->
					vmLineRegex.find(line)?.let { latest = it.groupValues[1] }
				}
				latest?.let {
					if (it != vmUri) {
						Log.i(TAG, "VM service URI (from buffer) -> $it")
						vmUri = it
						announceInfo()
					}
				}
			} catch (e: Exception) {
				Log.w(TAG, "vm-uri initial scan error: $e")
			}
			while (!stopped.get()) {
				try {
					// -v brief keeps it parseable; --pid scopes to our engine.
					val proc = ProcessBuilder(
						"logcat", "--pid=$pid", "-v", "brief", "-T", "1")
						.redirectErrorStream(true).start()
					proc.inputStream.bufferedReader().useLines { lines ->
						for (line in lines) {
							if (stopped.get()) break
							val m = vmLineRegex.find(line) ?: continue
							val uri = m.groupValues[1]
							if (uri != vmUri) {
								Log.i(TAG, "VM service URI changed -> $uri")
								vmUri = uri
								announceInfo()
							}
						}
					}
				} catch (e: Exception) {
					Log.w(TAG, "vm-uri watch error: $e")
				}
				if (!stopped.get()) Thread.sleep(1000)
			}
		}.also { it.isDaemon = true; it.start() }
	}

	private fun announceInfo() {
		synchronized(vmUriLock) {
			currentVm = vmUri
			ws?.send(infoMessage())
		}
		// A fresh, real VM URI means the engine finished (re)starting — clear any
		// "restarting"/"reloading" progress the overlay was showing.
		if (!vmUri.contains(":0/") &&
			(progressPhase == "restarting" || progressPhase == "reloading")) {
			setProgress("", 0, 0)
		} else {
			onUpdate?.invoke()
		}
	}

	private fun infoMessage(): String = JSONObject()
		.put("t", "info")
		.put("vm", vmUri)
		.put("transport", activeRelayUrl)
		// Readiness is state, not merely an edge-triggered event. A developer
		// tool can detach and reconnect to the same live VM after the original
		// {"t":"ready"} frame has already been consumed.
		.put("ready", readySent)
		.put("assetStoreId", assetStoreId)
		.put(
			"compatibility",
			JSONObject()
				.put("frameworkVersion", BuildConfig.RHR_FLUTTER_VERSION)
				.put("frameworkRevision", BuildConfig.RHR_FRAMEWORK_REVISION)
				.put("engineRevision", BuildConfig.RHR_ENGINE_REVISION)
				.put("dartSdkVersion", BuildConfig.RHR_DART_SDK_VERSION)
				.put("channel", BuildConfig.RHR_FLUTTER_CHANNEL)
				.put(
					"androidPlugins",
					JSONObject(BuildConfig.RHR_ANDROID_PLUGINS_JSON))
				.put("androidPermissions", androidPermissions()))
		.toString()

	private fun startDirectTransport(webSocket: WebSocket) {
		directTransport?.close()
		directTransport = RhrDirectTransport(
			this,
			sendSignal = { signal -> webSocket.send(signal) },
			onFrame = { frame -> handleFrame(frame) },
			onState = { state ->
				Log.i(TAG, "[$sessionCode] direct transport $state")
				if (state == RhrDirectTransport.State.OPEN) {
					Log.i(TAG, "[$sessionCode] direct WebRTC payload path ready")
				}
			},
		)
		directTransport?.startOffer()
	}

	private fun androidPermissions(): org.json.JSONArray {
		val info = packageManager.getPackageInfo(packageName, PackageManager.GET_PERMISSIONS)
		return org.json.JSONArray(info.requestedPermissions?.sorted() ?: emptyList<String>())
	}

	// ---- relay connection -------------------------------------------------

	private val loopSeq = java.util.concurrent.atomic.AtomicInteger(0)

	private fun startReconnectLoop(generation: Long = sessionGeneration) {
		if (reconnectThread?.isAlive == true && reconnectGeneration == generation) {
			Log.w(TAG, "[$sessionCode] startReconnectLoop SKIPPED — a loop is already alive")
			return
		}
		reconnectGeneration = generation
		val loopId = loopSeq.incrementAndGet()
		Log.i(TAG, "[$sessionCode] STARTING reconnect loop #$loopId")
		reconnectThread = Thread {
			var backoffMs = 1000L
			var candidateIndex = 0
			var failuresThisRound = 0
			while (!stopped.get() && generation == sessionGeneration) {
				val connected = AtomicBoolean(false)
				val closed = Object()
				val relayUrl = relayUrls[candidateIndex % relayUrls.size]
				candidateIndex = (candidateIndex + 1) % relayUrls.size
				val url = "$relayUrl/s/$sessionCode/device"
				Log.i(TAG, "[$sessionCode] loop#$loopId DIALING $url")
				val req = Request.Builder().url(url).build()
				val socket = client.newWebSocket(req, object : WebSocketListener() {
					override fun onOpen(webSocket: WebSocket, response: Response) {
						if (generation != sessionGeneration) return
						connected.set(true)
						activeRelayUrl = relayUrl
						failuresThisRound = 0
						// Assume no developer until we actually hear one — the
						// relay is a dumb pipe, so dev presence is learned from
						// forwarded dev frames, not from the relay.
						status = "waiting_dev"
						Log.i(TAG, "[$sessionCode] connected (http ${response.code})")
						if (!vmUri.contains(":0/")) {
							val sent = webSocket.send(infoMessage())
							Log.i(TAG, "[$sessionCode] SENT info queued=$sent vm=$vmUri")
						} else {
							Log.i(TAG, "[$sessionCode] vm still :0 — not announcing yet")
						}
					}

					override fun onMessage(webSocket: WebSocket, text: String) {
						if (generation != sessionGeneration) return
						Log.i(TAG, "[$sessionCode] RX text: ${text.take(60)}")
						lastDevActivity = System.currentTimeMillis()
						if (text.contains("\"t\":\"direct_") || text.contains("\"t\": \"direct_")) {
							directTransport?.handleSignal(text)
							return
						}
						// Over-the-wire update control messages. The handler is
						// host-provided; without one (plain wrapped app) the
						// frames are ignored and the dev side surfaces the
						// "did not acknowledge" timeout.
						if (text.contains("\"update_begin\"") ||
							text.contains("\"update_commit\"")) {
							try {
								val o = JSONObject(text)
								val u = updater ?: RhrPlayerUpdater(
									this@RhrSessionService,
									sendText = { m ->
										synchronized(vmUriLock) { ws?.send(m) }
									},
									sendBinary = { f -> sendBinaryFrame(f) },
								).also { updater = it }
								when (o.optString("t")) {
									"update_begin" -> u.handleBegin(o)
									"update_commit" -> u.handleCommit(o)
								}
							} catch (e: Exception) {
								Log.w(TAG, "update message failed: $e")
							}
							return
						}
						// The CLI's farewell on clean quit: leave "Connected" and
						// clear progress it owned.
						if (text.contains("\"dev_gone\"")) {
							Log.i(TAG, "[$sessionCode] developer left the session")
							if (status == "connected") status = "waiting_dev"
							setProgress("", 0, 0)
							return
						}
						// Anything else is developer traffic (hello, ping, progress,
						// reload signals) — a live developer is attached.
						if (status != "connected") status = "connected"
						// A dev that connects AFTER us relies on the relay replaying
						// our cached info. If that ever misses (TTL, ordering, a dev
						// that reconnected mid-session), the dev sends {"t":"hello"}
						// and we answer with a fresh info so pairing is robust to
						// connection order. Unknown text (e.g. pings) is ignored.
						if (text.contains("\"hello\"") && !vmUri.contains(":0/")) {
							// Wait for the developer hello before creating the offer. A
							// device can connect to the relay before the CLI subscribes;
							// starting here keeps the first offer and ICE candidates on a
							// live developer stream instead of losing them in the relay.
							if (preferDirect && directTransport == null) {
								startDirectTransport(webSocket)
							}
							announceInfo()
						} else if (text.contains("\"reloading\"")) {
							// The dev detected reload/sync traffic starting → show an
							// indeterminate "Reloading…" bar right away so there's no
							// dead gap. Explicit asset/kernel sync progress is more
							// specific and must not be overwritten by this traffic
							// heuristic while a large upload is in flight.
							if (progressPhase != "assets" && progressPhase != "syncing") {
								setProgress("reloading", 0, 0)
							}
						} else if (text.contains("\"reloaded\"")) {
							// Transfer went quiet → reload done, hide the bar. (A hot
							// reload keeps the same VM URI, so this dev signal is the
							// only reliable "done".)
							if (progressPhase == "reloading") setProgress("", 0, 0)
						} else if (text.contains("\"progress\"")) {
							// The dev reports real transfer/lifecycle progress; the
							// native overlay renders it above the Flutter surface.
							try {
								val o = JSONObject(text)
								setProgress(
									o.optString("phase", ""),
									o.optInt("done", 0),
									o.optInt("total", 0))
							} catch (_: Exception) {}
						}
					}

					override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
						if (generation != sessionGeneration) return
						lastDevActivity = System.currentTimeMillis()
						if (status != "connected") status = "connected"
						handleFrame(bytes.toByteArray())
					}

					override fun onFailure(
						webSocket: WebSocket, t: Throwable, response: Response?) {
						if (generation != sessionGeneration) return
						val code = response?.code
						Log.w(TAG, "[$sessionCode] ONFAILURE ${t.javaClass.simpleName}: " +
							"${t.message} httpResp=$code")
						if (code != null && code != 101) {
							// HTTP-level rejection: unknown code (session not
							// found) or a relay policy block. Stay visible as
							// "Session not found" while the reconnect loop keeps
							// trying in the background — the code becomes valid
							// the moment the real developer starts rhr.
							Log.i(TAG, "[$sessionCode] session rejected (http $code)")
							status = "rejected"
						} else {
							status = "retrying"
						}
						// Transfer progress belongs to this developer connection. If it
						// dies, keeping the last byte count makes a completed guest app
						// look permanently stuck (for example, "Syncing assets 1%").
						setProgress("", 0, 0)
						directTransport?.close()
						directTransport = null
						connected.set(false)
						synchronized(closed) { closed.notifyAll() }
					}

					override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
						if (generation != sessionGeneration) return
						Log.w(TAG, "[$sessionCode] ONCLOSING code=$code reason=\"$reason\"")
					}

					override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
						if (generation != sessionGeneration) return
						Log.w(TAG, "[$sessionCode] ONCLOSED code=$code reason=\"$reason\"")
						status = "closed"
						setProgress("", 0, 0)
						directTransport?.close()
						directTransport = null
						connected.set(false)
						synchronized(closed) { closed.notifyAll() }
					}
				})
				if (generation == sessionGeneration) {
					ws = socket
				} else {
					socket.close(1000, "session replaced")
				}
				// Block this loop until the socket dies (onClosed/onFailure call
				// notifyAll). Plain indefinite wait — do NOT gate on `connected`,
				// which isn't set until the async onOpen fires; gating raced past
				// it and re-dialed every ~1s, and each re-dial made the relay kick
				// the prior connection ("replaced by new connection") — a storm.
				synchronized(closed) {
					try { closed.wait() } catch (_: InterruptedException) {}
				}
				cleanupChannels()
				directTransport?.close()
				directTransport = null
				if (stopped.get() || generation != sessionGeneration) break
				if (connected.get()) {
					backoffMs = 1000L
					failuresThisRound = 0
				} else {
					failuresThisRound++
					// Try the next candidate immediately. Back off only after every
					// LAN/public candidate has failed once.
					if (failuresThisRound < relayUrls.size) continue
					failuresThisRound = 0
					backoffMs = minOf(backoffMs * 2, 30_000L)
				}
				// Sleep on the flow lock so a manual Reconnect ({"cmd":"kick"}
				// → notifyAll) interrupts the backoff instead of making the
				// tester wait up to 30s. Interrupt (stop) breaks it the same.
				synchronized(flowLock) {
					try { flowLock.wait(backoffMs) }
					catch (_: InterruptedException) {}
				}
			}
			// On a deliberate stop the handler already set status = "idle"
			// (which hides the overlay pill). Only mark "stopped" if the loop
			// somehow ended on its own — otherwise the pill would sit on
			// "Connection: stopped…" over the lobby after Disconnect.
			if (generation == sessionGeneration) {
				status = if (stopped.get()) "idle" else "stopped"
			}
		}.also { it.isDaemon = true; it.start() }
	}

	// Watches the developer presence lease and phase stall detection. While
	// `connected`, a dev message must arrive at least every DEV_LEASE_MS (the
	// CLI pings every 20s) or the developer is assumed gone — even when the
	// relay connection is healthy.
	private fun startPresenceWatch() {
		if (presenceWatchThread?.isAlive == true) return
		presenceWatchThread = Thread {
			while (!stopped.get()) {
				try {
					if (status == "connected" &&
						System.currentTimeMillis() - lastDevActivity > DEV_LEASE_MS) {
						Log.i(TAG, "[$sessionCode] developer lease expired — waiting for developer")
						status = "waiting_dev"
						setProgress("", 0, 0)
					}
					// A phase that stays on "restarting"/"awaiting_restart" with
					// no VM change is a stalled restart, not slow progress — the
					// dev is still attached (pings), so presence can't catch it.
					// Flag it honestly instead of leaving the card frozen.
					val setAt = RhrSessionService.Companion.phaseSetAt
					if (setAt != 0L) {
						val budget = if (progressPhase == "reloading") 60_000L else 180_000L
						val stalled = System.currentTimeMillis() - setAt > budget
						if (stalled != phaseStalled) phaseStalled = stalled
					}
				} catch (_: Exception) {}
				try {
					Thread.sleep(5000)
				} catch (_: InterruptedException) {
					break
				}
			}
		}.also { it.isDaemon = true; it.start() }
	}

	// ---- tunnel frames ----------------------------------------------------

	private fun sendBinaryFrame(frame: ByteArray): Boolean {
		val direct = directTransport
		if (direct != null && direct.send(frame)) return true
		return ws?.send(frame.toByteString()) == true
	}

	private fun handleFrame(frame: ByteArray) {
		if (frame.size < 5) return
		val op = frame[0].toInt()
		val channel = ByteBuffer.wrap(frame, 1, 4).int
		when (op) {
			OP_OPEN -> {
				pending[channel] = java.io.ByteArrayOutputStream()
				openChannel(channel)
			}
			OP_DATA -> {
				val sock = sockets[channel]
				if (sock != null) {
					try {
						sock.getOutputStream().write(frame, 5, frame.size - 5)
					} catch (e: Exception) {
						Log.w(TAG, "write failed ch=$channel: $e")
					}
				} else {
					pending[channel]?.write(frame, 5, frame.size - 5)
				}
				sendBinaryFrame(encodeAck(channel, frame.size - 5))
			}
			OP_ACK -> {
				val n = ByteBuffer.wrap(frame, 5, 4).int
				synchronized(flowLock) {
					unacked[channel] = maxOf(0, (unacked[channel] ?: 0) - n)
					flowLock.notifyAll()
				}
			}
			OP_CLOSE -> closeChannel(channel, notifyPeer = false)
			OP_UPDATE_DATA -> updater?.handleData(frame)
		}
	}

	private fun openChannel(channel: Int) {
		Thread {
			try {
				val vm = android.net.Uri.parse(vmUri)
				val sock = Socket()
				sock.connect(InetSocketAddress(vm.host ?: "127.0.0.1", vm.port), 5000)
				// Flush anything that arrived while we were connecting, then
				// atomically switch the channel over to the live socket.
				synchronized(flowLock) {
					val buffered = pending.remove(channel)
					if (buffered == null) {
						// Channel was closed while we were connecting.
						sock.close()
						return@Thread
					}
					if (buffered.size() > 0) {
						sock.getOutputStream().write(buffered.toByteArray())
					}
					sockets[channel] = sock
				}
				val reader = Thread {
					val buf = ByteArray(64 * 1024)
					try {
						val input = sock.getInputStream()
						while (true) {
							val n = input.read(buf)
							if (n < 0) break
							sendBinaryFrame(encodeData(channel, buf, n))
							// Flow control: block while this channel's window is full.
							synchronized(flowLock) {
								unacked[channel] = (unacked[channel] ?: 0) + n
								while ((unacked[channel] ?: 0) >= WINDOW_BYTES &&
									sockets.containsKey(channel) && !stopped.get()) {
									flowLock.wait(1000)
									if ((unacked[channel] ?: 0) < LOW_WATER) break
								}
							}
						}
					} catch (_: Exception) {
					} finally {
						if (sockets.remove(channel) != null) {
							sendBinaryFrame(encodeClose(channel))
						}
						readers.remove(channel)
						synchronized(flowLock) { unacked.remove(channel) }
					}
				}
				readers[channel] = reader
				reader.isDaemon = true
				reader.start()
			} catch (e: Exception) {
				Log.w(TAG, "channel $channel: VM connect failed: $e")
				sendBinaryFrame(encodeClose(channel))
			}
		}.also { it.isDaemon = true }.start()
	}

	private fun closeChannel(channel: Int, notifyPeer: Boolean) {
		pending.remove(channel)
		sockets.remove(channel)?.let { try { it.close() } catch (_: Exception) {} }
		readers.remove(channel)?.interrupt()
		synchronized(flowLock) { unacked.remove(channel); flowLock.notifyAll() }
		if (notifyPeer) sendBinaryFrame(encodeClose(channel))
	}

	private fun cleanupChannels() {
		for (ch in sockets.keys.toList()) closeChannel(ch, notifyPeer = false)
		pending.clear()
	}

	private fun encodeData(channel: Int, buf: ByteArray, n: Int): ByteArray =
		ByteBuffer.allocate(5 + n).put(OP_DATA.toByte()).putInt(channel)
			.put(buf, 0, n).array()

	private fun encodeAck(channel: Int, n: Int): ByteArray =
		ByteBuffer.allocate(9).put(OP_ACK.toByte()).putInt(channel).putInt(n).array()

	private fun encodeClose(channel: Int): ByteArray =
		ByteBuffer.allocate(5).put(OP_CLOSE.toByte()).putInt(channel).array()

	private fun ByteArray.toByteString(): ByteString = toByteString(0, size)

	// ---- persistent asset store (DevFS symlink trick) ---------------------
	//
	// flutter attach creates a fresh random-suffixed DevFS dir per session and
	// never reuses old ones (verified: orphans accumulate, assets re-download
	// every session). We plant build/flutter_assets inside each new DevFS dir
	// as a symlink into a persistent per-project store, so the CLI's asset
	// push lands in permanent storage and later sessions start warm.

	// Debounced "guest kernel ready" signal. When Flutter creates its DevFS dir
	// and syncs the guest kernel, the dev end needs to hot-restart to boot it —
	// but only ONCE the sync has settled. We arm a timer on DevFS activity and
	// fire {"t":"ready"} to the dev after a quiet window so asset sync can finish
	// and the overlay can ask the developer for the initial Hot Restart.
	private val readyHandler = android.os.Handler(android.os.Looper.getMainLooper())
	private var readyRunnable: Runnable? = null
	@Volatile private var readySent = false

	private fun armGuestReady() {
		// Show an indeterminate "Syncing…" bar while DevFS writes are landing —
		// the Cursor/custom-device path uses Flutter's own DevFS sync, so the CLI
		// never sends byte-progress; this is our on-device signal that work is in
		// flight. Cleared when the sync settles (ready).
		if (progressPhase != "syncing") setProgress("syncing", 0, 0)

		readyRunnable?.let { readyHandler.removeCallbacks(it) }
		val r = Runnable {
			setProgress("", 0, 0) // sync settled → hide the bar
			if (readySent) return@Runnable
			readySent = true
			synchronized(vmUriLock) {
				ws?.send(JSONObject().put("t", "ready").toString())
			}
			Log.i(TAG, "guest kernel settled → sent ready")
		}
		readyRunnable = r
		// ~1.5s of quiet after the last DevFS write = sync done.
		readyHandler.postDelayed(r, 1500)
	}

	private fun watchForDevfsDirs() {
		val cache = codeCacheDir
		devfsObserver?.stopWatching()
		devfsObserver = object : FileObserver(cache, CREATE) {
			override fun onEvent(event: Int, path: String?) {
				if (path == null) return
				val project = devfsProjectName(path) ?: return
				armGuestReady() // guest kernel is arriving; debounce → ready
				try {
					// The engine roots DevFS writes under an extra <fsName>/
					// segment (verified: <devfs>/<project>/build/...), so
					// the symlink must sit at <devfs>/<project>/build/flutter_assets.
					val devfsDir = File(cache, path)
					val buildDir = File(devfsDir, "$project/build")
					buildDir.mkdirs()
					val store = File(filesDir, "assets/$project/flutter_assets")
					store.mkdirs()
					val link = File(buildDir, "flutter_assets")
					if (!link.exists()) {
						Os.symlink(store.absolutePath, link.absolutePath)
						projectHint = project
						Log.i(TAG, "planted asset symlink for $project in $path")
					}
				} catch (e: Exception) {
					Log.w(TAG, "symlink plant failed for $path: $e")
				}
			}
		}
		devfsObserver?.startWatching()
	}

	private fun sweepOrphanedDevfsDirs() {
		// Flutter's VM service can still issue _deleteDevFS for a previous
		// directory after the relay session has been replaced. Deleting a fresh
		// directory here races that cleanup and surfaces as PathNotFoundException
		// in `flutter attach`. Keep recent directories available for Flutter's
		// idempotent cleanup; only reclaim genuinely old leftovers.
		val cutoff = System.currentTimeMillis() - 24 * 60 * 60 * 1000L
		codeCacheDir.listFiles()?.forEach { f ->
			if (f.isDirectory && devfsProjectName(f.name) != null &&
				f.lastModified() < cutoff) {
				deleteWithoutFollowingSymlinks(f)
				Log.i(TAG, "swept orphaned DevFS dir ${f.name}")
			}
		}
	}

	/**
	 * deleteRecursively() FOLLOWS directory symlinks — it once walked through
	 * the planted flutter_assets link and wiped the persistent store (490
	 * files, verified the hard way). Delete links as links, never descend.
	 */
	private fun deleteWithoutFollowingSymlinks(f: File) {
		// Os.lstat (API 21+) instead of java.nio.file.Files so the library
		// carries no desugaring requirement for host apps.
		val isLink = try {
			java.nio.file.Files.isSymbolicLink(f.toPath())
		} catch (_: Exception) { false }
		if (!isLink && f.isDirectory) {
			f.listFiles()?.forEach { deleteWithoutFollowingSymlinks(it) }
		}
		f.delete()
	}

	/** DevFS dirs look like `<project><6 UPPERCASE letters>`, e.g. my-appQVGOIA. */
	private fun devfsProjectName(name: String): String? {
		if (name.length <= 6) return null
		val suffix = name.takeLast(6)
		if (!suffix.all { it in 'A'..'Z' }) return null
		val project = name.dropLast(6)
		if (project.startsWith("flutter")) return null // engine's own dirs
		return project
	}

	// ---- notification -----------------------------------------------------

	private fun buildNotification(): Notification {
		val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
		nm.createNotificationChannel(
			NotificationChannel(
				CHANNEL_ID, "rhr session", NotificationManager.IMPORTANCE_LOW))
		return Notification.Builder(this, CHANNEL_ID)
			.setContentTitle("rhr session active")
			.setContentText("Remote hot reload tunnel is running")
			.setSmallIcon(android.R.drawable.stat_sys_download)
			.setOngoing(true)
			.build()
	}
}
