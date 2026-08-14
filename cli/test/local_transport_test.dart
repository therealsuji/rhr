import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rhr_cli/local_relay.dart';
import 'package:rhr_cli/relay_race.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

void main() {
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
    race.send([4, 5, 6]);
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
