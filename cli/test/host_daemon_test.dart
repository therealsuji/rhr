import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rhr_cli/host_daemon.dart';
import 'package:rhr_cli/relay_race.dart';
import 'package:test/test.dart';

const code = 'dev-AAAAAAAAAAAAAAAAAAAAAA';

/// A relay with the phone already on it: answers every host with the
/// phone's info and records what hosts send.
final class FakeRelay {
  FakeRelay._(this._server) {
    _server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(jsonEncode({'t': 'info', 'vm': 'http://127.0.0.1:1/'}));
      socket.listen((message) {
        if (message is String) received.add(jsonDecode(message) as Map);
      });
    });
  }

  static Future<FakeRelay> start() async =>
      FakeRelay._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final received = <Map>[];

  String get url => 'ws://127.0.0.1:${_server.port}';

  Future<void> close() => _server.close(force: true);
}

Future<String?> _ticket(String _) async => 'ticket';

void main() {
  late Directory state;
  late FakeRelay relay;
  late File daemonFile;
  late HostDaemonAddress daemon;

  setUp(() async {
    state = Directory.systemTemp.createTempSync('rhr_daemon_');
    relay = await FakeRelay.start();
    daemonFile = File('${state.path}/daemon.json');
    unawaited(
      HostDaemon.serve(
        code: code,
        relay: relay.url,
        idle: null,
        file: daemonFile,
        ticketFor: _ticket,
        keepalive: const Duration(milliseconds: 50),
      ),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    HostDaemonAddress? live;
    while (live == null && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      live = await liveHostDaemon(code, file: daemonFile);
    }
    daemon = live!;
  });

  tearDown(() async {
    RelayRace.releaseClaim(code);
    await relay.close();
    state.deleteSync(recursive: true);
  });

  Future<RelayRace> attach(String name) {
    // Each run is its own process, holding only the claim in its own file.
    RelayRace.releaseClaim(code);
    return RelayRace.connect(
      relays: [daemon.relay],
      code: code,
      claimFile: File('${state.path}/$name.claim'),
      ticketFor: _ticket,
      headers: daemon.headers,
    );
  }

  test('keeps the phone connected with no run attached', () async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(relay.received.where((m) => m['t'] == 'ping'), isNotEmpty);
    // The daemon is a pass-through: it never starts a direct path itself.
    expect(relay.received.where((m) => m['t'] == 'hello'), isEmpty);
  });

  test('a run reaches the phone through the daemon', () async {
    final run = await attach('a');
    final info = await run.stream.first.timeout(const Duration(seconds: 5));
    expect(jsonDecode(info as String)['t'], 'info');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(
      relay.received.where(
        (m) => m['t'] == 'hello' && m['connectionId'] == run.connectionId,
      ),
      isNotEmpty,
    );
    // Leaving gives back the run's claim, not the phone's.
    run.release();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(relay.received.where((m) => m['t'] == 'release'), isEmpty);
    await run.close();
  });

  test('a second project takes the phone, and the first cannot take it back',
      () async {
    final first = await attach('a');
    final firstEnded = first.stream.drain<void>();
    await (await attach('b')).selectedRelay;

    await firstEnded.timeout(const Duration(seconds: 5));
    // The first run's process holds only its own claim.
    RelayRace.releaseClaim(code);
    final comeback = RelayRace.connect(
      relays: [daemon.relay],
      code: code,
      claimFile: File('${state.path}/a.claim'),
      ticketFor: _ticket,
      headers: daemon.headers,
    );
    await expectLater(comeback, throwsA(isA<DeviceHandedOverException>()));
  });

  test('refuses a local process without the token', () async {
    await expectLater(
      WebSocket.connect('${daemon.relay}/s/$code/host'),
      throwsA(isA<WebSocketException>()),
    );
  });
}
