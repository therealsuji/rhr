package dev.rhr.rhr_player

import android.content.Context
import android.util.Log
import org.json.JSONObject
import org.webrtc.DataChannel
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import java.nio.ByteBuffer
import java.util.regex.Pattern

/**
 * Persistent Android end of the direct tunnel.
 *
 * The native session service owns this object, not the guest Flutter engine,
 * so a hot restart cannot tear down the data channel. Signaling is deliberately
 * kept on the existing session WebSocket. Tunnel payloads never use that
 * WebSocket while direct mode is active.
 */
internal class RhrDirectTransport(
	context: Context,
	private val sendSignal: (String) -> Unit,
	private val onFrame: (ByteArray) -> Unit,
	private val onState: (State) -> Unit,
	private val onFailure: (String) -> Unit,
) {
	enum class State { CONNECTING, OPEN, FAILED, CLOSED }

	companion object {
		private const val TAG = "rhr_direct"
		private const val SIGNAL_VERSION = 1
		private const val CHANNEL_LABEL = "rhr-tunnel-v1"
		private val initLock = Any()
		private var factoryReady = false

		private fun ensureFactory(context: Context) {
			synchronized(initLock) {
				if (factoryReady) return
				PeerConnectionFactory.initialize(
					PeerConnectionFactory.InitializationOptions
						.builder(context.applicationContext)
						.createInitializationOptions())
				factoryReady = true
			}
		}
	}

	private val appContext = context.applicationContext
	private var factory: PeerConnectionFactory? = null
	private var peer: PeerConnection? = null
	private var channel: DataChannel? = null
	private val pendingCandidates = mutableListOf<IceCandidate>()
	private val remoteCandidateKeys = mutableSetOf<String>()
	private val candidateLock = Any()
	@Volatile private var remoteDescriptionSet = false
	private var remoteMids = emptySet<String>()
	@Volatile private var state = State.CLOSED

	fun isOpen(): Boolean = state == State.OPEN

	fun startOffer() {
		if (state != State.CLOSED) return
		state = State.CONNECTING
		onState(State.CONNECTING)
		Log.i(TAG, "startOffer: initializing peer connection")
		try {
			ensureFactory(appContext)
			Log.i(TAG, "startOffer: factory ready")
			factory = PeerConnectionFactory.builder().createPeerConnectionFactory()
			val iceServers = listOf(
				PeerConnection.IceServer.builder("stun:stun.l.google.com:19302")
					.createIceServer())
			val configuration = PeerConnection.RTCConfiguration(iceServers)
			peer = factory?.createPeerConnection(configuration, observer())
				?: error("WebRTC peer connection could not be created")
			Log.i(TAG, "startOffer: peer created")
			val init = DataChannel.Init().apply { ordered = true }
			channel = peer?.createDataChannel(CHANNEL_LABEL, init)
			bindChannel(channel ?: error("WebRTC data channel could not be created"))
			Log.i(TAG, "startOffer: data channel created")
			peer?.createOffer(object : SdpObserver {
				override fun onCreateSuccess(description: SessionDescription) {
					Log.i(TAG, "createOffer success (${description.description.length} chars)")
					peer?.setLocalDescription(this, description)
					sendDescription("direct_offer", description)
				}
				override fun onSetSuccess() = Unit
				override fun onCreateFailure(error: String) {
					Log.w(TAG, "createOffer failure: $error")
					fail("offer: $error")
				}
				override fun onSetFailure(error: String) {
					Log.w(TAG, "setLocalDescription failure: $error")
					fail("offer set: $error")
				}
			}, MediaConstraints())
			Log.i(TAG, "startOffer: createOffer submitted")
		} catch (error: Throwable) {
			fail("start: ${error.message ?: error.javaClass.simpleName}")
		}
	}

	fun handleSignal(json: String) {
		try {
			val message = JSONObject(json)
			if (message.optInt("v", -1) != SIGNAL_VERSION) return
			when (message.optString("t")) {
				"direct_answer" -> {
					val sdp = message.getString("sdp")
					remoteMids = extractMids(sdp)
					Log.i(TAG, "received answer (${sdp.length} chars, mids=$remoteMids)")
					peer?.setRemoteDescription(
						remoteDescriptionObserver(),
						SessionDescription(SessionDescription.Type.ANSWER, sdp))
				}
				"direct_candidate" -> {
					val candidate = message.optString("candidate", "")
					if (candidate.isEmpty()) return
					val sdpMid = if (message.has("sdpMid") && !message.isNull("sdpMid")) {
						message.getString("sdpMid")
					} else {
						null
					}
					val sdpMLineIndex = message.optInt("sdpMLineIndex", -1)
					if (sdpMid.isNullOrBlank() || sdpMLineIndex < 0) {
						Log.w(TAG, "ignoring remote ICE candidate without a valid media id/index")
						return
					}
					if (!candidate.startsWith("candidate:")) {
						Log.w(TAG, "ignoring malformed remote ICE candidate")
						return
					}
					if (remoteDescriptionSet && remoteMids.isNotEmpty() && sdpMid !in remoteMids) {
						Log.w(TAG, "ignoring remote ICE candidate for unknown media id $sdpMid")
						return
					}
					val key = "$sdpMid|$sdpMLineIndex|$candidate"
					synchronized(candidateLock) {
						if (!remoteCandidateKeys.add(key)) return
						val ice = IceCandidate(sdpMid, sdpMLineIndex, candidate)
						if (remoteDescriptionSet) {
							addRemoteCandidate(ice)
						} else {
							pendingCandidates += ice
						}
					}
				}
			}
		} catch (error: Throwable) {
			Log.w(TAG, "invalid direct signal: ${error.message}")
		}
	}

	fun send(frame: ByteArray): Boolean {
		if (!isOpen()) {
			fail("payload send attempted before the data channel opened")
			return false
		}
		return try {
			val sent = channel?.send(DataChannel.Buffer(ByteBuffer.wrap(frame), true)) == true
			if (!sent) fail("data channel rejected a payload")
			sent
		} catch (error: Throwable) {
			fail("send: ${error.message ?: error.javaClass.simpleName}")
			false
		}
	}

	fun close() {
		if (state == State.CLOSED) return
		state = State.CLOSED
		try { channel?.unregisterObserver() } catch (_: Throwable) {}
		try { channel?.dispose() } catch (_: Throwable) {}
		try { peer?.close() } catch (_: Throwable) {}
		try { peer?.dispose() } catch (_: Throwable) {}
		try { factory?.dispose() } catch (_: Throwable) {}
		channel = null
		peer = null
		factory = null
		pendingCandidates.clear()
		remoteCandidateKeys.clear()
		remoteDescriptionSet = false
		remoteMids = emptySet()
		onState(State.CLOSED)
	}

	private fun observer() = object : PeerConnection.Observer {
		override fun onIceCandidate(candidate: IceCandidate) {
			val signal = JSONObject()
				.put("v", SIGNAL_VERSION)
				.put("t", "direct_candidate")
				.put("candidate", candidate.sdp)
				.put("sdpMid", candidate.sdpMid)
				.put("sdpMLineIndex", candidate.sdpMLineIndex)
			sendSignal(signal.toString())
		}
		override fun onIceGatheringChange(state: PeerConnection.IceGatheringState) {
			if (state == PeerConnection.IceGatheringState.COMPLETE) {
				sendSignal(JSONObject().put("v", SIGNAL_VERSION).put("t", "direct_end").toString())
			}
		}
		override fun onIceConnectionChange(state: PeerConnection.IceConnectionState) {
			when (state) {
				PeerConnection.IceConnectionState.CONNECTED,
				PeerConnection.IceConnectionState.COMPLETED -> Log.i(TAG, "ICE connected")
				PeerConnection.IceConnectionState.FAILED -> fail("ICE failed")
				PeerConnection.IceConnectionState.DISCONNECTED -> fail("ICE disconnected")
				else -> Unit
			}
		}
		override fun onDataChannel(channel: DataChannel) {
			bindChannel(channel)
		}
		override fun onSignalingChange(state: PeerConnection.SignalingState) = Unit
		override fun onIceConnectionReceivingChange(receiving: Boolean) = Unit
		override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>) = Unit
		override fun onAddStream(stream: org.webrtc.MediaStream) = Unit
		override fun onRemoveStream(stream: org.webrtc.MediaStream) = Unit
		override fun onRenegotiationNeeded() = Unit
		override fun onTrack(transceiver: org.webrtc.RtpTransceiver) = Unit
	}

	private fun bindChannel(next: DataChannel) {
		channel = next
		next.registerObserver(object : DataChannel.Observer {
			override fun onBufferedAmountChange(previousAmount: Long) = Unit
			override fun onStateChange() {
				when (next.state()) {
					DataChannel.State.OPEN -> {
						state = State.OPEN
						onState(State.OPEN)
					}
					DataChannel.State.CLOSED -> if (state != State.CLOSED) fail("data channel closed")
					else -> Unit
				}
			}
			override fun onMessage(buffer: DataChannel.Buffer) {
				if (!buffer.binary) {
					fail("data channel returned a non-binary message")
					return
				}
				val bytes = ByteArray(buffer.data.remaining())
				buffer.data.get(bytes)
				onFrame(bytes)
			}
		})
	}

	private fun sendDescription(type: String, description: SessionDescription) {
		sendSignal(
			JSONObject()
				.put("v", SIGNAL_VERSION)
				.put("t", type)
				.put("sdp", description.description)
				.toString())
	}

	private fun remoteDescriptionObserver() = object : SdpObserver {
		override fun onCreateSuccess(description: SessionDescription) = Unit
		override fun onSetSuccess() {
			val candidates = synchronized(candidateLock) {
				remoteDescriptionSet = true
				val buffered = pendingCandidates.toList()
				pendingCandidates.clear()
				buffered
			}
			candidates.forEach(::addRemoteCandidate)
		}
		override fun onCreateFailure(error: String) = fail("remote description: $error")
		override fun onSetFailure(error: String) = fail("remote description: $error")
	}

	private fun fail(reason: String) {
		if (state == State.FAILED || state == State.CLOSED) return
		Log.w(TAG, reason)
		state = State.FAILED
		onState(State.FAILED)
		onFailure(reason)
	}

	/**
	 * JNI's nativeAddIceCandidate aborts the process for malformed candidates
	 * instead of returning an error. Validate the fields that identify the
	 * answer's media section before crossing that boundary.
	 */
	private fun addRemoteCandidate(candidate: IceCandidate) {
		if (candidate.sdpMid.isNullOrBlank() || candidate.sdpMLineIndex < 0) return
		if (remoteMids.isNotEmpty() && candidate.sdpMid !in remoteMids) return
		Log.i(TAG, "adding remote ICE candidate mid=${candidate.sdpMid} index=${candidate.sdpMLineIndex}")
		peer?.addIceCandidate(candidate)
	}

	private fun extractMids(sdp: String): Set<String> {
		val pattern = Pattern.compile("(?m)^a=mid:([^\\r\\n]+)")
		val matcher = pattern.matcher(sdp)
		val mids = mutableSetOf<String>()
		while (matcher.find()) matcher.group(1)?.let(mids::add)
		return mids
	}
}
