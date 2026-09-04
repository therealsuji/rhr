import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';

abstract interface class RelayControlTransport {
  Stream<String> get controlStream;
  Future<String> get selectedRelay;
  String? get closeReason;
  void sendControl(String message);
  Future<void> close();
}

abstract interface class SessionTransport {
  Stream<Object> get stream;
  Future<String> get selectedRelay;
  Future<void> get payloadReady;
  String? get closeReason;
  void sendControl(String message);
  Future<void> sendPayload(Uint8List message);
  Future<void> close();
}

/// Connects the dev end to several relay candidates and selects the first one
/// that produces a device `info` message.
///
/// It forwards messages only from the candidate that first announces device
/// info and closes the remaining candidates once that winner is selected.
final class RelayRace implements RelayControlTransport, SessionTransport {
  RelayRace._();

  static const _hello = '{"t":"hello"}';

  final _events = StreamController<Object>();
  final _selected = Completer<String>();
  final _candidates = <_RelayCandidate>[];
  _RelayCandidate? _winner;
  var _closed = false;

  Stream<Object> get stream => _events.stream;
  Stream<String> get controlStream => _events.stream.map((message) {
    if (message is String) return message;
    throw const FormatException(
      'relay sent binary payload during a direct-only session',
    );
  });
  Future<String> get selectedRelay => _selected.future;
  Future<void> get payloadReady => Future.value();
  String? get closeReason => _winner?.channel.closeReason;

  static Future<RelayRace> connect({
    required List<String> relays,
    required String code,
  }) async {
    final race = RelayRace._();
    final uniqueRelays = relays.toSet();
    await Future.wait(
      uniqueRelays.map((relay) => race._connectCandidate(relay, code)),
    );
    if (race._candidates.isEmpty) {
      throw StateError('could not connect to any relay candidate');
    }
    for (final candidate in race._candidates) {
      candidate.channel.sink.add(_hello);
    }
    return race;
  }

  Future<void> _connectCandidate(String relay, String code) async {
    final channel = IOWebSocketChannel.connect(
      '$relay/s/$code/dev',
      pingInterval: const Duration(seconds: 20),
    );
    try {
      await channel.ready.timeout(const Duration(seconds: 8));
    } catch (_) {
      await channel.sink.close();
      return;
    }
    if (_closed || _winner != null) {
      await channel.sink.close();
      return;
    }
    final candidate = _RelayCandidate(relay, channel);
    _candidates.add(candidate);
    candidate.subscription = channel.stream.listen(
      (message) => _onMessage(candidate, message),
      onDone: () => _onClosed(candidate),
      onError: (_) => _onClosed(candidate),
    );
  }

  void _onMessage(_RelayCandidate candidate, Object message) {
    if (_winner == null) {
      if (!_isDeviceInfo(message)) return;
      _winner = candidate;
      if (!_selected.isCompleted) _selected.complete(candidate.relay);
      // The initial hello may have crossed the relay before the device
      // connected. Repeat it after the cached info arrives so a dev-first
      // pairing can still trigger optional device-side upgrades (such as
      // direct WebRTC signaling).
      candidate.channel.sink.add(_hello);
      for (final loser in _candidates.where((item) => item != candidate)) {
        unawaited(loser.channel.sink.close());
      }
    }
    if (identical(_winner, candidate) && !_events.isClosed) {
      _events.add(message);
    }
  }

  static bool _isDeviceInfo(Object message) {
    if (message is! String) return false;
    try {
      final decoded = jsonDecode(message);
      return decoded is Map<String, dynamic> && decoded['t'] == 'info';
    } on FormatException {
      return false;
    }
  }

  void _onClosed(_RelayCandidate candidate) {
    if (candidate.closed) return;
    candidate.closed = true;
    if (identical(_winner, candidate)) {
      if (!_events.isClosed) unawaited(_events.close());
      return;
    }
    if (_winner == null && _candidates.every((item) => item.closed)) {
      if (!_selected.isCompleted) {
        _selected.completeError(StateError('all relay candidates closed'));
      }
      if (!_events.isClosed) unawaited(_events.close());
    }
  }

  void sendControl(String message) => _send(message);

  Future<void> sendPayload(Uint8List message) async => _send(message);

  void _send(Object message) {
    final winner = _winner;
    if (winner == null) {
      throw StateError('no relay transport has been selected yet');
    }
    winner.channel.sink.add(message);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final candidate in _candidates) {
      await candidate.subscription?.cancel();
      await candidate.channel.sink.close();
    }
    if (!_events.isClosed) await _events.close();
  }
}

final class _RelayCandidate {
  _RelayCandidate(this.relay, this.channel);

  final String relay;
  final IOWebSocketChannel channel;
  StreamSubscription<Object?>? subscription;
  bool closed = false;
}
