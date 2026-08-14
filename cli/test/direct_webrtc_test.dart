import 'dart:typed_data';

import 'package:rhr_bridge/direct_signaling.dart';
import 'package:rhr_bridge/direct_webrtc.dart';
import 'package:test/test.dart';

void main() {
  test('peer rejects sending before negotiation', () async {
    final peer = DirectWebRtcPeer(onSignal: (_) {});
    addTearDown(peer.close);

    await expectLater(
      peer.send(Uint8List.fromList([1, 2, 3])),
      throwsStateError,
    );
  });

  test('candidate is buffered until a remote description exists', () async {
    final peer = DirectWebRtcPeer(onSignal: (_) {});
    addTearDown(peer.close);

    // A candidate is syntactically valid but cannot be applied until SDP has
    // selected the peer's media section. This must not throw synchronously.
    await peer.addCandidate(
      const DirectCandidateSignal(
        candidate: 'candidate:1 1 udp 1 127.0.0.1 9 typ host',
      ),
    );
  });
}
