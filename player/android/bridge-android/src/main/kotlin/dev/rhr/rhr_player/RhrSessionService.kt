package dev.rhr.rhr_player

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
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
 *   TEXT frames   = JSON control ({"t":"info","vm":<uri>} announced device->host)
 *   BINARY frames = [1B op][4B channel BE][payload], carried by WebRTC unless
 *                   relay-only mode was explicit; op 0=open 1=data 2=close
 *                   (an open's payload is empty for the VM service, or one
 *                   target byte: 1 device control, 2 native logs)
 *                   3=ack (payload = 4B consumed-byte count, flow control,
 *                   512KB window per channel)
 */
class RhrSessionService : Service() {
	companion object {
		private const val TAG = "rhr_service"
		private const val CHANNEL_ID = "rhr_session"
		private const val NOTIF_ID = 7411
		private const val DIRECT_SIGNAL_VERSION = 1
		/** rhr_native preference: the session code the tester paused. */
		private const val PAUSED_CODE = "paused_session_code"
		/** rhr_native preference: the session code agent control was stopped for. */
		private const val AGENT_STOPPED_CODE = "agent_stopped_session_code"
		// More concurrent VM channels than Flutter's tooling ever opens (a
		// handful, plus DevTools). Each costs a socket and two threads, so a
		// peer that keeps opening them must hit a ceiling.
		private const val MAX_CHANNELS = 64
		// A DevFS request whose head has not ended by now is not one this
		// service rebuilds; it goes to the VM untouched.
		private const val MAX_SNIFFED_HEAD = 64 * 1024
		// Largest RHR upload body held in memory for a rebuild: a gzipped
		// kernel or delta. Bounds what a peer can make this buffer.
		private const val MAX_RHR_UPLOAD = 64 * 1024 * 1024
		// SCTP's negotiated maximum message size, minus this protocol's 5-byte
		// data header. The Dart answer emits no a=max-message-size, so libwebrtc
		// falls back to the 64 KiB default from draft-ietf-mmusic-sdp-sctp-23 —
		// and a message over that limit makes libwebrtc close the data channel
		// itself, reporting success to the caller first. A full 64 KiB read plus
		// the header was five bytes over, which killed the tunnel whenever the
		// phone was busy enough to wake the reader on a full socket buffer.
		private const val TUNNEL_READ_BYTES = 64 * 1024 - 5

		private const val WINDOW_BYTES = 512 * 1024
		private const val LOW_WATER = WINDOW_BYTES / 2

		// Host presence lease: while the CLI is attached it pings every 20s
		// (the dumb relay forwards every host frame to us). If we hear nothing
		// for this long, the host is gone: surface "Waiting for your computer"
		// and clear any progress that belonged to its connection.
		private const val HOST_LEASE_MS = 45_000L

		/**
		 * States the host can go absent FROM. "connected" is the obvious one;
		 * "retrying" matters because a direct-transport failure moves us there
		 * (failDirectSession) while the relay socket is still perfectly alive.
		 * Gating the lease on "connected" alone meant the session that lost its
		 * WebRTC path — the one case where the host is most likely already
		 * gone — was the one case the lease could never reclaim.
		 */
		private val HOST_PRESENT_STATES = setOf("connected", "retrying")

		/**
		 * Set when the host says host_gone, cleared when one arrives again.
		 *
		 * Its departure tears the tunnel down a moment later, and that
		 * teardown used to overwrite "waiting_host" with "retrying", so a user
		 * who quit rhr cleanly was told the phone could not reach the relay.
		 * Same shape as a stop on the phone being undone by the socket close
		 * it caused; this is the host-initiated twin.
		 */
		@Volatile
		var hostLeft: Boolean = false

		// How long the direct tunnel may outlive the host that opened it.
		//
		// Payload rides WebRTC, never the relay, so once a session is up the
		// relay is not in the data path and cannot end it: a relay outage, or a
		// phone that loses its control socket while the peer connection holds,
		// leaves VM access — arbitrary code execution in the app — open with
		// nobody watching. Only this side can close it, so this deadline is the
		// enforcement rather than a backstop.
		//
		// Longer than HOST_LEASE_MS: presence expiring is routine (a laptop
		// sleeps, Wi-Fi moves) and the host usually returns to the same
		// tunnel. This is the outer bound on that patience.
		private const val DIRECT_AUTHORIZATION_MS = 120_000L

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
		// users. Transport faults close live connections; status and phase
		// faults only change the UI state. debugRebuildDelayMs holds each
		// rebuilt DevFS upload back, so a reconnect can land mid-upload.
		@Volatile var debugRebuildDelayMs = 0L

		fun debugInjectFault(name: String) {
			when (name) {
				"slow-devfs-rebuild" -> debugRebuildDelayMs = 60_000
				"clear" -> {
					debugRebuildDelayMs = 0
					setProgress("", 0, 0)
					status = if (current?.reconnectThread?.isAlive == true) "waiting_host" else "idle"
				}
				"relay-loss" -> current?.ws?.close(4001, "fault: relay loss")
				"tunnel-loss" -> current?.let { service ->
					service.sockets.keys.toList().forEach { service.closeChannel(it, notifyPeer = true) }
				}
				"direct-loss" -> current?.let { service ->
					service.ws?.let { service.failDirectSession(it, "fault: direct transport loss") }
				}
				"status-retrying" -> status = "retrying"
				"status-rejected" -> status = "rejected"
				"status-waiting" -> status = "waiting_host"
				"status-connected" -> status = "connected"
				"phase-restarting" -> setProgress("restarting", 0, 0)
				"phase-awaiting-restart" -> setProgress("awaiting_restart", 0, 0)
				"phase-reloading" -> setProgress("reloading", 0, 0)
				// The update phases, which otherwise cost a multi-minute
				// build and a real transfer to see once. Checking the
				// wording on a real screen should not be that expensive —
				// and the bugs these replaced were all wording.
				"phase-outdated" -> setProgress("outdated", 0, 0)
				"phase-building" -> setProgress("building", 0, 0)
				// Mid-transfer, at a number that is not a round one.
				"phase-updating" -> setProgress("updating", 37, 100)
				"phase-installing" -> setProgress("installing", 0, 0)
				"phase-install-confirm" -> setProgress("install_confirm", 0, 0)
				"phase-installed" -> setProgress("installed", 0, 0)
				"phase-update-failed" -> {
					progressMessage = "Gradle: no space left on device"
					setProgress("update_failed", 0, 0)
				}
				"update-foreign" -> {
					updatingForeignApp = true
					updateListeners.forEach { it() }
				}
				"update-player" -> {
					updatingForeignApp = false
					updateListeners.forEach { it() }
				}
				"clear-cache" -> clearAssetCaches()
			}
			Log.i(TAG, "debug fault injected: $name")
		}

		// Latest status, readable by the lobby over the MethodChannel. Setting
		// it also nudges the native overlay to redraw the connection indicator.
		@Volatile var status: String = "idle"
			private set(value) {
				field = value
				updateListeners.forEach { it() }
			}

		/**
		 * Whether the screen should stay on: from the moment a session starts
		 * dialing until it is stopped or paused. The user may be waiting
		 * hands-free on the relay, the computer, a build, or their coding
		 * agent, and a phone that sleeps meanwhile freezes all of it.
		 *
		 * Except a phone on an account waiting on its own rendezvous: nobody
		 * asked it to connect, and it may wait for hours, so it holds the
		 * screen (and the "displaying over other apps" notice that comes with
		 * the hold) only once a computer is connected.
		 */
		val holdsScreen: Boolean
			get() = current?.run {
				sessionCode.isNotEmpty() && !stopped.get() && !paused &&
					(!sessionCode.startsWith(RENDEZVOUS_PREFIX) || status == "connected")
			} == true

		/** Mirrors rhrRendezvousPrefix in bridge/lib/session_code.dart. */
		private const val RENDEZVOUS_PREFIX = "dev-"

		// Latest session code / VM URI, surfaced in the native dev menu so the
		// user can see them even after the guest app has taken the screen.
		@Volatile var currentCode: String = ""
			private set
		@Volatile var usesExternalVm = false
			private set
		@Volatile var currentVm: String = ""
			private set

		// Host-provided factory for over-the-wire APK updates (the player's
		// RhrPlayerUpdater does PackageInstaller self-updates). The factory
		// receives the live socket's send functions; invoked lazily when the
		// CLI starts an update transfer. Null => update frames are
		// ignored (a host that ships no update hook).
		@Volatile var updateHandlerFactory:
			((ctx: Context, sendText: (String) -> Unit, sendBinary: (ByteArray) -> Unit)
				-> RhrUpdateHandler)? = null

		@Volatile var runRequestHandler:
			((Context, JSONObject, (JSONObject) -> Unit, (vm: String, pkg: String) -> Unit, () -> Boolean) -> Unit)? = null

		// Latest transfer/lifecycle progress, pushed by the host over the tunnel
		// ({"t":"progress",...}) or set locally (e.g. "restarting"). The native
		// overlay in MainActivity renders this above the Flutter surface — it
		// must be native because a guest kernel owns the Flutter UI after boot.
		//
		// phase: "" (idle) | "assets" | "syncing" | "awaiting_restart" |
		//        "restarting" | "reloading" | "outdated" | "building" |
		//        "updating" | "update_failed"
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
				updateListeners.forEach { it() }
			}

