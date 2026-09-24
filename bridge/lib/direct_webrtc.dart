import 'dart:async';
import 'dart:typed_data';

import 'package:webrtc_dart/webrtc_dart.dart';

import 'direct_signaling.dart';

typedef DirectSignalSink = void Function(DirectSignal signal);

/// An ordered, reliable WebRTC data channel for the RHR tunnel.
///
/// This class owns only the peer connection. Signaling still travels over the
/// existing session relay via [onSignal], so callers can choose whether the
/// direct path is attempted.
/// One data-channel message carries one already-framed RHR tunnel packet.
final class DirectWebRtcPeer {
  static const _dataChannelMid = '0';

  DirectWebRtcPeer({
    required DirectSignalSink onSignal,
    RtcConfiguration? configuration,
    String label = 'rhr-tunnel-v1',
  }) : _onSignal = onSignal,
       _peer = RTCPeerConnection(configuration ?? const RtcConfiguration()),
       _label = label {
    _iceSubscription = _peer.onIceCandidate.listen((candidate) {
      _onSignal(
        DirectCandidateSignal(
          candidate: candidate.candidate,
          // webrtc_dart can omit these for its single data-channel m-line.
          // Android's libwebrtc JNI requires them, so use the deterministic
          // m-line identity for this data-only protocol.
          sdpMid: candidate.sdpMid ?? _dataChannelMid,
          sdpMLineIndex: candidate.sdpMLineIndex ?? 0,
        ),
      );
    });
    _iceGatheringSubscription = _peer.onIceGatheringStateChange.listen((state) {
      if (state == IceGatheringState.complete) {
        _onSignal(const DirectEndSignal());
      }
    });
    _peer.onDataChannel.listen(_bindChannel);
    _peer.onConnectionStateChange.listen((state) {
      if (!_state.isClosed) _state.add(state);
    });
  }

  /// Uses host candidates only, which is useful for deterministic LAN tests.
  factory DirectWebRtcPeer.localOnly({
    required DirectSignalSink onSignal,
    String label = 'rhr-tunnel-v1',
  }) {
    return DirectWebRtcPeer(
      onSignal: onSignal,
      configuration: const RtcConfiguration(iceServers: []),
      label: label,
    );
  }

  final DirectSignalSink _onSignal;
  final RTCPeerConnection _peer;
  final String _label;
  final _messages = StreamController<Uint8List>.broadcast();
  final _state = StreamController<PeerConnectionState>.broadcast();
  final _remoteCandidates = <DirectCandidateSignal>[];
  StreamSubscription<RTCIceCandidate>? _iceSubscription;
  StreamSubscription<IceGatheringState>? _iceGatheringSubscription;
  StreamSubscription<DataChannelState>? _channelStateSubscription;
  StreamSubscription<dynamic>? _channelMessageSubscription;
  dynamic _channel;
  final _channelDiscovered = Completer<dynamic>();
  Completer<dynamic>? _channelReady;
  bool _remoteDescriptionSet = false;
  bool _closed = false;

  Stream<Uint8List> get messages => _messages.stream;
  Stream<PeerConnectionState> get connectionStates => _state.stream;
  PeerConnectionState get connectionState => _peer.connectionState;

  /// Creates the offer and sends it through [onSignal].
  Future<void> startOffer() async {
    _ensureOpen();
    if (_channel != null) {
      throw StateError('direct WebRTC offer already started');
    }
    await _peer.waitForReady();
    _bindChannel(_peer.createDataChannel(_label, ordered: true));
    final offer = await _peer.createOffer();
    await _peer.setLocalDescription(offer);
    _onSignal(DirectDescriptionSignal.offer(offer.sdp));
  }

  /// Accepts an offer and sends the answer through [onSignal].
  Future<void> acceptOffer(DirectDescriptionSignal offer) async {
    _ensureOpen();
    if (!offer.isOffer) {
      throw ArgumentError.value(offer.type, 'offer.type', 'must be offer');
    }
    await _setRemoteDescription(offer);
    final answer = await _peer.createAnswer();
    await _peer.setLocalDescription(answer);
    _onSignal(DirectDescriptionSignal.answer(answer.sdp));
  }

  /// Completes the offer/answer exchange on the offerer.
  Future<void> acceptAnswer(DirectDescriptionSignal answer) async {
    _ensureOpen();
    if (!answer.isAnswer) {
      throw ArgumentError.value(answer.type, 'answer.type', 'must be answer');
    }
    await _setRemoteDescription(answer);
  }

  /// Adds a remote ICE candidate, buffering trickled candidates that arrive
  /// before the offer/answer has been installed.
  Future<void> addCandidate(DirectCandidateSignal signal) async {
    _ensureOpen();
    if (signal.candidate == null) return;
    if (!_remoteDescriptionSet) {
      _remoteCandidates.add(signal);
      return;
    }
    await _addCandidate(signal);
  }

