import 'dart:async';

import 'package:test/test.dart';
import 'package:webrtc_dart/webrtc_dart.dart';

/// The DTLS peer is authenticated by its certificate matching the
/// a=fingerprint in the SDP. If signaling hands one side a fingerprint that is
/// not the peer's, as a man in the middle presenting its own certificate
/// would, the handshake must fail on that side instead of connecting.
void main() {
  test('peers with matching fingerprints connect', () async {
    final (offerer, answerer) = await _connect();
    await expectLater(
      _settled(offerer),
      completion(PeerConnectionState.connected),
    );
    await expectLater(
      _settled(answerer),
      completion(PeerConnectionState.connected),
    );
  }, timeout: const Timeout(Duration(seconds: 30)));

  test(
      'the DTLS server rejects a client whose certificate is not in the answer',
      () async {
    // The answerer is the DTLS client (setup:active); the offerer checks it.
    final (offerer, _) = await _connect(tamperAnswer: true);
    await expectLater(
      _settled(offerer),
      completion(PeerConnectionState.failed),
    );
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('the DTLS client rejects a server whose certificate is not in the offer',
      () async {
    final (_, answerer) = await _connect(tamperOffer: true);
    await expectLater(
      _settled(answerer),
      completion(PeerConnectionState.failed),
    );
  }, timeout: const Timeout(Duration(seconds: 30)));
}

/// Swaps every a=fingerprint value for one no certificate here hashes to.
RTCSessionDescription _withForeignFingerprint(RTCSessionDescription d) =>
    RTCSessionDescription(
      type: d.type,
      sdp: d.sdp.replaceAllMapped(
        RegExp(r'(a=fingerprint:sha-256 )[0-9A-Fa-f:]+'),
        (m) => '${m[1]}${List.filled(32, 'AB').join(':')}',
      ),
    );

/// The first state past connecting.
Future<PeerConnectionState> _settled(RTCPeerConnection peer) async {
  const pending = {PeerConnectionState.new_, PeerConnectionState.connecting};
  if (!pending.contains(peer.connectionState)) return peer.connectionState;
  return peer.onConnectionStateChange
      .firstWhere((state) => !pending.contains(state))
      .timeout(const Duration(seconds: 20));
}

Future<(RTCPeerConnection, RTCPeerConnection)> _connect({
  bool tamperOffer = false,
  bool tamperAnswer = false,
}) async {
  final offerer = RTCPeerConnection(const RtcConfiguration(iceServers: []));
  final answerer = RTCPeerConnection(const RtcConfiguration(iceServers: []));
  addTearDown(() async {
    await offerer.close();
    await answerer.close();
  });
  // Candidates wait until both descriptions are in, then flow directly.
  var described = false;
  final toAnswerer = <RTCIceCandidate>[];
  final toOfferer = <RTCIceCandidate>[];
  offerer.onIceCandidate.listen((c) =>
      described ? unawaited(answerer.addIceCandidate(c)) : toAnswerer.add(c));
  answerer.onIceCandidate.listen((c) =>
      described ? unawaited(offerer.addIceCandidate(c)) : toOfferer.add(c));

  await offerer.waitForReady();
  await answerer.waitForReady();
  offerer.createDataChannel('security', ordered: true);
  final offer = await offerer.createOffer();
  await offerer.setLocalDescription(offer);
  await answerer.setRemoteDescription(
      tamperOffer ? _withForeignFingerprint(offer) : offer);
  final answer = await answerer.createAnswer();
  await answerer.setLocalDescription(answer);
  await offerer.setRemoteDescription(
      tamperAnswer ? _withForeignFingerprint(answer) : answer);
  described = true;
  for (final c in toAnswerer) {
    await answerer.addIceCandidate(c);
  }
  for (final c in toOfferer) {
    await offerer.addIceCandidate(c);
  }
  return (offerer, answerer);
}
