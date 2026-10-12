// rhr relay: pairs a device bridge and a host CLI by session code and pipes
// text control messages between them. Binary tunnel payloads are rejected:
// they belong on the direct WebRTC data channel.
//
// Endpoints:
//   GET /s/<code>/device   — device bridge dials out here
//   GET /s/<code>/host     — host CLI connects here
//   GET /healthz
//
// The relay never parses tunnel frames. The one exception: the most recent
// TEXT frame from the device (the bridge's "info" hello carrying the VM
// service URI) is cached and replayed to a host that connects later, so
// connection order doesn't matter.
//
// It speaks plain ws and binds loopback by default. A session code grants the
// phone's VM service, so off this machine it must sit behind a TLS proxy;
// RHR_RELAY_BIND=0.0.0.0 opens it to the network for exactly that setup.

import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final sessions = <String, Session>{};
const maxControlMessageBytes = 64 * 1024;

/// The shape the CLI mints (bridge/lib/session_code.dart). Anything shorter
/// or hand-picked is guessable, and a session code is a bearer credential.
final sessionCodePattern = RegExp(
  r'^rhr-[2-9a-hjkmnp-z]{4}-[2-9a-hjkmnp-z]{4}-[2-9a-hjkmnp-z]{4}$',
);

class Session {
  Session({this.onEmpty, this.allowBinaryPayloads = false});

  final void Function()? onEmpty;
  final bool allowBinaryPayloads;
  WebSocketChannel? device;
  WebSocketChannel? host;
  String? lastDeviceInfo;

  void pipeDevice(WebSocketChannel ch) {
    device?.sink.close(4001, 'replaced by new connection');
    device = ch;
    ch.stream.listen(
      (msg) {
        if (!allowBinaryPayloads && msg is! String) {
          stderr.writeln('[relay] rejected binary payload from device');
          ch.sink.close(4002, 'binary payload disabled');
          return;
        }
        if (msg is String && utf8.encode(msg).length > maxControlMessageBytes) {
          stderr.writeln(
            '[relay] rejected oversized control message from device',
          );
          ch.sink.close(4003, 'control message too large');
          return;
        }
        if (_isInfoMessage(msg)) lastDeviceInfo = msg;
        host?.sink.add(msg);
      },
      onDone: () => _deviceClosed(ch),
      onError: (_) => _deviceClosed(ch),
    );
    final info = lastDeviceInfo;
    if (info != null && host != null) host!.sink.add(info);
  }

  void pipeHost(WebSocketChannel ch) {
    host = ch;
    ch.stream.listen(
      (msg) {
        if (!allowBinaryPayloads && msg is! String) {
          stderr.writeln('[relay] rejected binary payload from host');
          ch.sink.close(4002, 'binary payload disabled');
          return;
        }
        if (msg is String && utf8.encode(msg).length > maxControlMessageBytes) {
          stderr.writeln(
            '[relay] rejected oversized control message from host',
          );
          ch.sink.close(4003, 'control message too large');
          return;
        }
        device?.sink.add(msg);
      },
      onDone: () => _hostClosed(ch),
      onError: (_) => _hostClosed(ch),
    );
    final info = lastDeviceInfo;
    if (info != null) ch.sink.add(info);
  }

  void _deviceClosed(WebSocketChannel ch) {
    stderr.writeln('[relay] device channel done');
    // A dead device's info is worse than none: a host attaching later would
    // tunnel to a VM service port that no longer exists.
    if (device == ch) {
      device = null;
      lastDeviceInfo = null;
      // The session is dead without a device: drop the host too so the
      // CLI's recovery loop re-dials and re-pairs when the device returns.
      host?.sink.close(4000, 'device disconnected');
      host = null;
      _maybeEvict();
    }
  }

  void _hostClosed(WebSocketChannel ch) {
    if (host == ch) {
      host = null;
      _maybeEvict();
    }
  }

  void _maybeEvict() {
    if (device == null && host == null && lastDeviceInfo == null)
      onEmpty?.call();
  }
}

bool _isInfoMessage(Object message) {
  if (message is! String) return false;
  try {
    final decoded = jsonDecode(message);
    return decoded is Map && decoded['t'] == 'info';
  } on FormatException {
    return false;
  }
}

Session _sessionFor(String code, {bool allowBinaryPayloads = false}) {
  final existing = sessions[code];
  if (existing != null) return existing;
  late final Session created;
  created = Session(
    allowBinaryPayloads: allowBinaryPayloads,
    onEmpty: () {
      if (identical(sessions[code], created)) sessions.remove(code);
    },
  );
  sessions[code] = created;
  return created;
}

Future<HttpServer> startRelay(
  int port, {
  bool allowBinaryPayloads = false,
  Object address = '127.0.0.1',
}) async {
  final handler = (Request req) {
    final seg = req.url.pathSegments;
    if (seg.length == 1 && seg[0] == 'healthz') return Response.ok('ok');
    if (seg.length == 3 && seg[0] == 's') {
      final code = seg[1];
      final role = seg[2];
      if (role != 'device' && role != 'host')
        return Response.notFound('bad role');
      if (!sessionCodePattern.hasMatch(code)) {
        return Response(HttpStatus.badRequest, body: 'not a session code');
      }
      if (req.headers['origin'] != null) {
        return Response.forbidden('browser clients not allowed');
      }
      // One host per phone: a second is refused rather than allowed to
      // evict the first, as on the hosted relay.
      if (role == 'host' && sessions[code]?.host != null) {
        return Response(
          HttpStatus.conflict,
          body: 'busy: another host is connected to this device',
        );
      }
      return webSocketHandler((WebSocketChannel ws, _) {
        final s = _sessionFor(code, allowBinaryPayloads: allowBinaryPayloads);
        stderr.writeln('[relay] $role connected');
        role == 'device' ? s.pipeDevice(ws) : s.pipeHost(ws);
      })(req);
    }
    return Response.notFound('not found');
  };

  return shelf_io.serve(handler, address, port);
}

Future<void> main(List<String> args) async {
  final port = int.parse(
    args.isNotEmpty ? args[0] : Platform.environment['PORT'] ?? '8123',
  );
  final address = Platform.environment['RHR_RELAY_BIND'] ?? '127.0.0.1';
  final server = await startRelay(
    port,
    allowBinaryPayloads:
        Platform.environment['RHR_ALLOW_BINARY_PAYLOADS'] == '1',
    address: address,
  );
  stderr.writeln('[relay] listening on $address:${server.port}');
}
