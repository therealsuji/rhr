import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';

abstract interface class RelayControlTransport {
  Stream<String> get controlStream;
  Future<String> get selectedRelay;
  String? get closeReason;
  void sendControl(String message);
  Future<void> close();
}

/// The reason a relay gives when it closes a socket that sent a binary
/// frame (close code 4002). The public relay carries signalling text only;
/// bulk data (the VM tunnel, player and app updates) rides direct WebRTC.
const relayBinaryRefusal = 'binary payload disabled';

/// What to tell the developer when [relayBinaryRefusal] ends a session.
const relayBinaryUnsupported =
    'this relay does not carry tunnel or update payloads, only signalling. '
    'Remove --no-direct so bulk data rides the direct WebRTC path, or use a '
    'private relay started with RHR_ALLOW_BINARY_PAYLOADS=1.';

abstract interface class SessionTransport {
  Stream<Object> get stream;
  Future<String> get selectedRelay;
  Future<void> get payloadReady;
  String? get closeReason;
  void sendControl(String message);
  Future<void> sendPayload(Uint8List message);
  Future<void> close();
}

/// Thrown when the relay refuses because another developer holds the device.
///
/// Distinct from an ordinary connect failure: retrying will not help until the
/// holder disconnects, so the CLI reports it instead of looping.
final class DeviceBusyException implements Exception {
  const DeviceBusyException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Connects the dev end to several relay candidates and selects the first one
/// that produces a device `info` message.
///
/// It forwards messages only from the candidate that first announces device
/// info and closes the remaining candidates once that winner is selected.
final class RelayRace implements RelayControlTransport, SessionTransport {
  RelayRace._(this._code, this._claimFile);

  final File? _claimFile;

  /// The session this race is for, so a granted claim is filed under it.
  final String _code;

  // Repeated hellos share an identity; a reconnect must replace the old peer.
  final _hello = jsonEncode({
    't': 'hello',
    'connectionId': base64UrlEncode(
      List<int>.generate(16, (_) => Random.secure().nextInt(256)),
    ),
  });

  /// Header naming the claim being resumed, and carrying the granted one back.
  static const _claimHeader = 'x-rhr-claim';

  /// Claims this process holds, by relay and session code.
  ///
  /// Static because a reconnect builds a fresh RelayRace: the recovery loop
  /// must re-dial as the incumbent rather than as a stranger asking for a
  /// phone it already has. The relay and code prevent a claim from being
  /// offered to another server or session.
  static final _claims = <(String, String), String>{};

  /// Forgets the claim for [code], so the next connect asks for a new one.
  ///
  /// Local bookkeeping only: [release] is what tells the relay to hand the
  /// device back before the grace period runs out.
  static void releaseClaim(String code) =>
      _claims.removeWhere((key, _) => key.$2 == code);

  /// Tells the relay this session is over on purpose, so the next developer
  /// takes the device immediately instead of waiting out a grace period meant
  /// for a CLI that crashed.
  void release() {
    releaseClaim(_code);
    final file = _claimFile;
    if (file != null && file.existsSync()) file.deleteSync();
    if (_closed) return;
    try {
      sendControl('{"t":"release"}');
    } catch (_) {
      // A socket already gone releases the claim by its own timeout.
    }
  }

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
    File? claimFile,
  }) async {
    final race = RelayRace._(code, claimFile);
    final uniqueRelays = relays.toSet();
    final refusals = <String>[];
    await Future.wait(
      uniqueRelays.map(
        (relay) => race._connectCandidate(relay, code, refusals),
      ),
    );
    if (refusals.isNotEmpty) {
      final drain = race.stream.listen((_) {});
      await race.close();
      await drain.cancel();
      throw DeviceBusyException(refusals.first);
    }
    if (race._candidates.isEmpty) {
      throw StateError('could not connect to any relay candidate');
    }
    for (final candidate in race._candidates) {
      candidate.channel.sink.add(race._hello);
    }
    return race;
  }

  Future<void> _connectCandidate(
    String relay,
    String code,
    List<String> refusals,
  ) async {
    var claim = _claims[(relay, code)];
    final file = _claimFile;
    if (claim == null && file != null && file.existsSync()) {
      try {
        final saved = jsonDecode(file.readAsStringSync());
        if (saved is Map<String, dynamic> &&
            saved['code'] == code &&
            saved['relay'] == relay &&
            saved['id'] is String) {
          claim = saved['id'] as String;
        }
      } on FormatException {
        // An incomplete cache cannot authorize resuming a claim.
      }
    }
    // dart:io's WebSocket rather than IOWebSocketChannel.connect: a refused
    // claim comes back as an HTTP 409, and only this surfaces the status
    // instead of a bare "connection failed".
    WebSocket? socket;
    try {
      socket = await WebSocket.connect(
        '$relay/s/$code/dev',
        headers: claim == null ? null : {_claimHeader: claim},
      ).timeout(const Duration(seconds: 8));
    } catch (e) {
      // The relay refuses a claim someone else holds with 409; anything else
      // is an ordinary unreachable-relay failure and stays silent, because a
      // race across several candidates expects some of them to fail.
      final text = '$e';
      if (text.contains('409')) refusals.add(_busyReason(text));
      return;
    }
    socket.pingInterval = const Duration(seconds: 20);
    final channel = IOWebSocketChannel(socket);
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

  /// Reads the claim id out of the relay's `{"t":"claim","id":..}` frame.
  static String? _readClaim(String message) {
    try {
      final decoded = jsonDecode(message);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['t'] != 'claim') return null;
      final id = decoded['id'];
      return id is String ? id : null;
    } on FormatException {
      return null;
    }
  }

  /// The relay's own words where they survive, otherwise a plain sentence.
  ///
  /// dart:io reports the refusal as "not upgraded to websocket, HTTP status
  /// code: 409" and drops the response body, so the relay's specific reason is
  /// usually gone by the time it reaches here.
  static String _busyReason(String raw) {
    final marker = raw.indexOf('busy:');
    return marker == -1
        ? 'this device is in use by another developer'
        : raw.substring(marker);
  }

  void _onMessage(_RelayCandidate candidate, Object message) {
    if (message is String && message.contains('"claim"')) {
      final granted = _readClaim(message);
      if (granted != null) {
        _claims[(candidate.relay, _code)] = granted;
        final file = _claimFile;
        if (file != null) {
          file.parent.createSync(recursive: true);
          file.writeAsStringSync(
            jsonEncode({
              'code': _code,
              'relay': candidate.relay,
              'id': granted,
            }),
            flush: true,
          );
          if (!Platform.isWindows) Process.runSync('chmod', ['600', file.path]);
        }
      }
      return;
    }
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
