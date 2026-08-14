import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:rhr_bridge/direct_signaling.dart';
import 'package:rhr_bridge/direct_webrtc.dart';
import 'package:webrtc_dart/webrtc_dart.dart';

import 'relay_race.dart';

/// Upgrades the payload leg of a selected relay session to WebRTC when the
/// device advertises it. The relay remains the signaling and fallback path.
/// This keeps the rollout opt-in: callers that do not construct this wrapper
/// retain the current WebSocket-only behavior.
final class DirectSessionTransport implements SessionTransport {
  DirectSessionTransport(this._relay) {
    // Keep the entire WebRTC peer and every callback in a guarded zone. The
    // current webrtc_dart release can start SCTP work with unawaited futures;
    // a late SACK can then raise an uncaught queue-reentrancy error outside the
    // future returned by send(). Containing the package at this boundary lets
    // the relay remain usable when the experimental direct path misbehaves.
    _directZone = Zone.current.fork(
      specification: ZoneSpecification(
        handleUncaughtError: (self, parent, zone, error, stack) {
          _handleDirectRuntimeError(error, stack);
        },
      ),
    );
    _directZone.run(() {
      _peer = DirectWebRtcPeer(
        onSignal: (signal) {
          try {
            _relay.send(signal.encode());
          } on StateError {
            // The device cannot advertise a direct offer before the relay has
            // selected a candidate, but late ICE candidates can race shutdown.
          }
        },
      );
      _peer.messages.listen(
        (frame) {
          if (!_events.isClosed) _events.add(frame);
        },
        onError: (Object error, StackTrace stack) {
          if (!_events.isClosed) _events.addError(error, stack);
          _directReady = false;
        },
      );
      _peer.connectionStates.listen((state) {
        if (state == PeerConnectionState.failed ||
            state == PeerConnectionState.disconnected ||
            state == PeerConnectionState.closed) {
          _directReady = false;
          unawaited(_peer.close());
        }
      });
      _relaySubscription = _relay.stream.listen(
        _onRelayMessage,
        onDone: _relayClosed,
        onError: (Object error, StackTrace stack) {
          if (!_events.isClosed) _events.addError(error, stack);
        },
      );
    });
  }

  final RelayRace _relay;
  final _events = StreamController<Object>();
  late final Zone _directZone;
  late final DirectWebRtcPeer _peer;
  late final StreamSubscription<Object> _relaySubscription;
  var _directReady = false;
  var _closed = false;
  var _directRuntimeErrorReported = false;
  var _directFallbackReported = false;

  Stream<Object> get stream => _events.stream;
  Future<String> get selectedRelay => _relay.selectedRelay;
  String? get closeReason => _relay.closeReason;

  void send(Object message) {
    if (_closed) throw StateError('direct session transport is closed');
    if (message is List<int> && _directReady) {
      final frame = Uint8List.fromList(message);
      // The vendored SCTP implementation serializes its transmit loop. Keep
      // the transport itself concurrent so one slow buffered frame cannot
      // hold every later VM-service request behind it.
      unawaited(_sendDirect(frame));
      return;
    }
    _relay.send(message);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _relaySubscription.cancel();
    await _peer.close();
    if (!_events.isClosed) await _events.close();
    await _relay.close();
  }

  void _handleDirectRuntimeError(Object error, StackTrace stack) {
    if (_closed) return;
    _directReady = false;
    if (!_directRuntimeErrorReported) {
      _directRuntimeErrorReported = true;
      stderr.writeln(
        '[rhr] direct WebRTC runtime failure: $error; '
        'using WebSocket fallback',
      );
    }
    // Do not rethrow: this is precisely the unawaited package failure that
    // previously terminated the CLI isolate. Closing is best effort; any
    // secondary package error is handled by this same zone.
    unawaited(_peer.close());
  }

  void _onRelayMessage(Object message) {
    final signal = _tryDecodeDirectSignal(message);
    if (signal == null) {
      if (!_events.isClosed) _events.add(message);
      return;
    }
    unawaited(_handleSignal(signal));
  }

  Future<void> _handleSignal(DirectSignal signal) async {
    switch (signal) {
      case DirectDescriptionSignal(:final type):
        if (type != 'offer') return;
        await _peer.acceptOffer(signal);
        try {
          await _peer.waitUntilOpen(timeout: const Duration(seconds: 20));
          _directReady = true;
          stderr.writeln('[rhr] direct WebRTC/STUN payload path is ready');
        } catch (_) {
          // Keep the WebSocket payload path if ICE/DTLS cannot complete.
          _directReady = false;
          stderr.writeln(
            '[rhr] direct WebRTC path unavailable; using WebSocket fallback',
          );
        }
      case DirectCandidateSignal():
        await _peer.addCandidate(signal);
      case DirectEndSignal():
        break;
    }
  }

  Future<void> _sendDirect(Uint8List frame) async {
    // Frames queued before a direct failure must immediately use the relay;
    // retrying each one against a closed/stalled SCTP channel would serialize
    // a timeout for every pending VM-service packet.
    if (!_directReady) {
      try {
        _relay.send(frame);
      } on StateError {
        // The relay can be closing at the same time as the direct peer.
      }
      return;
    }
    try {
      // A stalled SCTP association otherwise waits for its retransmission
      // timer (roughly a minute on a real phone) before the relay fallback
      // becomes usable. Direct is an optimization, so fail fast and keep
      // the VM-service request on the proven relay path.
      await _peer.send(frame).timeout(const Duration(seconds: 4));
    } catch (_) {
      _directReady = false;
      // Closing the host peer tells the Android endpoint to stop selecting
      // the stale direct channel too; its next response then uses the relay.
      unawaited(_peer.close());
      if (!_directFallbackReported) {
        _directFallbackReported = true;
        stderr.writeln(
          '[rhr] direct WebRTC payload stalled; using WebSocket fallback',
        );
      }
      try {
        _relay.send(frame);
      } on StateError {
        // The relay can be closing at the same time as the direct peer.
      }
    }
  }

  void _relayClosed() {
    _directReady = false;
    if (!_events.isClosed) unawaited(_events.close());
  }

  static DirectSignal? _tryDecodeDirectSignal(Object message) {
    if (message is! String) return null;
    try {
      final decoded = jsonDecode(message);
      if (decoded is! Map<String, dynamic>) return null;
      final type = decoded['t'];
      if (type is! String || !type.startsWith('direct_')) return null;
      return DirectSignal.decode(decoded);
    } on FormatException {
      return null;
    }
  }
}
