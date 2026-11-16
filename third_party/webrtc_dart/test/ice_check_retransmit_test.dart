// ignore_for_file: implementation_imports
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:webrtc_dart/src/stun/const.dart';
import 'package:webrtc_dart/webrtc_dart.dart';

/// A connectivity check is a STUN transaction, retransmitted until answered
/// (RFC 8489 Section 6.2.1), not one datagram. The first requests often leave
/// before the peer has our answer, or hit a NAT pinhole that is not open yet;
/// a check that gave up on its first loss failed every pair on such a path.
void main() {
  const peerUfrag = 'peerUfrg';
  const peerPassword = 'peer-password-of-24-char';

  test('a check whose first requests are lost still proves its pair',
      () async {
    final ice = IceConnectionImpl(
      iceControlling: false,
      options: const IceOptions(useIpv6: false),
    );
    addTearDown(ice.close);
    await ice.gatherCandidates();
    final host = ice.localCandidates.firstWhere((c) => c.type == 'host');

    // The peer ignores the first two copies of every request, then answers.
    final peer = await RawDatagramSocket.bind(host.host, 0);
    addTearDown(peer.close);
    final seen = <String, int>{};
    peer.listen((event) {
      final datagram = peer.receive();
      if (datagram == null) return;
      final request = parseStunMessage(datagram.data);
      if (request == null || request.messageClass != StunClass.request) return;
      final copies = seen.update(request.transactionIdHex, (n) => n + 1,
          ifAbsent: () => 1);
      if (copies < 3) return;
      final response = StunMessage(
        method: StunMethod.binding,
        messageClass: StunClass.successResponse,
        transactionId: request.transactionId,
      )
        ..setAttribute(StunAttributeType.xorMappedAddress,
            (datagram.address.address, datagram.port))
        ..addMessageIntegrity(Uint8List.fromList(utf8.encode(peerPassword)))
        ..addFingerprint();
      peer.send(response.toBytes(), datagram.address, datagram.port);
    });

    ice.setRemoteParams(
      iceLite: false,
      usernameFragment: peerUfrag,
      password: peerPassword,
    );
    await ice.addRemoteCandidate(RTCIceCandidate(
      foundation: 'peer',
      component: 1,
      transport: 'udp',
      priority: 1,
      host: host.host,
      port: peer.port,
      type: 'host',
    ));

    await ice.connect();

    expect(ice.state, IceState.completed);
    expect(ice.nominated?.remoteCandidate.port, peer.port);
    expect(seen.values, contains(3));
  });
}
