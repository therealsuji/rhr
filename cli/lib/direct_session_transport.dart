import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:rhr_bridge/direct_signaling.dart';
import 'package:rhr_bridge/direct_webrtc.dart';
import 'package:webrtc_dart/webrtc_dart.dart';

import 'relay_race.dart';

final class DirectTransportFailure implements Exception {
  const DirectTransportFailure(this.message, {this.transient = false});

  final String message;

  /// Whether retrying could plausibly succeed.
  ///
  /// A relay socket that drops mid-negotiation says nothing about whether a
  /// direct path is possible — the next attempt usually gets one. A refusal
  /// from the device, or a payload path that failed after being established,
  /// is a real answer and retrying only spins.
  final bool transient;

  @override
  String toString() => message;
}

/// Uses the relay for text control messages and WebRTC for tunnel payloads.
/// Binary relay frames are protocol errors in this mode.
final class DirectSessionTransport implements SessionTransport {
  DirectSessionTransport(
    this._relay, {
    this.offerTimeout = const Duration(seconds: 20),
    this.connectionTimeout = const Duration(seconds: 20),
    // A send waits on the peer's receive window, so this has to outlast a
    // phone that is briefly full — which is ordinary mid-restart, when a 40 MB
    // kernel is going out faster than the engine drains it. Four seconds
    // failed sessions that were about to succeed; the ICE layer already tears
    // down a genuinely dead path at roughly 30s (six consent misses), so this
    // sits just inside that and does not mask real loss.
    this.sendTimeout = const Duration(seconds: 25),
  }) {
    _payloadReady.future.ignore();
    _directZone = Zone.current.fork(
      specification: ZoneSpecification(
        handleUncaughtError: (self, parent, zone, error, stack) {
          _fail('direct WebRTC runtime failure: $error', stack: stack);
        },
      ),
    );
    _directZone.run(() {
      _peer = DirectWebRtcPeer(
        onSignal: (signal) {
          try {
            _relay.sendControl(signal.encode());
          } on Object catch (error, stack) {
            _fail('direct signaling failed: $error', stack: stack);
          }
        },
      );
      _peer.messages.listen(
        (frame) {
          if (!_directReady) {
            _fail('direct payload arrived before WebRTC became ready');
            return;
          }
          if (!_events.isClosed) _events.add(frame);
        },
        onError: (Object error, StackTrace stack) {
          _fail('direct WebRTC receive failed: $error', stack: stack);
        },
      );
      _peer.connectionStates.listen((state) {
        if (_closed || _failure != null) return;
        // `disconnected` is transient by definition: the ICE layer raises it on
        // a SINGLE missed consent check — one STUN binding request with a 2s
        // wait and no retransmit — and clears it again on the next success.
        // During a 50MB asset push a 2s blip is ordinary, so treating it as
        // fatal tore down healthy sessions. Real loss still arrives as
        // `failed`, which the ICE layer raises only after six consecutive
        // misses, roughly the 30s RFC 7675 allows before consent expires.
        // `closed` is the device tearing its peer down on purpose: it does
        // that when it replaces the session (connector mode adopting a new
        // target VM), when the tester taps Disconnect, or when its own relay
        // socket drops — and in all but the second case it redials within a
        // second. That is a reason to re-dial and renegotiate, not to quit.
        // No direct_error goes back either: it would land on the device's
        // replacement session and fail that one too.
        if (state == PeerConnectionState.closed) {
          _fail(
            'direct WebRTC connection closed by the device',
            notifyPeer: false,
            transient: true,
          );
        } else if (state == PeerConnectionState.failed) {
          // Before the data channel ever opened this is ICE finding no
          // pair, which on the same network and candidates succeeds on the
          // next offer often enough to be worth one (seen on the SM-A566B:
          // one failure between runs that connected in under a second).
          // After it opened it is a path that was working and died.
          _fail('direct WebRTC connection failed', transient: _stage != 'open');
        }
      });
      _relaySubscription = _relay.controlStream.listen(
        _onRelayControl,
        onDone: _relayClosed,
        onError: (Object error, StackTrace stack) {
          _fail('direct-only relay protocol failed: $error', stack: stack);
        },
      );
    });
  }

  final RelayControlTransport _relay;
  final Duration offerTimeout;
  final Duration connectionTimeout;
  final Duration sendTimeout;
  final _events = StreamController<Object>();
  final _payloadReady = Completer<void>();
  late final Zone _directZone;
  late final DirectWebRtcPeer _peer;
  late final StreamSubscription<String> _relaySubscription;
  Timer? _offerTimer;
  Timer? _candidateTimer;
  DirectDescriptionSignal? _pendingOffer;
  Future<void>? _negotiation;
  var _remoteCandidatesComplete = false;
  var _directReady = false;

  /// How far direct negotiation got. A direct path that dies silently is the
  /// hardest failure here to act on — "direct WebRTC connection failed" says
  /// nothing about whether the offer never arrived, candidates never
  /// finished gathering, or DTLS never completed — so every failure names
  /// the last stage reached.
  var _stage = 'waiting for the device to announce itself';
  var _closed = false;
  DirectTransportFailure? _failure;

  @override
  Stream<Object> get stream => _events.stream;

  @override
  Future<String> get selectedRelay => _relay.selectedRelay;

  @override
  Future<void> get payloadReady => _payloadReady.future;

  @override
  String? get closeReason => _relay.closeReason;

  @override
  void sendControl(String message) {
    // Deliberately NOT gated on _failure, unlike sendPayload below. Control
    // text rides the relay and never touches WebRTC, so a dead payload path
    // says nothing about whether this can be delivered — _fail itself sends
    // its peer notification through _relay.sendControl for that reason.
    //
    // Gating it here meant a WebRTC failure silently took out the farewell
    // (dev_gone), the presence heartbeat (ping) and the re-signaling that
    // would have rebuilt the very channel that died.
    if (_closed) throw StateError('direct session transport is closed');
    _relay.sendControl(message);
  }

