import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'account_auth.dart';
import 'private_file.dart';
import 'reconnect_backoff.dart';
import 'relay_config.dart';
import 'relay_race.dart';

/// The host daemon: one process per account phone that keeps the phone
/// connected to this computer whether or not a project is running.
///
/// Without it every `rhr run` was its own host. The phone went back to
/// "Waiting for your computer" between runs, its screen could sleep, and a
/// second project was refused as "busy" until the first let go.
///
/// The daemon holds the phone's relay connection: its claim, a fresh ticket
/// on every dial, and the presence pings that keep the phone "Connected" and
/// its screen on. Each `rhr run` reaches the phone through it, over loopback,
/// speaking the relay protocol it already speaks, so a run is unchanged: its
/// hello reaches the phone, and its WebRTC path is set up end to end with the
/// phone, never through here.
///
/// One run at a time has the phone. A new run takes it over; the run it took
/// it from is refused (HTTP 410) when it tries to come back, and ends.
final class HostDaemon {
  HostDaemon._(
    this.code,
    this.relay,
    this.idle,
    this._server,
    this._token,
    this._file,
    this._ticketFor,
  );

  final String code;
  final String relay;

  /// How long the daemon keeps the phone after the last run leaves.
  final Duration? idle;
  final HttpServer _server;
  final String _token;
  final File _file;
  final Future<String?> Function(String rendezvous) _ticketFor;
  final _stopped = Completer<void>();

  RelayRace? _upstream;

  /// Why runs are refused while the phone cannot be reached: a status code
  /// RelayRace understands, or null to refuse as unavailable.
  int? _refusal;

  /// The phone's latest `info`, replayed to a run that connects after it,
  /// as the relay does.
  String? _info;
  _Run? _run;
  final _supersededClaims = <String>{};
  Timer? _idleTimer;
  var _stopping = false;