		// Why the last phase ended, when the computer's side failed. Carried
		// on the progress message so the user reads the actual reason
		// instead of watching a bar sit still.
		@Volatile var progressMessage: String = ""

		// True while the in-flight transfer is the user's OWN app
		// (kind=app) rather than a player self-update, so the overlay can
		// name what is actually being installed.
		@Volatile var updatingForeignApp: Boolean = false

		// What the user is told the foreign install is: their app, or the
		// RHR Agent add-on their coding agent asked for.
		@Volatile var foreignAppName: String = "your app"

		/**
		 * Device control, as the user sees it: only in the session
		 * notification, never on screen, where it would cover the app the
		 * agent is reading. [agentControlling] holds from the agent's first
		 * answer until the host leaves, and is when the notification offers
		 * "Stop agent control". [agentStopped] is the user's choice: it
		 * refuses every request until they allow it again or start another
		 * session, and survives Android restarting the player.
		 */
		@Volatile var agentStopped = false
		@Volatile var agentControlling = false

		/** RHR Agent answered a request: it can see and tap this phone. */
		fun agentActed() {
			if (agentControlling) return
			agentControlling = true
			current?.refreshNotification()
		}

		// When the current progress phase began, used for stall detection.
		@Volatile private var phaseSetAt = 0L
		// MainActivity registers here to be pinged whenever status/progress
		// changes, so the overlay redraws without polling. Called on any thread.
		val updateListeners = java.util.concurrent.CopyOnWriteArraySet<() -> Unit>()

		/**
		 * The install steps, which only this phone can see.
		 *
		 * Everything else on the progress card is relayed from the
		 * CLI on the computer, but the CLI's view ends at the last byte it
		 * sent: it cannot know when PackageInstaller took the APK, or that
		 * Android is holding an install sheet in front of the user. Those
		 * are minutes where the phone would otherwise still be showing a
		 * finished transfer, so the updater reports them locally.
		 */
		fun setInstallPhase(phase: String) = setProgress(phase, 0, 0)

		/** An install that died on this phone, with the reason it died. */
		fun setInstallFailed(message: String) {
			progressMessage = message
			setProgress("update_failed", 0, 0)
		}

		private fun setProgress(phase: String, done: Int, total: Int) {
			phaseStalled = false
			progressPhase = phase
			progressDone = done
			progressTotal = total
			if (phase.isEmpty()) {
				phaseSetAt = 0L
			} else {
				phaseSetAt = System.currentTimeMillis()
			}
			updateListeners.forEach { it() }
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
	// Certificate pin for relays addressed by IP (the developer's LAN relay),
	// from the session link. See RelayDial.client.
	private var relayPin: String? = null
	@Volatile private var activeRelayUrl = ""
	private var sessionCode = ""
	// The code is a bearer token for this phone; logs carry only its prefix.
	private val logTag get() = LogRedaction.session(sessionCode)
	private var vmUri = ""
	// Connector mode: the vmUri was handed to us (target app's door) —
	// never override it from our own process log.
	@Volatile private var watchOwnVm = true
		set(value) {
			field = value
			usesExternalVm = !value
			updateListeners.forEach { it() }
		}
	@Volatile private var ownVmUri = ""
	// The connected app whose VM the tunnel reaches, or null for the player's
	// own engine. Native logs come from this app's beacon.
	@Volatile private var connectedPackage: String? = null
	private var projectHint: String? = null
	private val sockets = ConcurrentHashMap<Int, ChannelEnd>()
	private val readers = ConcurrentHashMap<Int, Thread>()
	// Invariant: data frames can race the channel's TCP connect —
	// buffer them until the socket is ready, never drop them.
	private val pending = ConcurrentHashMap<Int, java.io.ByteArrayOutputStream>()
	// Channels whose first request is still undecided: an RHR DevFS upload
	// (rebuilt here from a delta, see DevFsDelta) or anything else, which is
	// passed through untouched.
	private val sniffers = ConcurrentHashMap<Int, DevFsDelta.Sniffer>()
	// Per-channel unacked byte counts; readers block on the lock when full.
	private val unacked = ConcurrentHashMap<Int, Int>()
	private val flowLock = Object()
	// Bumped under flowLock whenever the channel table resets. Channel numbers
	// restart at 1 for every host connection, so work that outlives one
	// (a DevFS rebuild) must not write into a new connection's channel of the
	// same number.
	@Volatile private var channelEpoch = 0L
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
	@Volatile private var directFailureReported = false
	// Over-the-wire APK-update receiver, provided by the HOST app (the
	// player installs its own replacement; other hosts may ship none).
	// Created on demand; must live in this service (not the Dart world)
	// because the install kills the process and the transfer must survive
	// guest hot-restarts.
	private var updater: RhrUpdateHandler? = null
	// Last time we heard from the host (any host→device message). Drives the
	// presence lease expiry.
	@Volatile private var lastHostActivity = 0L

	/**
	 * True while the user has made this phone unavailable.
	 *
	 * Enforced here, not only at the relay: the relay refuses new claims, but
	 * a host already on the direct path is not routed through it, and a
	 * pause sent while the socket was down never reached it at all. So while
	 * this is set nothing from a host is acted on, no tunnel is opened,
	 * and every reconnect tells the relay again.
	 *
	 * Remembered per session code, because every reconnect also tells the
	 * relay when the phone is NOT paused (a resume can be lost the same way).
	 * Forgotten in memory, a player restarted by Android would announce a
	 * resume the user never gave.
	 */
	@Volatile private var paused = false
		set(value) {
			field = value
			val preferences = getSharedPreferences("rhr_native", Context.MODE_PRIVATE)
			if (value) preferences.edit().putString(PAUSED_CODE, sessionCode).apply()
			else preferences.edit().remove(PAUSED_CODE).apply()
		}

	private fun pausedEarlier(code: String): Boolean =
		getSharedPreferences("rhr_native", Context.MODE_PRIVATE)
			.getString(PAUSED_CODE, null) == code

	/**
	 * Sets [agentStopped] and remembers it per session code, like [paused]:
	 * Android restarting the player resumes the same session, and must not
	 * hand device control back to a host the user stopped.
	 */
	private fun setAgentStopped(value: Boolean) {
		agentStopped = value
		val preferences = getSharedPreferences("rhr_native", Context.MODE_PRIVATE)
		if (value) preferences.edit().putString(AGENT_STOPPED_CODE, sessionCode).apply()
		else preferences.edit().remove(AGENT_STOPPED_CODE).apply()
	}

	private fun agentStoppedEarlier(code: String): Boolean =
		getSharedPreferences("rhr_native", Context.MODE_PRIVATE)
			.getString(AGENT_STOPPED_CODE, null) == code

	/** Tells the relay whether developers may claim this phone. */
	private fun availabilityMessage(): String =
		JSONObject().put("t", if (paused) "pause" else "resume").toString()

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
		updateListeners.add(refreshScreenHold)
		if (android.os.Build.VERSION.SDK_INT >= 24) {
			getSystemService(android.net.ConnectivityManager::class.java)
				?.registerDefaultNetworkCallback(networkCallback)
		}
	}

