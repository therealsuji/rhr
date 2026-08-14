import 'dart:async';
import 'dart:typed_data';

import 'package:rhr_bridge/direct_signaling.dart';
import 'package:rhr_bridge/direct_webrtc.dart';
import 'package:test/test.dart';

void main() {
  test(
    'two peers exchange a reliable binary frame without a relay payload path',
    () async {
      late DirectWebRtcPeer offerer;
      late DirectWebRtcPeer answerer;
      final offererSignals = <DirectSignal>[];

      offerer = DirectWebRtcPeer.localOnly(
        onSignal: (signal) {
          offererSignals.add(signal);
          unawaited(_deliver(signal, answerer));
        },
      );
      answerer = DirectWebRtcPeer.localOnly(
        onSignal: (signal) => unawaited(_deliver(signal, offerer)),
      );
      addTearDown(() async {
        await offerer.close();
        await answerer.close();
      });

      await offerer.startOffer();
      await Future.wait([
        offerer.waitUntilOpen(timeout: const Duration(seconds: 10)),
        answerer.waitUntilOpen(timeout: const Duration(seconds: 10)),
      ]);

      final candidates = offererSignals.whereType<DirectCandidateSignal>();
      expect(candidates, isNotEmpty);
      expect(
        candidates,
        everyElement(
          isA<DirectCandidateSignal>()
              .having((signal) => signal.sdpMid, 'sdpMid', '0')
              .having((signal) => signal.sdpMLineIndex, 'sdpMLineIndex', 0),
        ),
      );

      final received = answerer.messages.first;
      await offerer.send(Uint8List.fromList([1, 2, 3, 4]));
      expect(await received.timeout(const Duration(seconds: 5)), [1, 2, 3, 4]);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'two peers survive a burst of payload frames',
    () async {
      late DirectWebRtcPeer offerer;
      late DirectWebRtcPeer answerer;
      final offererSignals = <DirectSignal>[];

      offerer = DirectWebRtcPeer.localOnly(
        onSignal: (signal) {
          offererSignals.add(signal);
          unawaited(_deliver(signal, answerer));
        },
      );
      answerer = DirectWebRtcPeer.localOnly(
        onSignal: (signal) => unawaited(_deliver(signal, offerer)),
      );
      addTearDown(() async {
        await offerer.close();
        await answerer.close();
      });

      await offerer.startOffer();
      await Future.wait([
        offerer.waitUntilOpen(timeout: const Duration(seconds: 10)),
        answerer.waitUntilOpen(timeout: const Duration(seconds: 10)),
      ]);

      final received = <List<int>>[];
      final subscription = answerer.messages.listen(received.add);
      addTearDown(subscription.cancel);
      final frames = List.generate(
        120,
        (index) => Uint8List.fromList(List<int>.filled(8 * 1024, index & 0xff)),
      );
      for (final frame in frames) {
        await offerer.send(frame);
      }

      await _eventually(
        () => received.length == frames.length,
        timeout: const Duration(seconds: 30),
      );
      expect(received, frames);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

Future<void> _eventually(
  bool Function() predicate, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition did not become true', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _deliver(DirectSignal signal, DirectWebRtcPeer receiver) async {
  switch (signal) {
    case DirectDescriptionSignal(:final type):
      if (type == 'offer') {
        await receiver.acceptOffer(signal);
      } else {
        await receiver.acceptAnswer(signal);
      }
    case DirectCandidateSignal():
      await receiver.addCandidate(signal);
    case DirectEndSignal():
      break;
  }
}
