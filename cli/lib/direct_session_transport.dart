import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:rhr_bridge/direct_signaling.dart';
import 'package:rhr_bridge/direct_webrtc.dart';
import 'package:webrtc_dart/webrtc_dart.dart';

import 'relay_race.dart';

final class DirectTransportFailure implements Exception {
  const DirectTransportFailure(this.message);

  final String message;

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
    this.sendTimeout = const Duration(seconds: 4),
  }) {
    _payloadReady.future.ignore();
    _directZone = Zone.current.fork(
      specification: ZoneSpecification(
        handleUncaughtError: (self, parent, zone, error, stack) {
          _fail('direct WebRTC runtime failure: $error', stack);
        },
      ),
    );
    _directZone.run(() {
      _peer = DirectWebRtcPeer(
        onSignal: (signal) {
          try {
            _relay.sendControl(signal.encode());
          } on Object catch (error, stack) {
            _fail('direct signaling failed: $error', stack);
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
          _fail('direct WebRTC receive failed: $error', stack);
        },
      );
      _peer.connectionStates.listen((state) {
        if (_closed || _failure != null) return;
        if (state == PeerConnectionState.failed ||
            state == PeerConnectionState.disconnected ||
            state == PeerConnectionState.closed) {
          _fail('direct WebRTC connection ${state.name}');
        }
      });
      _relaySubscription = _relay.controlStream.listen(
        _onRelayControl,
        onDone: _relayClosed,
        onError: (Object error, StackTrace stack) {
          _fail('direct-only relay protocol failed: $error', stack);
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
  var _directReady = false;
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
    final failure = _failure;
    if (failure != null) throw failure;
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
      _fail(failure.message, stack);
      throw failure;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _offerTimer?.cancel();
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
            _fail('direct WebRTC negotiation failed: $error', stack);
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
        await _peer.acceptOffer(signal);
        await _peer.waitUntilOpen(timeout: connectionTimeout);
        if (_closed || _failure != null) return;
        _directReady = true;
        if (!_payloadReady.isCompleted) _payloadReady.complete();
        stderr.writeln('[rhr] direct WebRTC/STUN payload path is ready');
      case DirectCandidateSignal():
        await _peer.addCandidate(signal);
      case DirectEndSignal():
        break;
      case DirectErrorSignal(:final message):
        _fail('device direct transport failed: $message', null, false);
    }
  }

  void _fail(String message, [StackTrace? stack, bool notifyPeer = true]) {
    if (_closed || _failure != null) return;
    final failure = _failure = DirectTransportFailure(message);
    _directReady = false;
    _offerTimer?.cancel();
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
    _directReady = false;
    if (!_payloadReady.isCompleted) {
      _payloadReady.completeError(
        const DirectTransportFailure(
          'signaling relay closed before the direct WebRTC payload path was ready',
        ),
      );
    }
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