	// The phone's default network. Sockets are bound to the network they were
	// opened on, so when it changes (Wi-Fi to cellular and back) the relay
	// socket and the direct path are dead even before they notice: OkHttp's
	// ping and ICE consent take up to ~30 s to say so. Acting on the change
	// itself makes a handover a reconnect, not an outage.
	@Volatile private var defaultNetwork: android.net.Network? = null

	private val networkCallback = object : android.net.ConnectivityManager.NetworkCallback() {
		override fun onAvailable(network: android.net.Network) {
			val previous = defaultNetwork
			defaultNetwork = network
			if (previous != null && previous != network && !stopped.get()) {
				Log.i(TAG, "[$logTag] default network changed; reconnecting now")
				ws?.cancel()
			}
			// Back from no network at all: cut short a backoff of up to 30 s.
			synchronized(flowLock) { flowLock.notifyAll() }
		}

		override fun onLost(network: android.net.Network) {
			if (network != defaultNetwork) return
			defaultNetwork = null
			// Its sockets are dead. Failing the relay socket now lets the loop
			// redial the moment another network is up, instead of after a ping
			// timeout on the old one.
			if (!stopped.get()) ws?.cancel()
		}
	}

	override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
		when (intent?.getStringExtra("cmd")) {
			"start" -> {
				val requestedRelay =
					intent.getStringExtra("relayUrl") ?: return START_NOT_STICKY
				// A plaintext relay off loopback would hand the session code,
				// and with it this app's VM service, to the network. Links are
				// checked before they get here; this holds for every caller.
				val requestedRelays =
					(intent.getStringArrayListExtra("relayUrls") ?: arrayListOf(requestedRelay))
						.filter { it.isNotBlank() }
						.distinct()
						.ifEmpty { listOf(requestedRelay) }
						.filter(RelayDial::allowed)
				if (requestedRelays.isEmpty()) {
					Log.w(TAG, "refusing a session with no TLS relay")
					return START_NOT_STICKY
				}
				val requestedPin = intent.getStringExtra("relayPin")
				val requestedCode =
					intent.getStringExtra("code") ?: return START_NOT_STICKY
				val requestedVm =
					intent.getStringExtra("vmUri") ?: return START_NOT_STICKY
				// watchVm=false: the vmUri IS the door (connector mode — the
				// target app is a different process, so our own logcat can
				// never see its engine lines). Default true: the player
				// hosts its own engine and tracks guest kernel swaps.
				val requestedOwnVm = intent.getBooleanExtra("watchVm", true)
				if (requestedOwnVm) ownVmUri = requestedVm
				val requestedDirect = intent.getBooleanExtra("preferDirect", true)
				val sameLiveSession = reconnectThread?.isAlive == true &&
					!stopped.get() && sessionCode == requestedCode &&
					// Connector mode: the vmUri is FRESHLY discovered from
					// the target app on every connectTarget call. If it
					// moved, the target restarted and the preserved door is
					// a corpse (verified: every later session then dialed
					// the dead port, and reloads silently landed on the
					// wrong app). The player's auto-resume is unchanged —
					// its own engine reports a stale URI on Activity
					// recreate, where the live service knows better.
					(requestedOwnVm || requestedVm == vmUri)
				if (sameLiveSession) {
					// Reopening the Activity creates a new FlutterEngine whose
					// Service.getInfo() may report a stale VM URI. The native service
					// survived and still owns the working tunnel, so do not replace its
					// endpoint during same-session auto-resume.
					Log.i(TAG, "[$logTag] preserving live VM URI ${LogRedaction.vmUri(vmUri)}")
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
					relayPin = requestedPin
					sessionCode = requestedCode
					watchOwnVm = requestedOwnVm
					vmUri = requestedVm
					preferDirect = requestedDirect
					currentCode = sessionCode
					currentVm = vmUri
					readySent = false // re-arm sync-ready for a genuinely new session
					stopped.set(false)
					// A new session starts with no host having left it; a
					// stale flag here would suppress a real reconnect notice.
					hostLeft = false
					// "Stop agent control" lasts until the user allows it again
					// or connects to another session; the same code coming
					// back after Android restarted the player stays stopped.
					agentStopped = agentStoppedEarlier(requestedCode)
					agentControlling = false
					// A pause stays with its session code until the user
					// resumes or disconnects: the same code coming back after
					// Android restarted the player is still paused.
					paused = pausedEarlier(requestedCode)
					if (paused) status = "paused"
					sweepOrphanedDevfsDirs()
					if (watchOwnVm) watchForDevfsDirs()
					// The VM watcher tracks OUR own service URI across guest hot
					// restarts; the presence watcher tracks the host and
					// enforces the tunnel deadline. Different jobs, and hosted
					// mode needs both — it used to run only the first, so a
					// hosted session's tunnel outlived its host unchecked.
					if (watchOwnVm) startVmUriWatch()
					startPresenceWatch()
					startReconnectLoop(sessionGeneration)
				}
				updateListeners.forEach { it() }
				startForeground(NOTIF_ID, buildNotification())
			}
			"kick" -> synchronized(flowLock) { flowLock.notifyAll() } // also wakes backoff
			// The user making the phone unavailable without ending the session:
			// the code stays, the relay refuses new claims, and the host that
			// was connected is dropped. Stop alone would hand the phone straight
			// to whoever asked next.
			"pause" -> {
				paused = true
				// If the socket is down this is lost, and onOpen says it again.
				ws?.send(availabilityMessage())
				// Drop the developer who was here, on every path they had in:
				// the direct peer, the VM channels it or the relay carried, and
				// any APK transfer or install prompt still open.
				directTransport?.close()
				directTransport = null
				cleanupChannels()
				updater?.cancel("this phone was paused")
				// The progress was theirs, and a phase outranks the status on
				// the banner, so leaving it would hide "Paused".
				setProgress("", 0, 0)
				updatingForeignApp = false
				status = "paused"
			}
			"resume" -> {
				paused = false
				// Lost if the socket is down; onOpen says it again.
				val told = ws?.send(availabilityMessage()) == true
				status = if (told) "waiting_host" else "retrying"
				updateListeners.forEach { it() }
			}
			// The user asking for their app back in its opening state. Only
			// the host can do this — a hot restart is Flutter's, driven from
			// the computer — so this asks rather than acts, and the menu only
			// offers it while a host is attached to ask.
			"restart_guest" -> {
				if (status == "connected" && progressPhase != "restarting" && progressPhase != "reloading") {
					setProgress("restarting", 0, 0)
					if (ws?.send(JSONObject().put("t", "restart_guest").toString()) != true) {
						setProgress("reload_failed", 0, 0)
					}
				}
			}
			"stop_agent" -> {
				setAgentStopped(true)
				refreshNotification()
			}
			"allow_agent" -> {
				setAgentStopped(false)
				refreshNotification()
			}
			"stop" -> {
				stopped.set(true)
				paused = false
				setAgentStopped(false)
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
				// A stop during an update left the phase behind, and the
				// phase outranks the status on both surfaces — so the card
				// kept showing a transfer for a session that no longer
				// existed. Nothing is in flight after this.
				setProgress("", 0, 0)
				updatingForeignApp = false
				status = "idle"
				stopSelf()
			}
		}
		return START_STICKY
	}

	override fun onDestroy() {
		if (android.os.Build.VERSION.SDK_INT >= 24) {
			try {
				getSystemService(android.net.ConnectivityManager::class.java)
					?.unregisterNetworkCallback(networkCallback)
			} catch (_: IllegalArgumentException) {
				// Never registered.
			}
		}
		stopped.set(true)
		ws?.close(1000, "service destroyed")
		directTransport?.close()
		directTransport = null
		devfsObserver?.stopWatching()
		updateListeners.remove(refreshScreenHold)
		main.removeCallbacksAndMessages(null)
		holdScreen(false)
		if (RhrSessionService.current === this) RhrSessionService.current = null
		super.onDestroy()
	}

	private val main = android.os.Handler(android.os.Looper.getMainLooper())
	private val refreshScreenHold: () -> Unit = {
		main.post { if (RhrSessionService.current === this) holdScreen(holdsScreen) }
	}
	private var screenHold: android.view.View? = null

	/**
	 * Keeps the display from timing out while [holdsScreen], whatever the
	 * session is doing: connecting, building, installing, or running.
	 *
	 * The user may be looking at the player or at a separate debug app, and
	 * the player cannot set FLAG_KEEP_SCREEN_ON on another app's window. It
	 * can set it on a window of its own above everything: the flag holds the
	 * screen for as long as any visible window carries it. So this is a 1×1,
	 * fully transparent, untouchable overlay whose only job is the flag.
	 * Fully transparent also exempts it from Android 12's untrusted-touch
	 * blocking.
	 *
	 * It needs the "display over other apps" permission. Without it the
	 * player's own Activity still sets the flag while it is on screen. The
	 * power button still turns the screen off; only the idle timeout is
	 * suppressed.
	 */
	private fun holdScreen(hold: Boolean) {
		val wm = getSystemService(WINDOW_SERVICE) as android.view.WindowManager
		val current = screenHold
		// TYPE_APPLICATION_OVERLAY is API 26; older phones rely on the Activity.
		if (!hold || android.os.Build.VERSION.SDK_INT < 26 ||
			!android.provider.Settings.canDrawOverlays(this)
		) {
			if (current != null) runCatching { wm.removeView(current) }
			screenHold = null
			return
		}
		if (current != null) return
		val view = android.view.View(this)
		val params = android.view.WindowManager.LayoutParams(
			1,
			1,
			android.view.WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
			android.view.WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
				android.view.WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
				android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
			android.graphics.PixelFormat.TRANSLUCENT,
		).apply { alpha = 0f }
		runCatching { wm.addView(view, params) }
			.onSuccess { screenHold = view }
			.onFailure { Log.w(TAG, "screen hold rejected", it) }
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
					ownVmUri = it
					if (watchOwnVm && it != vmUri) {
						Log.i(TAG, "VM service URI (from buffer) -> ${LogRedaction.vmUri(it)}")
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
							ownVmUri = uri
							if (watchOwnVm && uri != vmUri) {
								Log.i(TAG, "VM service URI changed -> ${LogRedaction.vmUri(uri)}")
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

	/**
	 * Points the tunnel back at the player's own engine. A target app belongs
	 * to the run that launched it: once that host is gone the app may be
	 * too (closed, crashed, uninstalled), and announcing its address would
	 * hand the next host a dead VM. Its run launches it again.
	 *
	 * Announced at once: the relay replays the last info to a host that
	 * connects, before this side hears its hello.
	 */
	private fun resumeOwnVm() {
		synchronized(vmUriLock) {
			if (watchOwnVm) return
			watchOwnVm = true
			connectedPackage = null
			vmUri = ownVmUri
			currentVm = vmUri
		}
		announceInfo()
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
			updateListeners.forEach { it() }
		}
	}

	private val ownCertificate: String by lazy {
		try {
			val signers = if (android.os.Build.VERSION.SDK_INT >= 28) {
				packageManager.getPackageInfo(packageName, android.content.pm.PackageManager.GET_SIGNING_CERTIFICATES)
					.signingInfo?.apkContentsSigners
			} else {
				@Suppress("DEPRECATION")
				packageManager.getPackageInfo(packageName, android.content.pm.PackageManager.GET_SIGNATURES).signatures
			}
			val signer = signers?.singleOrNull() ?: return@lazy ""
			java.security.MessageDigest.getInstance("SHA-256").digest(signer.toByteArray())
				.joinToString("") { "%02x".format(it) }
		} catch (_: Exception) {
			""
		}
	}

	private fun infoMessage(): String = JSONObject()
		.put("t", "info")
		.put("deviceName", android.os.Build.MODEL)
		.put("deviceId", InstallationIdentity.id(this))
		.put("vm", vmUri)
		// The host hello this answers. The relay replays the last info to
		// every host that connects, and an attaching one waits for its own.
		.put("answers", hostConnectionId ?: JSONObject.NULL)
		.put("transport", activeRelayUrl)
		// Readiness is state, not merely an edge-triggered event. A host
		// tool can detach and reconnect to the same live VM after the original
		// {"t":"ready"} frame has already been consumed.
		.put("ready", readySent)
		.put("assetStoreId", assetStoreId)
		// This host rebuilds DevFS uploads the CLI sends as deltas; the
		// pure-Dart desktop bridge does not.
		.put("devfsDelta", 1)
		// A beacon-built app trusts exactly this package and signing
		// certificate with its VM address.
		.put("playerPackage", packageName)
		.put("playerCertificate", ownCertificate)
		// "player" | "connector", which is how the host side decides whether to
		// run the compatibility gate and offer a player update.
		//
		// Connector mode is the exception: we are tunneling a THIRD-party
		// app's VM service, so the identity in this hello describes US, not
		// the target. Announcing "player" there would gate the host
		// against the wrong app's Flutter version — and offer it a player
		// update that could not fix it. `watchOwnVm` is false exactly when
		// the vmUri belongs to someone else, so it is the honest signal.
		.put("host", if (watchOwnVm) RhrConfig.hostKind(this) else "connector")
		.put(
			"compatibility",
			JSONObject()
				.put("frameworkVersion", RhrConfig.flutterVersion(this))
				.put("frameworkRevision", RhrConfig.frameworkRevision(this))
				.put("engineRevision", RhrConfig.engineRevision(this))
				.put("dartSdkVersion", RhrConfig.dartSdkVersion(this))
				.put("channel", RhrConfig.channel(this))
				.put(
					"androidPlugins",
					JSONObject(RhrConfig.androidPluginsJson(this).ifBlank { "{}" }))
				.put("androidPermissions", androidPermissions()))
		.toString()

	private var hostConnectionId: String? = null

	private fun startDirectTransport(webSocket: WebSocket) {
		// A paused phone opens no tunnel, whoever asks.
		if (paused) return
		directTransport?.close()
		directTransport = RhrDirectTransport(
			this,
			sendSignal = { signal -> webSocket.send(signal) },
			onFrame = { frame -> handleFrame(frame) },
			onState = { state ->
				Log.i(TAG, "[$logTag] direct transport $state")
				if (state == RhrDirectTransport.State.OPEN) {
					Log.i(TAG, "[$logTag] direct WebRTC payload path ready")
				}
			},
			onFailure = { reason ->
				failDirectSession(webSocket, reason)
				// Every channel's payload rode this transport, so they are
				// dead with it. Close them now rather than at the next hello:
				// their VM sockets otherwise stay open with nothing reading.
				cleanupChannels()
			},
		)
		directTransport?.startOffer()
	}

	private fun failDirectSession(
		webSocket: WebSocket,
		reason: String,
		notifyPeer: Boolean = true,
	) {
		if (!preferDirect || directFailureReported) return
		directFailureReported = true
		Log.w(TAG, "[$logTag] direct WebRTC session failed: $reason")
		// Same reason as the socket failure above: a teardown the user asked
		// for must not report itself as a connection problem. Nor one the
		// host caused by leaving — its host_gone arrives seconds before
		// the ICE teardown it sets off.
		if (!stopped.get() && !hostLeft && !paused) status = "retrying"
		if (notifyPeer) {
			webSocket.send(
				JSONObject()
					.put("v", DIRECT_SIGNAL_VERSION)
					.put("t", "direct_error")
					.put("message", reason)
					.toString())
		}
		// Keep signaling alive so the next host hello can replace the peer
		// without waiting for a WebSocket close handshake and relay backoff.
	}

	private fun androidPermissions(): org.json.JSONArray {
		val info = packageManager.getPackageInfo(packageName, PackageManager.GET_PERMISSIONS)
		return org.json.JSONArray(info.requestedPermissions?.sorted() ?: emptyList<String>())
	}

	// ---- relay connection -------------------------------------------------

	private val loopSeq = java.util.concurrent.atomic.AtomicInteger(0)

	private fun startReconnectLoop(generation: Long = sessionGeneration) {
		if (reconnectThread?.isAlive == true && reconnectGeneration == generation) {
			Log.w(TAG, "[$logTag] startReconnectLoop SKIPPED — a loop is already alive")
			return
		}
		reconnectGeneration = generation
		val loopId = loopSeq.incrementAndGet()
		Log.i(TAG, "[$logTag] STARTING reconnect loop #$loopId")
		reconnectThread = Thread {
			var backoffMs = 1000L
			var candidateIndex = 0
			var failuresThisRound = 0
			while (!stopped.get() && generation == sessionGeneration) {
				val wasConnected = AtomicBoolean(false)
				val closed = Object()
				val relayUrl = relayUrls[candidateIndex % relayUrls.size]
				candidateIndex = (candidateIndex + 1) % relayUrls.size
				Log.i(TAG, "[$logTag] loop#$loopId DIALING $relayUrl")
				val req = RelayDial.request(this, relayUrl, sessionCode)
				val socket = RelayDial.client(client, relayUrl, relayPin)
					.newWebSocket(req, object : WebSocketListener() {
					override fun onOpen(webSocket: WebSocket, response: Response) {
						if (generation != sessionGeneration) return
						wasConnected.set(true)
						directFailureReported = false
						activeRelayUrl = relayUrl
						failuresThisRound = 0
						// Assume no host until we actually hear one — the
						// relay is a dumb pipe, so host presence is learned from
						// forwarded host frames, not from the relay.
						status = if (paused) "paused" else "waiting_host"
						Log.i(TAG, "[$logTag] connected (http ${response.code})")
						// The relay keeps the pause, but one sent while the
						// socket was down never reached it, and neither did a
						// resume. Say which it is on every connection.
						webSocket.send(availabilityMessage())
						if (runRequestHandler != null || !vmUri.contains(":0/")) {
							val sent = webSocket.send(infoMessage())
							Log.i(TAG, "[$logTag] SENT info queued=$sent vm=${LogRedaction.vmUri(vmUri)}")
						} else {
							Log.i(TAG, "[$logTag] vm still :0 — not announcing yet")
						}
					}

					override fun onMessage(webSocket: WebSocket, text: String) {
						if (generation != sessionGeneration) return
						Log.i(TAG, "[$logTag] RX text: ${text.take(60)}")
						// Paused: a host still reaching this socket (one the
						// relay admitted before the pause landed) gets nothing.
						// OkHttp answers the relay's pings below this level, so
						// dropping every message keeps the socket alive.
						if (paused) return
						lastHostActivity = System.currentTimeMillis()
						if (text.contains("\"t\":\"direct_") || text.contains("\"t\": \"direct_")) {
							val directMessage = try { JSONObject(text) } catch (_: Exception) { null }
							if (directMessage?.optString("t") == "direct_error") {
								failDirectSession(
									webSocket,
									directMessage.optString("message", "host direct transport failed"),
									notifyPeer = false)
								return
							}
							directTransport?.handleSignal(text)
							return
						}
						val runRequest = try { JSONObject(text) } catch (_: Exception) { null }
						if (runRequest?.optString("t") == "run_request") {
							hostLeft = false
							if (runRequest.optString("action") == "host_player") {
								val available = ownVmUri.isNotEmpty() && !ownVmUri.contains(":0/")
								if (available) synchronized(vmUriLock) {
									watchOwnVm = true
									connectedPackage = null
									vmUri = ownVmUri
									currentVm = vmUri
								}
								webSocket.send(JSONObject().put("t", "run_response")
									.put("id", runRequest.optInt("id")).put("ok", true)
									.put("ready", available).put("vm", ownVmUri).toString())
								return
							}

							runRequestHandler?.invoke(this@RhrSessionService, runRequest,
								{ response -> if (generation == sessionGeneration) webSocket.send(response.toString()) },
								{ targetVm, targetPackage ->
									if (generation == sessionGeneration) {
										synchronized(vmUriLock) {
											watchOwnVm = false
											connectedPackage = targetPackage
											vmUri = targetVm
											currentVm = targetVm
										}
										announceInfo()
									}
								}, { generation == sessionGeneration && !stopped.get() && !hostLeft && !paused })
							return
						}
						// Over-the-wire update control messages. The handler is
						// host-provided; without one the frames are
						// ignored and the CLI surfaces the
						// "did not acknowledge" timeout.
						if (text.contains("\"update_begin\"") ||
							text.contains("\"update_commit\"")) {
							try {
								val o = JSONObject(text)
								val factory = updateHandlerFactory
								val u = updater ?: factory?.invoke(
									this@RhrSessionService,
									{ m ->
										synchronized(vmUriLock) { ws?.send(m) }
									},
									{ f -> sendBinaryFrame(f) },
								)?.also { updater = it }
								when (o.optString("t")) {
									"update_begin" -> u?.handleBegin(o)
									"update_commit" -> u?.handleCommit(o)
								}
							} catch (e: Exception) {
								Log.w(TAG, "update message failed: $e")
							}
							return
						}
						// The CLI's farewell on clean quit: leave "Connected" and
						// clear progress it owned. Honoured from "retrying" too —
						// a host whose direct tunnel died still says goodbye over
						// the relay, and that is the case where the user is
						// otherwise left reading a connection error.
						if (text.contains("\"host_gone\"")) {
							Log.i(TAG, "[$logTag] host left the session")
							hostLeft = true
							if (status in HOST_PRESENT_STATES) status = "waiting_host"
							// Failures, and a run waiting on the user's approval,
							// stay up: they tell the user why nothing is happening.
							if (progressPhase !in setOf("preparation_failed", "update_failed", "approval_needed", "native_changed")) {
								setProgress("", 0, 0)
							}
							// The peer belonged to the host that just left; it
							// can only decay to ICE failed from here, and while it
							// exists the next host's hello does not start a
							// fresh offer (that hello then waits on a corpse and
							// inherits its failure). Drop it now.
							directTransport?.close()
							directTransport = null
							directFailureReported = false
							resumeOwnVm()
							// The coding agent left with it.
							if (agentControlling) {
								agentControlling = false
								refreshNotification()
							}
							return
						}
						// Anything else is host traffic (hello, ping, progress,
						// reload signals) — a live host is attached.
						hostLeft = false
						if (status != "connected") status = "connected"
						// A host that connects AFTER us relies on the relay replaying
						// our cached info. If that ever misses (TTL, ordering, a host
						// that reconnected mid-session), the host sends {"t":"hello"}
						// and we answer with a fresh info so pairing is robust to
						// connection order. Unknown text (e.g. pings) is ignored.
						// Abrupt CLI exits do not send host_gone. A new attempt numbers its
						// channels from 1 again, owns a new peer, and is owed an info
						// addressed to it, whichever transport carries its payload.
						val hello = text.contains("\"hello\"")
						val newConnection = hello && runRequest?.optString("connectionId") != hostConnectionId
						if (newConnection) {
							hostConnectionId = runRequest?.optString("connectionId")
							cleanupChannels()
							resumeOwnVm()
						}
						if (hello && (runRequestHandler != null || !vmUri.contains(":0/"))) {
							// Wait for the host hello before creating the offer. A
							// device can connect to the relay before the CLI subscribes;
							// starting here keeps the first offer and ICE candidates on a
							// live host stream instead of losing them in the relay.
							if (preferDirect && (newConnection || directFailureReported || directTransport == null)) {
								directFailureReported = false
								if (!newConnection) cleanupChannels()
								startDirectTransport(webSocket)
							}
							announceInfo()
						} else if (text.contains("\"reloading\"")) {
							// The host detected reload/sync traffic starting → show an
							// indeterminate "Reloading…" bar right away so there's no
							// dead gap. Explicit asset/kernel sync progress is more
							// specific and must not be overwritten by this traffic
							// heuristic while a large upload is in flight.
							if (progressPhase != "assets" && progressPhase != "syncing") {
								setProgress("reloading", 0, 0)
							}
						} else if (text.contains("\"reloaded\"")) {
							// Transfer went quiet → reload done, hide the bar. (A hot
							// reload keeps the same VM URI, so this host signal is the
							// only reliable "done".)
							if (progressPhase == "reloading") setProgress("", 0, 0)
						} else if (text.contains("\"progress\"")) {
							// The host reports real transfer/lifecycle progress; the
							// native overlay renders it above the Flutter surface.
							try {
								val o = JSONObject(text)
								progressMessage = o.optString("message", "")
								setProgress(
									o.optString("phase", ""),
									o.optInt("done", 0),
									o.optInt("total", 0))
							} catch (_: Exception) {}
						}
					}

					override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
						if (generation != sessionGeneration) return
						if (paused) return
						if (preferDirect) {
							failDirectSession(
								webSocket,
								"relay sent binary payload in direct-only mode")
							return
						}
						lastHostActivity = System.currentTimeMillis()
						if (status != "connected") status = "connected"
						handleFrame(bytes.toByteArray())
					}

					override fun onFailure(
						webSocket: WebSocket, t: Throwable, response: Response?) {
						if (generation != sessionGeneration) return
						val code = response?.code
						Log.w(TAG, "[$logTag] ONFAILURE ${t.javaClass.simpleName}: " +
							"${t.message} httpResp=$code")
						if (paused) {
							// Stays "paused": that is what the tester chose, and
							// the loop re-sends it to the relay on reconnect.
						} else if (code != null && code != 101) {
							// HTTP-level rejection: unknown code (session not
							// found) or a relay policy block. Stay visible as
							// "Session not found" while the reconnect loop keeps
							// trying in the background — the code becomes valid
							// the moment you start rhr on the computer.
							Log.i(TAG, "[$logTag] session rejected (http $code)")
							status = "rejected"
						} else if (!stopped.get() && !hostLeft) {
							// Disconnect closes this socket itself, so the
							// failure it raises arrives on a callback thread
							// AFTER the stop set "idle" — and overwrote it with
							// "retrying". The lobby then said disconnected while
							// the overlay said it was still trying, and nothing
							// was trying at all. A host that said host_gone
							// leaves the same way, from the other end.
							status = "retrying"
						}
						// Transfer progress belongs to this host connection. If it
						// dies, keeping the last byte count makes a completed guest app
						// look permanently stuck (for example, "Syncing assets 1%").
						setProgress("", 0, 0)
						directTransport?.close()
						directTransport = null
						synchronized(closed) { closed.notifyAll() }
					}

					override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
						if (generation != sessionGeneration) return
						Log.w(TAG, "[$logTag] ONCLOSING code=$code reason=\"$reason\"")
					}

					override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
						if (generation != sessionGeneration) return
						Log.w(TAG, "[$logTag] ONCLOSED code=$code reason=\"$reason\"")
						// A close the user asked for is not a lost connection,
						// and a paused phone stays paused through the reconnect.
						if (!stopped.get() && !paused) status = "closed"
						setProgress("", 0, 0)
						directTransport?.close()
						directTransport = null
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
				if (wasConnected.get()) {
					backoffMs = 1000L
					failuresThisRound = 0
					continue
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
				// user wait up to 30s. Interrupt (stop) breaks it the same.
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

	// Watches the host presence lease and phase stall detection. While
	// `connected`, a host message must arrive at least every HOST_LEASE_MS (the
	// CLI pings every 20s) or the host is assumed gone — even when the
	// relay connection is healthy.
	private fun startPresenceWatch() {
		if (presenceWatchThread?.isAlive == true) return
		presenceWatchThread = Thread {
			while (!stopped.get()) {
				try {
					val sinceHost = System.currentTimeMillis() - lastHostActivity
					if (status in HOST_PRESENT_STATES && sinceHost > HOST_LEASE_MS) {
						Log.i(TAG, "[$logTag] host lease expired — waiting for host")
						status = "waiting_host"
						setProgress("", 0, 0)
					}
					// Presence expiring only changes what the screen says; the
					// tunnel itself stays open so a user who steps away can
					// pick up where they left off. Past this outer deadline that
					// patience becomes a hole: nobody is watching, and the relay
					// cannot close a WebRTC channel it was never part of.
					if (directTransport != null && sinceHost > DIRECT_AUTHORIZATION_MS) {
						Log.w(
							TAG,
							"[$logTag] no host for ${sinceHost / 1000}s — " +
								"closing the direct tunnel",
						)
						closeDirectForExpiry()
					}
					// A phase that stays on "restarting"/"awaiting_restart" with
					// no VM change is a stalled restart, not slow progress — the
					// host is still attached (pings), so presence can't catch it.
					// Flag it honestly instead of leaving the card frozen.
					val setAt = RhrSessionService.Companion.phaseSetAt
					if (setAt != 0L) {
						// A build is minutes of honest work, not a stall: a
						// cold player build measured over 4 minutes. Anything
						// shorter flags every normal update as stuck.
						val budget = when (progressPhase) {
							"reloading" -> 60_000L
							"building" -> 900_000L
							// Both wait on a human, not on work in flight.
							"outdated", "update_failed" -> Long.MAX_VALUE
							else -> 180_000L
						}
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

	/**
	 * Ends VM access when the host has not been heard from for too long.
	 *
	 * Closing the peer connection is what actually revokes access: the tunnel
	 * carries the VM service, and the VM service is arbitrary code execution
	 * inside the app. The relay socket is left alone on purpose — the session
	 * is still valid and the host may come back, at which point its
	 * hello starts a fresh offer and a new tunnel.
	 */
	private fun closeDirectForExpiry() {
		directTransport?.close()
		directTransport = null
		resumeOwnVm()
		setProgress("", 0, 0)
		if (status in HOST_PRESENT_STATES) status = "waiting_host"
	}

	// ---- tunnel frames ----------------------------------------------------

	private fun sendBinaryFrame(frame: ByteArray): Boolean {
		if (preferDirect) {
			val direct = directTransport
			if (direct != null && direct.send(frame)) return true
			ws?.let {
				failDirectSession(it, "tunnel payload produced before WebRTC was ready")
			}
			return false
		}
		return ws?.send(frame.toByteString()) == true
	}

	private fun handleFrame(bytes: ByteArray) {
		// Both transports are already dropping host traffic while paused;
		// this catches a frame that was in flight when the pause landed.
		if (paused) return
		val frame = TunnelFrame.parse(bytes)
		if (frame == null) {
			Log.w(TAG, "[$logTag] dropped a malformed tunnel frame (${bytes.size} bytes)")
			return
		}
		val channel = frame.channel
		when (frame) {
			is TunnelFrame.Open -> {
				val epoch = synchronized(flowLock) {
					// A reused number would orphan the first socket: the peer
					// has lost track of it, so both go.
					if (pending.containsKey(channel) || sockets.containsKey(channel)) {
						Log.w(TAG, "[$logTag] channel $channel opened twice; closing it")
						closeChannel(channel, notifyPeer = true)
						return
					}
					// Every channel costs a socket and two threads.
					if (pending.size + sockets.size >= MAX_CHANNELS) {
						Log.w(TAG, "[$logTag] refused channel $channel: $MAX_CHANNELS already open")
						sendBinaryFrame(encodeClose(channel))
						return
					}
					pending[channel] = java.io.ByteArrayOutputStream()
					channelEpoch
				}
				// Only VM service traffic can be a DevFS upload.
				if (frame.target == null) sniffers[channel] = DevFsDelta.Sniffer(epoch)
				openChannel(channel, epoch, frame.target)
			}
			is TunnelFrame.Data -> {
				val sniffer = sniffers[channel]
				if (sniffer != null) {
					sniff(channel, sniffer, frame)
				} else if (deliver(channel, frame.frame, TunnelFrame.HEADER_BYTES, frame.length)) {
					sendBinaryFrame(encodeAck(channel, frame.length))
				}
			}
			is TunnelFrame.Ack -> synchronized(flowLock) {
				unacked[channel] = maxOf(0, (unacked[channel] ?: 0) - frame.bytes)
				flowLock.notifyAll()
			}
			is TunnelFrame.Close -> closeChannel(channel, notifyPeer = false)
			is TunnelFrame.UpdateData -> updater?.handleData(frame.frame)
		}
	}

	/**
	 * Writes tunnel bytes to the channel's VM socket, or holds them until it
	 * connects. The connect thread flushes pending bytes and publishes the
	 * socket under this same lock, so no data falls between those steps.
	 */
	private fun deliver(
		channel: Int, bytes: ByteArray, offset: Int, length: Int, epoch: Long = channelEpoch,
	): Boolean =
		synchronized(flowLock) {
			if (epoch != channelEpoch) return false
			try {
				val end = sockets[channel]
				if (end != null) {
					end.write(bytes, offset, length)
				} else {
					val buffer = pending[channel] ?: return false
					buffer.write(bytes, offset, length)
				}
				true
			} catch (e: Exception) {
				Log.w(TAG, "write failed ch=$channel: $e")
				closeChannel(channel, notifyPeer = true)
				false
			}
		}

	/** Holds a channel's first bytes until they show whether the request is an
	 *  RHR DevFS upload. Anything else goes through exactly as sent.
	 *
	 *  Everything held here is acked as it arrives, so the peer's window does
	 *  not bound it; the caps below do. Before the head ends, each frame
	 *  rescans the bytes so far, which [MAX_SNIFFED_HEAD] keeps small. */
	private fun sniff(channel: Int, sniffer: DevFsDelta.Sniffer, frame: TunnelFrame.Data) {
		sniffer.bytes.write(frame.frame, TunnelFrame.HEADER_BYTES, frame.length)
		sendBinaryFrame(encodeAck(channel, frame.length))
		if (sniffer.head == null) {
			if (sniffer.notAPut()) return passThrough(channel)
			val bytes = sniffer.bytes.toByteArray()
			val head = DevFsDelta.parseHead(bytes, bytes.size)
			if (head == null) {
				if (bytes.size > MAX_SNIFFED_HEAD) passThrough(channel)
				return
			}
			if (!head.isRhrUpload) return passThrough(channel)
			val length = head.contentLength
			if (length == null || length < 0 || length > MAX_RHR_UPLOAD) {
				// An RHR upload cannot go to the VM as sent, and one this
				// size is not ours to hold. The CLI reports the closed upload.
				Log.w(TAG, "[$logTag] refused DevFS upload ch=$channel: content-length ${head.headers["content-length"]}")
				closeChannel(channel, notifyPeer = true)
				return
			}
			sniffer.head = head
		}
		val head = sniffer.head ?: return
		// Both terms are bounded above, so this cannot overflow.
		val end = head.bodyStart + (head.contentLength ?: return)
		if (sniffer.bytes.size() < end) return
		sniffers.remove(channel)
		val body = sniffer.bytes.toByteArray().copyOfRange(head.bodyStart, end)
		Thread { forwardUpload(channel, sniffer.epoch, head, body) }.apply { isDaemon = true }.start()
	}

	private fun passThrough(channel: Int) {
		val bytes = sniffers.remove(channel)?.bytes?.toByteArray() ?: return
		deliver(channel, bytes, 0, bytes.size)
	}

	/** Rebuilds an RHR upload and sends the VM the plain PUT it expects. A
	 *  missing base or a bad hash answers 409; the CLI resends the whole file.
	 *  Runs on its own thread, so it only touches [channel] while [epoch] is
	 *  still the current connection's. */
	private fun forwardUpload(channel: Int, epoch: Long, head: DevFsDelta.Head, body: ByteArray) {
		var forward: DevFsDelta.Forward? = null
		try {
			forward = DevFsDelta.rebuild(File(cacheDir, "rhr-devfs-bases"), head, body)
			if (debugRebuildDelayMs > 0) {
				Log.i(TAG, "DevFS upload ch=$channel: debug delay ${debugRebuildDelayMs}ms (epoch $epoch)")
				Thread.sleep(debugRebuildDelayMs)
				Log.i(TAG, "DevFS upload ch=$channel: delivering now (epoch $epoch, current $channelEpoch)")
			}
			if (forward == null) {
				Log.w(TAG, "DevFS upload ch=$channel: base missing or hash mismatch, asking for the whole file")
				val answer = DevFsDelta.missingBase
				synchronized(flowLock) {
					if (epoch != channelEpoch) return
					sendBinaryFrame(encodeData(channel, answer, answer.size))
					closeChannel(channel, notifyPeer = true)
				}
				return
			}
			if (!deliver(channel, forward.head, 0, forward.head.size, epoch)) return
			forward.inlineBody?.let { deliver(channel, it, 0, it.size, epoch) }
			forward.body?.inputStream()?.use { input ->
				val buffer = ByteArray(64 * 1024)
				while (true) {
					val n = input.read(buffer)
					if (n < 0 || !deliver(channel, buffer, 0, n, epoch)) break
				}
			}
		} catch (e: Exception) {
			Log.w(TAG, "DevFS upload ch=$channel failed: $e")
			synchronized(flowLock) {
				if (epoch == channelEpoch) closeChannel(channel, notifyPeer = true)
			}
		} finally {
			forward?.body?.delete()
		}
	}

	/** Connects [channel] to the VM service, or to a [target] from
	 *  [DeviceEndpoints]. Like a DevFS rebuild, the connect and its reader
	 *  outlive the connection that opened them, so they only touch [channel]
	 *  while [epoch] is current and the end is still theirs. */
	private fun openChannel(channel: Int, epoch: Long, target: Int?) {
		Thread {
			try {
				val sock = if (target == null) {
					val vm = android.net.Uri.parse(vmUri)
					val socket = Socket()
					socket.connect(InetSocketAddress(vm.host ?: "127.0.0.1", vm.port), 5000)
					ChannelEnd.of(socket)
				} else {
					DeviceEndpoints.open(this, target, connectedPackage)
				}
				// Flush anything that arrived while we were connecting, then
				// atomically switch the channel over to the live end.
				synchronized(flowLock) {
					val buffered = if (epoch == channelEpoch) pending.remove(channel) else null
					if (buffered == null) {
						// Channel was closed while we were connecting.
						sock.close()
						return@Thread
					}
					if (buffered.size() > 0) {
						val bytes = buffered.toByteArray()
						sock.write(bytes, 0, bytes.size)
					}
					sockets[channel] = sock
				}
				val reader = Thread {
					val buf = ByteArray(TUNNEL_READ_BYTES)
					try {
						val input = sock.input
						while (true) {
							val n = input.read(buf)
							if (n < 0) break
							synchronized(flowLock) {
								if (sockets[channel] !== sock) return@Thread
								sendBinaryFrame(encodeData(channel, buf, n))
								// Flow control: block while this channel's window is full.
								unacked[channel] = (unacked[channel] ?: 0) + n
								while ((unacked[channel] ?: 0) >= WINDOW_BYTES &&
									sockets[channel] === sock && !stopped.get()) {
									flowLock.wait(1000)
									if ((unacked[channel] ?: 0) < LOW_WATER) break
								}
							}
						}
					} catch (_: Exception) {
					} finally {
						synchronized(flowLock) {
							if (sockets.remove(channel, sock)) {
								sendBinaryFrame(encodeClose(channel))
								unacked.remove(channel)
							}
							readers.remove(channel, Thread.currentThread())
						}
					}
				}
				readers[channel] = reader
				reader.isDaemon = true
				reader.start()
			} catch (e: Exception) {
				Log.w(TAG, "channel $channel: connect to ${target ?: "VM"} failed: $e")
				synchronized(flowLock) {
					if (epoch == channelEpoch) closeChannel(channel, notifyPeer = true)
				}
			}
		}.also { it.isDaemon = true }.start()
	}

	private fun closeChannel(channel: Int, notifyPeer: Boolean) = synchronized(flowLock) {
		pending.remove(channel)
		sniffers.remove(channel)
		sockets.remove(channel)?.let { try { it.close() } catch (_: Exception) {} }
		readers.remove(channel)?.interrupt()
		synchronized(flowLock) { unacked.remove(channel); flowLock.notifyAll() }
		if (notifyPeer) sendBinaryFrame(encodeClose(channel))
	}

	private fun cleanupChannels() {
		synchronized(flowLock) { channelEpoch += 1 }
		for (ch in sockets.keys.toList()) closeChannel(ch, notifyPeer = false)
		pending.clear()
		sniffers.clear()
	}

	private fun encodeData(channel: Int, buf: ByteArray, n: Int): ByteArray =
		ByteBuffer.allocate(5 + n).put(TunnelFrame.OP_DATA.toByte()).putInt(channel)
			.put(buf, 0, n).array()

	private fun encodeAck(channel: Int, n: Int): ByteArray =
		ByteBuffer.allocate(9).put(TunnelFrame.OP_ACK.toByte()).putInt(channel).putInt(n).array()

	private fun encodeClose(channel: Int): ByteArray =
		ByteBuffer.allocate(5).put(TunnelFrame.OP_CLOSE.toByte()).putInt(channel).array()

	private fun ByteArray.toByteString(): ByteString = toByteString(0, size)

	// ---- persistent asset store (DevFS symlink trick) ---------------------
	//
	// flutter attach creates a fresh random-suffixed DevFS dir per session and
	// never reuses old ones (verified: orphans accumulate, assets re-download
	// every session). We plant build/flutter_assets inside each new DevFS dir
	// as a symlink into a persistent per-project store, so the CLI's asset
	// push lands in permanent storage and later sessions start warm.

	// Debounced "guest kernel ready" signal. When Flutter creates its DevFS dir
	// and syncs the guest kernel, the host end needs to hot-restart to boot it —
	// but only ONCE the sync has settled. We arm a timer on DevFS activity and
	// fire {"t":"ready"} to the host after a quiet window so asset sync can finish
	// and the overlay can ask the host for the initial Hot Restart.
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
				val project = DevFsDelta.projectName(path) ?: return
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
			if (f.isDirectory && DevFsDelta.projectName(f.name) != null &&
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
			(Os.lstat(f.absolutePath).st_mode and android.system.OsConstants.S_IFLNK) != 0
		} catch (_: Exception) {
			false
		}
		if (!isLink && f.isDirectory) {
			f.listFiles()?.forEach { deleteWithoutFollowingSymlinks(it) }
		}
		f.delete()
	}

	// ---- notification -----------------------------------------------------

	/** Posts the session notification again, after device control changed. */
	private fun refreshNotification() {
		(getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
			.notify(NOTIF_ID, buildNotification())
	}

	private fun buildNotification(): Notification {
		val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
		nm.createNotificationChannel(
			NotificationChannel(
				CHANNEL_ID, "rhr session", NotificationManager.IMPORTANCE_LOW))
		val builder = Notification.Builder(this, CHANNEL_ID)
			.setContentTitle("rhr session active")
			.setSmallIcon(android.R.drawable.stat_sys_download)
			.setOngoing(true)
		fun action(cmd: String, title: String) = Notification.Action.Builder(
			null, title,
			PendingIntent.getService(
				this, 1,
				Intent(this, RhrSessionService::class.java).putExtra("cmd", cmd),
				PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
			),
		).build()
		when {
			agentStopped -> builder.setContentText("You turned off agent control for this session")
				.addAction(action("allow_agent", "Allow agent control"))
			agentControlling -> builder.setContentText("Your coding agent can see and tap this phone")
				.addAction(action("stop_agent", "Stop agent control"))
			else -> builder.setContentText("Remote hot reload tunnel is running")
		}
		return builder.build()
	}
}