  /// Serves [code] until it has been idle for [idle] (never when null), or
  /// until stopped by a signal. [file] is where it publishes itself.
  static Future<void> serve({
    required String code,
    required String relay,
    Duration? idle = const Duration(minutes: 15),
    File? file,
    Future<String?> Function(String rendezvous) ticketFor = rendezvousTicket,
    Duration keepalive = hostLeasePingInterval,
  }) async {
    file ??= hostDaemonFile(code);
    if (await liveHostDaemon(code, file: file) != null) {
      stderr.writeln('[rhr daemon] already running for $code');
      return;
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final token = base64UrlEncode(
      List<int>.generate(24, (_) => Random.secure().nextInt(256)),
    );
    final daemon = HostDaemon._(
      code,
      relay,
      idle,
      server,
      token,
      file,
      ticketFor,
    );
    writePrivateFile(
      file,
      jsonEncode({'port': server.port, 'token': token, 'pid': pid}),
    );
    stderr.writeln('[rhr daemon] serving $code on port ${server.port}');
    final signals = [
      for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm])
        signal.watch().listen((_) => daemon._stop()),
    ];
    server.listen(daemon._accept);
    daemon._armIdle();
    final pings = Timer.periodic(keepalive, (_) {
      // Before the phone has answered there is no one to ping.
      try {
        daemon._upstream?.sendControl(jsonEncode({'t': 'ping'}));
      } on StateError {
        // Not selected yet.
      }
    });
    unawaited(daemon._holdPhone());
    await daemon._stopped.future;
    pings.cancel();
    for (final signal in signals) {
      await signal.cancel();
    }
  }

  /// Keeps a relay connection to the phone open, dialling again whenever it
  /// drops, until the daemon stops.
  Future<void> _holdPhone() async {
    final backoff = ReconnectBackoff();
    while (!_stopping) {
      try {
        final upstream = await RelayRace.connect(
          relays: [relay],
          code: code,
          claimFile: File('${_file.path}.claim'),
          ticketFor: _ticketFor,
          hello: false,
        );
        _upstream = upstream;
        _refusal = null;
        backoff.markReady();
        stderr.writeln('[rhr daemon] connected to the phone\'s relay');
        await upstream.stream.forEach(_fromPhone);
        if (_stopping) return;
        stderr.writeln('[rhr daemon] relay connection closed');
      } on DevicePausedException {
        _refusal = 423;
        await Future<void>.delayed(ReconnectBackoff.pausedRetry);
        continue;
      } on DeviceBusyException catch (busy) {
        _refusal = 409;
        stderr.writeln('[rhr daemon] $busy');
      } on DeviceAccessException catch (refused) {
        stderr.writeln('[rhr daemon] $refused');
        await _stop();
        return;
      } on Object catch (error) {
        stderr.writeln('[rhr daemon] could not reach the relay: $error');
      }
      _upstream = null;
      _info = null;
      // The run's channels and WebRTC path went with the connection; it
      // dials again, as it would after any relay drop.
      await _run?.socket.close(WebSocketStatus.goingAway, 'relay reconnecting');
      if (_stopping) return;
      await Future<void>.delayed(backoff.nextDelay());
    }
  }

  void _fromPhone(Object message) {
    if (message is String && message.contains('"info"')) {
      try {
        if ((jsonDecode(message) as Map)['t'] == 'info') _info = message;
      } on Object {
        // Not JSON; forwarded as it is.
      }
    }
    _run?.socket.add(message);
  }

  Future<void> _accept(HttpRequest request) async {
    if (request.uri.path != '/s/$code/host' ||
        request.headers.value(hostDaemonTokenHeader) != _token) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    final upstream = _upstream;
    if (upstream == null || _stopping) {
      request.response.statusCode = _refusal ?? HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }
    final offered = request.headers.value('x-rhr-claim');
    final current = _run;
    final resuming = current != null && offered == current.claim;
    if (!resuming && offered != null && _supersededClaims.contains(offered)) {
      // A run another project took the phone from, trying to take it back.
      request.response.statusCode = HttpStatus.gone;
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    final run = _Run(socket, resuming ? current.claim : _newClaim());
    if (current != null) {
      if (!resuming) _supersededClaims.add(current.claim);
      await current.socket.close(4010, 'handed over to another run');
    }
    _run = run;
    _idleTimer?.cancel();
    stderr.writeln(
      resuming ? '[rhr daemon] run reconnected' : '[rhr daemon] run attached',
    );
    socket.add(jsonEncode({'t': 'claim', 'id': run.claim}));
    final info = _info;
    if (info != null) socket.add(info);
    socket.listen(
      (message) => _fromRun(run, message),
      onDone: () => _left(run),
      onError: (_) => _left(run),
    );
  }

  void _fromRun(_Run run, Object? message) {
    if (!identical(_run, run)) return;
    final upstream = _upstream;
    if (upstream == null) return;
    try {
      if (message is String) {
        // The daemon keeps the phone's claim; a run leaving gives back only
        // its own.
        if (message == '{"t":"release"}') {
          _supersededClaims.add(run.claim);
          return;
        }
        upstream.sendControl(message);
      } else if (message is List<int>) {
        unawaited(upstream.sendPayload(Uint8List.fromList(message)));
      }
    } on StateError {
      // The phone has not answered yet; the run's hello is repeated once it does.
    }
  }

  void _left(_Run run) {
    if (!identical(_run, run)) return;
    _run = null;
    stderr.writeln('[rhr daemon] run left; keeping the phone connected');
    _armIdle();
  }

  void _armIdle() {
    final idle = this.idle;
    if (idle == null || _run != null) return;
    _idleTimer?.cancel();
    _idleTimer = Timer(idle, () {
      stderr.writeln('[rhr daemon] no run for ${idle.inMinutes} min; stopping');
      unawaited(_stop());
    });
  }

  Future<void> _stop() async {
    if (_stopping) return;
    _stopping = true;
    if (_file.existsSync()) _file.deleteSync();
    final upstream = _upstream;
    if (upstream != null) {
      // Gives the phone back now, rather than after the relay's grace.
      upstream.release();
      try {
        upstream.sendControl(jsonEncode({'t': 'host_gone'}));
      } on StateError {
        // Never selected; nothing to tell.
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    await _run?.socket.close(WebSocketStatus.goingAway, 'rhr daemon stopped');
    await upstream?.close();
    await _server.close(force: true);
    if (!_stopped.isCompleted) _stopped.complete();
  }

  static String _newClaim() => base64UrlEncode(
    List<int>.generate(16, (_) => Random.secure().nextInt(256)),
  );
}

final class _Run {
  _Run(this.socket, this.claim);

  final WebSocket socket;
  final String claim;
}

/// Header a run presents to the daemon: the token from [hostDaemonFile].
const hostDaemonTokenHeader = 'x-rhr-daemon-token';

/// Where the daemon for [code] publishes its port and token, readable only
/// by this user.
File hostDaemonFile(String code) =>
    File('${accountSessionFile().parent.path}/daemon/$code.json');

/// Where the daemon for [code] started by [ensureHostDaemon] writes its log.
File hostDaemonLog(String code) =>
    File('${accountSessionFile().parent.path}/daemon/$code.log');

typedef HostDaemonAddress = ({String relay, Map<String, String> headers});

/// The daemon serving [code], if one is running and answers.
Future<HostDaemonAddress?> liveHostDaemon(String code, {File? file}) async {
  file ??= hostDaemonFile(code);
  if (!file.existsSync()) return null;
  final Object? saved;
  try {
    saved = jsonDecode(file.readAsStringSync());
  } on FormatException {
    return null;
  }
  if (saved is! Map || saved['port'] is! int || saved['token'] is! String) {
    return null;
  }
  final port = saved['port'] as int;
  try {
    // A daemon killed outright leaves its file behind.
    final probe = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(seconds: 1),
    );
    probe.destroy();
  } on SocketException {
    return null;
  }
  return (
    relay: 'ws://127.0.0.1:$port',
    headers: {hostDaemonTokenHeader: saved['token'] as String},
  );
}

/// The daemon serving [code], started in the background if none is running.
Future<HostDaemonAddress> ensureHostDaemon(
  String code, {
  required String relay,
}) async {
  final live = await liveHostDaemon(code);
  if (live != null) return live;
  final log = hostDaemonLog(code);
  ensurePrivateDirectory(log.parent);
  await Process.start(
    'sh',
    [
      '-c',
      r'exec "$0" "$@" >"$RHR_DAEMON_LOG" 2>&1 </dev/null',
      Platform.resolvedExecutable,
      Platform.script.toFilePath(),
      'daemon',
      '--code',
      code,
      '--relay',
      relay,
    ],
    environment: {'RHR_DAEMON_LOG': log.path},
    mode: ProcessStartMode.detached,
  );
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(deadline)) {
    final started = await liveHostDaemon(code);
    if (started != null) return started;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  throw HostDaemonUnavailable(log.path);
}

/// The daemon was started but never answered.
final class HostDaemonUnavailable implements Exception {
  const HostDaemonUnavailable(this.log);

  final String log;

  @override
  String toString() => 'the rhr daemon did not start; its log is $log';
}
