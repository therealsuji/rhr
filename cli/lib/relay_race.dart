import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';

import 'package:rhr_bridge/session_code.dart';

import 'account_auth.dart';
import 'private_file.dart';

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

/// What to tell the user when [relayBinaryRefusal] ends a session.
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

/// Thrown when the relay refuses because another host holds the device.
///
/// Distinct from an ordinary connect failure: retrying will not help until the
/// holder disconnects, so the CLI reports it instead of looping.
final class DeviceBusyException implements Exception {
  const DeviceBusyException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Thrown when the account service will not let this user reach a
/// device's rendezvous: signed out, or the device left the account.
///
/// Retrying cannot fix it, so the caller ends rather than looping.
final class DeviceAccessException implements Exception {
  const DeviceAccessException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Connects the host end to several relay candidates and selects the first one
/// that produces a device `info` message.
///
/// It forwards messages only from the candidate that first announces device
/// info and closes the remaining candidates once that winner is selected.
final class RelayRace implements RelayControlTransport, SessionTransport {
  RelayRace._(this._code, this._claimFile);

  final File? _claimFile;

  /// The session this race is for, so a granted claim is filed under it.
  final String _code;

  /// This connection's identity. Repeated hellos share it; a reconnect gets a
  /// new one, which is how the device knows to replace the old peer.
  final connectionId = base64UrlEncode(
    List<int>.generate(16, (_) => Random.secure().nextInt(256)),
  );
  late final _hello = jsonEncode({'t': 'hello', 'connectionId': connectionId});

  /// Hands a relay's claim back before its grace period runs out.
  static const _release = '{"t":"release"}';

  /// Header naming the claim being resumed, and carrying the granted one back.
  static const _claimHeader = 'x-rhr-claim';

  /// Header carrying the account service's ticket for a rendezvous.
  static const _ticketHeader = 'x-rhr-ticket';

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

  /// Tells the relay this session is over on purpose, so the next host
  /// takes the device immediately instead of waiting out a grace period meant
  /// for a CLI that crashed.
  void release() {
    releaseClaim(_code);
    final file = _claimFile;
    if (file != null && file.existsSync()) file.deleteSync();
    if (_closed) return;
    // Before a winner, every candidate relay admitted this host and
    // holds a claim for it.
    final winner = _winner;
    for (final candidate in winner == null ? _candidates : [winner]) {
      if (!candidate.closed) candidate.channel.sink.add(_release);
    }
  }

  final _events = StreamController<Object>();
  final _selected = Completer<String>();
  final _candidates = <_RelayCandidate>[];
  _RelayCandidate? _winner;
  bool _ticketRefused = false;
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
    Future<String?> Function(String rendezvous) ticketFor = rendezvousTicket,
  }) async {
    // A rendezvous is a public name; the relay admits a developer to it only
    // with a ticket, and tickets are short-lived, so each dial asks afresh.
    String? ticket;
    if (rhrRendezvousInstallation(code) != null) {
      ticket = await ticketFor(code);
      if (ticket == null) {
        throw const DeviceAccessException(
          'this device is not on your account, or you are signed out. '
          'Run `rhr devices` to check.',
        );
      }
    }
    final race = RelayRace._(code, claimFile);
    final uniqueRelays = relays.toSet();
    final refusals = <String>[];
    await Future.wait(
      uniqueRelays.map(
        (relay) => race._connectCandidate(
          relay,
          code,
          refusals,
          // Only the account service can check a ticket, so no other relay
          // in the race is handed one to replay.
          ticket: relayIsService(relay, accountService()) ? ticket : null,
        ),
      ),
    );
    if (refusals.isNotEmpty || race._ticketRefused) {
      // The relays that admitted us each hold a claim this run will not use.
      for (final candidate in race._candidates) {
        if (!candidate.closed) candidate.channel.sink.add(_release);
      }
      final drain = race.stream.listen((_) {});
      await race.close();
      await drain.cancel();
      if (race._ticketRefused) {
        throw const DeviceAccessException(
          'the account service refused this device ticket. '
          'Run `rhr devices` to check.',
        );
      }
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
    List<String> refusals, {
    String? ticket,
  }) async {
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
        '$relay/s/$code/host',
        headers: {_claimHeader: ?claim, _ticketHeader: ?ticket},
      ).timeout(const Duration(seconds: 8));
    } catch (e) {
      // The relay refuses a claim someone else holds with 409; anything else
      // is an ordinary unreachable-relay failure and stays silent, because a
      // race across several candidates expects some of them to fail.
      final text = '$e';
      if (text.contains('409')) refusals.add(_busyReason(text));
      // A ticket the account service refused will be refused again; waiting
      // on the other candidates would hang on a phone that never arrives.
      if (ticket != null && text.contains('401')) _ticketRefused = true;
      return;
    }
    socket.pingInterval = const Duration(seconds: 20);
    final channel = IOWebSocketChannel(socket);
    if (_closed || _winner != null) {
      // Admitted too late to matter; its claim would still hold the device.
      channel.sink.add(_release);
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
        ? 'this device is in use by another host'
        : raw.substring(marker);
  }

  void _onMessage(_RelayCandidate candidate, Object message) {
    if (message is String && message.contains('"claim"')) {
      final granted = _readClaim(message);
      if (granted != null) {
        _claims[(candidate.relay, _code)] = granted;
        final file = _claimFile;
        if (file != null) {
          writePrivateFile(
            file,
            jsonEncode({
              'code': _code,
              'relay': candidate.relay,
              'id': granted,
            }),
          );
        }
      }
      return;
    }
    if (_winner == null) {
      if (!_isDeviceInfo(message)) return;
      _winner = candidate;
      if (!_selected.isCompleted) _selected.complete(candidate.relay);
      // The initial hello may have crossed the relay before the device
      // connected. Repeat it after the cached info arrives so a host-first
      // pairing can still trigger optional device-side upgrades (such as
      // direct WebRTC signaling).
      candidate.channel.sink.add(_hello);
      // A loser's claim is dead weight: left alone, its relay would hold the
      // device for a grace period and refuse this host's next run.
      for (final loser in _candidates.where(
        (item) => item != candidate && !item.closed,
      )) {
        loser.channel.sink.add(_release);
        unawaited(loser.channel.sink.close());
        loser.closed = true;
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
