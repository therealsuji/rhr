import 'dart:io';

import 'package:rhr_bridge/relay_defaults.dart';
import 'package:rhr_cli/relay_race.dart';
import 'package:test/test.dart';

/// A relay that answers every upgrade with [status], as the hosted relay
/// does when it refuses a host.
Future<HttpServer> _refusingRelay(int status) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) {
    request.response
      ..statusCode = status
      ..write('refused');
    request.response.close();
  });
  return server;
}

void main() {
  test('only the public relay counts as unable to carry payloads', () {
    expect(onlyPublicRelays([defaultPublicRelay]), isTrue);
    expect(onlyPublicRelays(['wss://relay.example.com']), isFalse);
    expect(
      onlyPublicRelays(['wss://192.168.1.5:9000', defaultPublicRelay]),
      isFalse,
    );
  });

  test('a paused phone is reported as paused, not as busy', () async {
    final relay = await _refusingRelay(423);
    addTearDown(() => relay.close(force: true));
    await expectLater(
      RelayRace.connect(
        relays: ['ws://127.0.0.1:${relay.port}'],
        code: 'rhr-2345-6789-abcd',
      ),
      throwsA(isA<DevicePausedException>()),
    );
  });

  test('a phone held by another host is reported as busy', () async {
    final relay = await _refusingRelay(409);
    addTearDown(() => relay.close(force: true));
    await expectLater(
      RelayRace.connect(
        relays: ['ws://127.0.0.1:${relay.port}'],
        code: 'rhr-2345-6789-abcd',
      ),
      throwsA(
        isA<DeviceBusyException>().having(
          (e) => '$e',
          'message',
          contains('another host'),
        ),
      ),
    );
  });
}