  /// Waits for the SCTP data channel to become open.
  Future<void> waitUntilOpen({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (_channel == null) {
      await _channelDiscovered.future.timeout(timeout);
    }
    final ready = _channelReady;
    if (ready == null) {
      throw StateError('the direct data channel has not been negotiated');
    }
    await ready.future.timeout(timeout);
  }

  /// Pause new sends above this much queued data, resuming as it clears.
  ///
  /// One megabyte is enough to keep the SCTP association busy on a fast link
  /// without letting an asset push queue the whole bundle in memory.
  static const _bufferHighWater = 1024 * 1024;

  Future<void> send(Uint8List frame) async {
    _ensureOpen();
    final channel = _channel;
    if (channel == null) {
      throw StateError('the direct data channel has not been negotiated');
    }
    final ready = _channelReady;
    if (ready != null && !ready.isCompleted) await ready.future;
    // webrtc_dart 0.25.x starts SCTP transmission fire-and-forget from
    // sendBinary(). A SACK can therefore enter _transmit while the previous
    // call is still walking its sent queue; the package's unhandled
    // ConcurrentModificationError used to take down the whole CLI isolate.
    // Keep the send future alive until the channel drains and contain any
    // late package error in this peer's state stream so the transport can
    // terminate the session instead of crashing the isolate.
    final completion = Completer<void>();
    runZonedGuarded(
      () => unawaited(_sendAndDrain(channel, frame, completion)),
      (Object error, StackTrace stack) {
        if (!_closed && !_state.isClosed) {
          _state.add(PeerConnectionState.failed);
        }
        if (!completion.isCompleted) {
          completion.completeError(error, stack);
        }
      },
    );
    await completion.future;
  }

  /// Applies backpressure while a send is outstanding, then completes.
  ///
  /// `bufferedAmount` counts the WHOLE channel, not this frame, so waiting for
  /// zero makes every send wait for every other send. During an asset push
  /// that backlog reaches megabytes and never empties, so a nine-byte control
  /// frame would sit behind it until the caller's timeout fired — and that
  /// timeout tears down the session. Waiting instead for the buffer to fall
  /// under a high-water mark keeps the channel from growing without bound
  /// while letting a send finish as soon as the queue is moving.
  Future<void> _sendAndDrain(
    dynamic channel,
    Uint8List frame,
    Completer<void> completion,
  ) async {
    try {
      await channel.sendBinary(frame);
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (channel.bufferedAmount > _bufferHighWater) {
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('direct WebRTC data channel did not drain');
        }
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      if (!completion.isCompleted) completion.complete();
    } catch (error, stack) {
      if (!completion.isCompleted) completion.completeError(error, stack);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _channelMessageSubscription?.cancel();
    await _channelStateSubscription?.cancel();
    await _iceSubscription?.cancel();
    await _iceGatheringSubscription?.cancel();
    try {
      await _peer.close();
    } finally {
      await _messages.close();
      await _state.close();
    }
  }

  Future<void> _setRemoteDescription(DirectDescriptionSignal signal) async {
    await _peer.setRemoteDescription(
      RTCSessionDescription(type: signal.type, sdp: signal.sdp),
    );
    _remoteDescriptionSet = true;
    final buffered = List<DirectCandidateSignal>.of(_remoteCandidates);
    _remoteCandidates.clear();
    for (final candidate in buffered) {
      await _addCandidate(candidate);
    }
  }

  Future<void> _addCandidate(DirectCandidateSignal signal) async {
    final parsed = RTCIceCandidate.fromSdp(signal.candidate!);
    await _peer.addIceCandidate(
      RTCIceCandidate(
        foundation: parsed.foundation,
        component: parsed.component,
        transport: parsed.transport,
        priority: parsed.priority,
        host: parsed.host,
        port: parsed.port,
        type: parsed.type,
        relatedAddress: parsed.relatedAddress,
        relatedPort: parsed.relatedPort,
        tcpType: parsed.tcpType,
        generation: parsed.generation,
        ufrag: parsed.ufrag,
        sdpMid: signal.sdpMid ?? _dataChannelMid,
        sdpMLineIndex: signal.sdpMLineIndex ?? 0,
      ),
    );
  }

  void _bindChannel(dynamic channel) {
    if (_channel != null || _closed) return;
    _channel = channel;
    if (!_channelDiscovered.isCompleted) _channelDiscovered.complete(channel);
    final ready = _channelReady = Completer<dynamic>();
    _channelStateSubscription = channel.onStateChange.listen((state) {
      if (state == DataChannelState.open && !ready.isCompleted) {
        ready.complete(channel);
      } else if (state == DataChannelState.closed && !ready.isCompleted) {
        ready.completeError(
          StateError('direct data channel closed before open'),
        );
      } else if (state == DataChannelState.closed && !_closed) {
        // A data channel can close while the ICE peer still reports
        // connected. Surface it as a transport failure instead of waiting for
        // SCTP's retransmission timer.
        _state.add(PeerConnectionState.failed);
      }
    });
    _channelMessageSubscription = channel.onMessage.listen((message) {
      if (message is Uint8List) {
        _messages.add(message);
      } else if (message is List<int>) {
        _messages.add(Uint8List.fromList(message));
      } else {
        _messages.addError(
          FormatException('direct data channel returned non-binary data'),
        );
      }
    });
    if (channel.state == DataChannelState.open && !ready.isCompleted) {
      ready.complete(channel);
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError('direct WebRTC peer is closed');
  }
}
