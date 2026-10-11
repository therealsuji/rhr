import 'dart:async';

import 'package:test/test.dart';
import 'package:webrtc_dart/webrtc_dart.dart';

/// A DTLS handshake the other side abandons, or that its own peer closes,
/// must end as a reported failure, not as an error thrown 30 s later where
/// nothing catches it. That error killed the bridge and could kill the CLI
/// when a phone dropped off mid-handshake.
///
/// An error that escapes to the zone fails this test, so it only has to
/// outlive the handshake timeout.
void main() {
  test(
    'an abandoned handshake fails quietly, whoever closes',
    () async {
      final vanished = await _handshakeAbandoned(closeOfferer: false);
      final tornDown = await _handshakeAbandoned(closeOfferer: true);
      await Future<void>.delayed(const Duration(seconds: 33));
      expect(vanished.connectionState, PeerConnectionState.failed);
      expect(tornDown.connectionState, PeerConnectionState.closed);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

/// Connects two loopback peers and closes the answerer the moment the
/// offerer's ICE connects, before DTLS can finish. With [closeOfferer], the
/// offerer is then closed too, as a transport tears down a failed path.
Future<RTCPeerConnection> _handshakeAbandoned({
  required bool closeOfferer,
}) async {
  final offerer = RTCPeerConnection(const RtcConfiguration(iceServers: []));
  final answerer = RTCPeerConnection(const RtcConfiguration(iceServers: []));
  final abandoned = Completer<void>();
  offerer.onIceConnectionStateChange.listen((state) async {
    if (abandoned.isCompleted ||
        (state != IceConnectionState.connected &&
            state != IceConnectionState.completed)) {
      return;
    }
    abandoned.complete();
    await answerer.close();
    if (closeOfferer) await offerer.close();
  });
  final toAnswerer = <RTCIceCandidate>[];
  final toOfferer = <RTCIceCandidate>[];
  offerer.onIceCandidate.listen(toAnswerer.add);
  answerer.onIceCandidate.listen(toOfferer.add);

  await offerer.waitForReady();
  await answerer.waitForReady();
  offerer.createDataChannel('abandoned', ordered: true);
  final offer = await offerer.createOffer();
  await offerer.setLocalDescription(offer);
  await answerer.setRemoteDescription(offer);
  final answer = await answerer.createAnswer();
  await answerer.setLocalDescription(answer);
  await offerer.setRemoteDescription(answer);
  while (!abandoned.isCompleted) {
    for (final candidate in toAnswerer) {
      await answerer.addIceCandidate(candidate);
    }
    toAnswerer.clear();
    for (final candidate in toOfferer) {
      await offerer.addIceCandidate(candidate);
    }
    toOfferer.clear();
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return offerer;
}
