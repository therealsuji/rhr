import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:rhr_cli/local_relay.dart';
import 'package:rhr_cli/relay_race.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

void main() {
  test(
    'a restarted CLI resumes its saved claim and release clears it',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'rhr-claim-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final cache = File('${directory.path}/claim.json');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final offered = <String?>[];
      server.listen((request) async {
        offered.add(request.headers.value('x-rhr-claim'));
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((_) {});
        socket.add(jsonEncode({'t': 'claim', 'id': 'test-claim'}));
        socket.add(jsonEncode({'t': 'info', 'vm': 'http://127.0.0.1:1/'}));
      });
      const code = 'rhr-claim-test';
      final relay = 'ws://127.0.0.1:${server.port}';
      Future<RelayRace> connect(String url) async {
        final race = await RelayRace.connect(
          relays: [url],
          code: code,
          claimFile: cache,
        );
        race.stream.listen((_) {});
        await race.selectedRelay;
        return race;
      }

      final first = await connect(relay);
      await first.close();
      RelayRace.releaseClaim(code);
      final second = await connect(relay);
      expect(offered, [null, 'test-claim']);
      await second.close();
      RelayRace.releaseClaim(code);
      final differentRelay = await connect('$relay/other');
      expect(offered.last, isNull);
      differentRelay.release();
      expect(cache.existsSync(), isFalse);
      await differentRelay.close();
    },
  );

  test(
    'a refused relay does not silently wait on an empty local candidate',
    () async {
      final busy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => busy.close(force: true));
      busy.listen((request) async {
        request.response.statusCode = HttpStatus.conflict;
        await request.response.close();
      });
      const code = 'rhr-refused-test';
      final local = (await LocalRelay.start(
        code,
        advertisedAddress: InternetAddress.loopbackIPv4,
      ))!;
      addTearDown(local.close);
      await expectLater(
        RelayRace.connect(
          relays: [local.loopbackUrl, 'ws://127.0.0.1:${busy.port}'],
          code: code,
        ),
        throwsA(isA<DeviceBusyException>()),
      );
    },
  );

  test(
    'hello identity is stable within an attempt and changes on reconnect',
    () async {
      const code = 'rhr-hello-identity';
      final relay = (await LocalRelay.start(
        code,
        advertisedAddress: InternetAddress.loopbackIPv4,
      ))!;
      addTearDown(relay.close);
      final device = IOWebSocketChannel.connect(
        '${relay.loopbackUrl}/s/$code/device',
      );
      addTearDown(device.sink.close);
      await device.ready;
      final hellos = device.stream
          .where((message) => message is String)
          .map(
            (message) => jsonDecode(message as String) as Map<String, dynamic>,
          )
          .where((message) => message['t'] == 'hello')
          .asBroadcastStream();
      Future<List<String>> connect() async {
        final received = hellos
            .take(2)
            .map((message) => message['connectionId'] as String)
            .toList();
        final race = await RelayRace.connect(
          relays: [relay.loopbackUrl],
          code: code,
        );
        final events = race.stream.listen((_) {});
        device.sink.add(jsonEncode({'t': 'info', 'vm': 'http://127.0.0.1:1/'}));
        await race.selectedRelay;
        final ids = await received.timeout(const Duration(seconds: 5));
        await race.close();
        await events.cancel();
        return ids;
      }

      final first = await connect();
      final second = await connect();
      expect(first.toSet(), hasLength(1));
      expect(second.toSet(), hasLength(1));
      expect(first.first, isNotEmpty);
      expect(second.first, isNot(first.first));
    },
  );

  test(
    'reconnecting developer receives info after other phone messages',
    () async {
      final relay = (await LocalRelay.start(
        'rhr-test-reconnect',
        advertisedAddress: InternetAddress.loopbackIPv4,
      ))!;
      addTearDown(relay.close);
      final device = await WebSocket.connect(
        '${relay.loopbackUrl}/s/${relay.sessionCode}/device',
      );
      addTearDown(device.close);
      final firstDev = await WebSocket.connect(
        '${relay.loopbackUrl}/s/${relay.sessionCode}/dev',
      );
      addTearDown(firstDev.close);
      const info = '{"t":"info","vm":"http://127.0.0.1:1234/"}';
      const pong = '{"t":"pong"}';
      final receivedPong = firstDev.firstWhere((message) => message == pong);
      device.add(info);
      device.add('{"t":"progress","phase":"installed"}');
      device.add('invalid control message');
      device.add(pong);
      await receivedPong.timeout(const Duration(seconds: 3));
      await firstDev.close();

      final reconnected = await WebSocket.connect(
        '${relay.loopbackUrl}/s/${relay.sessionCode}/dev',
      );
      addTearDown(reconnected.close);
      expect(await reconnected.first.timeout(const Duration(seconds: 3)), info);
    },
  );

  test(
    'embedded relay pipes device and dev frames in both directions',
    () async {
      final relay = await LocalRelay.start(
        'rhr-test-2345-6789',
        advertisedAddress: InternetAddress.loopbackIPv4,
      );
      addTearDown(() => relay?.close());
      expect(relay, isNotNull);

      final device = IOWebSocketChannel.connect(
        '${relay!.loopbackUrl}/s/${relay.sessionCode}/device',
      );
      final dev = IOWebSocketChannel.connect(
        '${relay.loopbackUrl}/s/${relay.sessionCode}/dev',
      );
      addTearDown(device.sink.close);
      addTearDown(dev.sink.close);
      await Future.wait([device.ready, dev.ready]);

      final devMessage = dev.stream.first;
      device.sink.add(jsonEncode({'t': 'info', 'vm': 'http://127.0.0.1:1/'}));
      expect(await devMessage, contains('"t":"info"'));

      final deviceMessage = device.stream.first;
      dev.sink.add([1, 2, 3]);
      expect(await deviceMessage, [1, 2, 3]);
    },
  );

  test('relay race selects the candidate that has a device', () async {
    const code = 'rhr-test-2345-6789';
    final emptyRelay = await LocalRelay.start(
      code,
      advertisedAddress: InternetAddress.loopbackIPv4,
    );
    final deviceRelay = await LocalRelay.start(
      code,
      advertisedAddress: InternetAddress.loopbackIPv4,
    );
    addTearDown(() => emptyRelay?.close());
    addTearDown(() => deviceRelay?.close());

    final race = await RelayRace.connect(
      relays: [emptyRelay!.loopbackUrl, deviceRelay!.loopbackUrl],
      code: code,
    );
    addTearDown(race.close);
    final device = IOWebSocketChannel.connect(
      '${deviceRelay.loopbackUrl}/s/$code/device',
    );
    addTearDown(device.sink.close);
    await device.ready;
    device.sink.add(jsonEncode({'t': 'info', 'vm': 'http://127.0.0.1:1/'}));

    expect(await race.selectedRelay, deviceRelay.loopbackUrl);
    expect(await race.stream.first, contains('"t":"info"'));

    final received = device.stream.firstWhere(
      (message) => message is List<int>,
    );
    await race.sendPayload(Uint8List.fromList([4, 5, 6]));
    expect(await received, [4, 5, 6]);
  });

  test(
    'replaced relay sockets do not retain completed subscriptions',
    () async {
      final relay = await LocalRelay.start(
        'rhr-test-replacements',
        advertisedAddress: InternetAddress.loopbackIPv4,
      );
      addTearDown(() => relay?.close());
      expect(relay, isNotNull);
      final runningRelay = relay!;

      final sockets = <IOWebSocketChannel>[];
      for (var i = 0; i < 4; i++) {
        final device = IOWebSocketChannel.connect(
          '${runningRelay.loopbackUrl}/s/${runningRelay.sessionCode}/device',
        );
        final dev = IOWebSocketChannel.connect(
          '${runningRelay.loopbackUrl}/s/${runningRelay.sessionCode}/dev',
        );
        sockets.addAll([device, dev]);
        await Future.wait([device.ready, dev.ready]);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(runningRelay.activeSubscriptionCount, 2);
      }

      for (final socket in sockets) {
        await socket.sink.close();
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(runningRelay.activeSubscriptionCount, 0);
    },
  );
}