  @override
  Future<void> sendPayload(Uint8List message) async {
    final failure = _failure;
    if (failure != null) throw failure;
    if (_closed) throw StateError('direct session transport is closed');
    if (!_directReady) {
      throw const DirectTransportFailure(
        'direct WebRTC payload path is not ready',
      );
    }
    try {
      await _peer.send(message).timeout(sendTimeout);
    } on Object catch (error, stack) {
      final failure = DirectTransportFailure(
        'direct WebRTC payload send failed: $error',
      );
      _fail(failure.message, stack: stack);
      throw failure;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _offerTimer?.cancel();
    _candidateTimer?.cancel();
    if (!_payloadReady.isCompleted) {
      _payloadReady.completeError(
        const DirectTransportFailure(
          'session closed before the direct WebRTC payload path was ready',
        ),
      );
    }
    await _relaySubscription.cancel();
    await _peer.close();
    if (!_events.isClosed) await _events.close();
    await _relay.close();
  }

  void _onRelayControl(String message) {
    final decoded = _decodeControl(message);
    switch (decoded) {
      case DirectSignal signal:
        unawaited(
          _handleSignal(signal).catchError((Object error, StackTrace stack) {
            _fail(
              'direct WebRTC negotiation failed: $error',
              stack: stack,
              transient: error is TimeoutException,
            );
          }),
        );
      case _DeviceInfo():
        _offerTimer ??= Timer(
          offerTimeout,
          () => _fail('device did not offer a direct WebRTC payload path'),
        );
        if (!_events.isClosed) _events.add(message);
      case _ApplicationControl():
        if (!_events.isClosed) _events.add(message);
      case _InvalidDirectControl(:final error):
        _fail('invalid direct signaling message: $error');
    }
  }

  Future<void> _handleSignal(DirectSignal signal) async {
    switch (signal) {
      case DirectDescriptionSignal(:final type):
        if (type != 'offer') {
          throw const FormatException(
            'device sent an unexpected direct answer',
          );
        }
        _offerTimer?.cancel();
        _stage = 'offer received, gathering remote ICE candidates';
        _pendingOffer = signal;
        _candidateTimer ??= Timer(
          connectionTimeout,
          () => _fail('device did not finish gathering direct ICE candidates'),
        );
        await _startNegotiationWhenReady();
      case DirectCandidateSignal():
        await _peer.addCandidate(signal);
      case DirectEndSignal():
        _stage = 'remote candidates complete, negotiating';
        _remoteCandidatesComplete = true;
        _candidateTimer?.cancel();
        await _startNegotiationWhenReady();
      case DirectErrorSignal(:final message):
        // The device reports the same ICE verdict from its side; before the
        // channel opened it is the same retryable negotiation failure.
        _fail(
          'device direct transport failed: $message',
          notifyPeer: false,
          transient: _stage != 'open',
        );
    }
  }

  Future<void> _startNegotiationWhenReady() async {
    final offer = _pendingOffer;
    if (offer == null || !_remoteCandidatesComplete) return;
    final negotiation = _negotiation ??= _negotiate(offer);
    await negotiation;
  }

  Future<void> _negotiate(DirectDescriptionSignal offer) async {
    await _peer.acceptOffer(offer);
    _stage = 'offer accepted, waiting for the data channel to open';
    await _peer.waitUntilOpen(timeout: connectionTimeout);
    if (_closed || _failure != null) return;
    _directReady = true;
    _stage = 'open';
    if (!_payloadReady.isCompleted) _payloadReady.complete();
    stderr.writeln('[rhr] direct WebRTC/STUN payload path is ready');
  }

  void _fail(
    String message, {
    StackTrace? stack,
    bool notifyPeer = true,
    bool transient = false,
  }) {
    if (_closed || _failure != null) return;
    final failure = _failure = DirectTransportFailure(
      _stage == 'open' ? message : '$message (stage: $_stage)',
      transient: transient,
    );
    _directReady = false;
    _offerTimer?.cancel();
    _candidateTimer?.cancel();
    if (!_payloadReady.isCompleted) {
      _payloadReady.completeError(failure, stack ?? StackTrace.current);
    }
    if (notifyPeer) {
      try {
        _relay.sendControl(DirectErrorSignal(message).encode());
      } catch (_) {}
    }
    if (!_events.isClosed) {
      _events.addError(failure, stack ?? StackTrace.current);
    }
    unawaited(_peer.close());
  }

  void _relayClosed() {
    final failure = _failure ??= const DirectTransportFailure(
      'signaling relay closed; reconnect to the phone',
      transient: true,
    );
    _directReady = false;
    if (!_payloadReady.isCompleted) _payloadReady.completeError(failure);
    if (!_events.isClosed) unawaited(_events.close());
  }

  static Object _decodeControl(String message) {
    try {
      final decoded = jsonDecode(message);
      if (decoded is! Map<String, dynamic>) return const _ApplicationControl();
      final type = decoded['t'];
      if (type == 'info') return const _DeviceInfo();
      if (type is! String || !type.startsWith('direct_')) {
        return const _ApplicationControl();
      }
      try {
        return DirectSignal.decode(decoded);
      } on FormatException catch (error) {
        return _InvalidDirectControl(error);
      }
    } on FormatException {
      return const _ApplicationControl();
    }
  }
}

final class _DeviceInfo {
  const _DeviceInfo();
}

final class _ApplicationControl {
  const _ApplicationControl();
}

final class _InvalidDirectControl {
  const _InvalidDirectControl(this.error);

  final FormatException error;
}
