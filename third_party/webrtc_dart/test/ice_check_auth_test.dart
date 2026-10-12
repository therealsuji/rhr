// ignore_for_file: implementation_imports
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:webrtc_dart/src/ice/candidate_pair.dart';
import 'package:webrtc_dart/src/stun/const.dart';
import 'package:webrtc_dart/webrtc_dart.dart';

/// A connectivity check proves a pair, and the first proven pair is
/// nominated and carries DTLS. So only a check from our peer may do that: its
/// USERNAME must be `<our ufrag>:<their ufrag>` and its MESSAGE-INTEGRITY
/// must verify under our ice-pwd (RFC 8445 Section 7.3). Anyone else who can
/// reach the socket must not be able to create or nominate a pair.
void main() {
  const remoteUfrag = 'peerUfrg';
  late IceConnectionImpl ice;
  late RTCIceCandidate host;
  late RawDatagramSocket attacker;
  late int pairsBefore;
  final responses = StreamController<StunMessage>.broadcast();

  setUp(() async {
    ice = IceConnectionImpl(
      iceControlling: false,
      options: const IceOptions(useIpv6: false),
    );
    await ice.gatherCandidates();
    host = ice.localCandidates.firstWhere((c) => c.type == 'host');
    ice.setRemoteParams(
      iceLite: false,
      usernameFragment: remoteUfrag,
      password: 'peer-password-of-24-char',
    );
    // A signaled remote candidate, so checks are handled rather than queued.
    final silent = await RawDatagramSocket.bind(host.host, 0);
    addTearDown(silent.close);
    await ice.addRemoteCandidate(RTCIceCandidate(
      foundation: 'remote',
      component: 1,
      transport: 'udp',
      priority: 1,
      host: host.host,
      port: silent.port,
      type: 'host',
    ));
    pairsBefore = ice.checkList.length;

    attacker = await RawDatagramSocket.bind(host.host, 0);
    attacker.listen((event) {
      final datagram = attacker.receive();
      final message = datagram == null ? null : parseStunMessage(datagram.data);
      if (message != null) responses.add(message);
    });
  });

  tearDown(() async {
    attacker.close();
    await ice.close();
  });

  /// Sends a binding request to our host candidate and reports whether it was
  /// answered.
  Future<bool> check({required String username, required String password}) {
    final request = StunMessage(
      method: StunMethod.binding,
      messageClass: StunClass.request,
    )
      ..setAttribute(StunAttributeType.username, username)
      ..setAttribute(StunAttributeType.priority, 1)
      ..setAttribute(StunAttributeType.iceControlling, BigInt.one)
      ..setAttribute(StunAttributeType.useCandidate, null)
      ..addMessageIntegrity(Uint8List.fromList(utf8.encode(password)))
      ..addFingerprint();
    final answered = responses.stream
        .any((r) => r.transactionIdHex == request.transactionIdHex)
        .timeout(const Duration(milliseconds: 500), onTimeout: () => false);
    attacker.send(request.toBytes(), InternetAddress(host.host), host.port);
    return answered;
  }

  void expectNoPairTouched() {
    expect(ice.checkList, hasLength(pairsBefore));
    expect(
      ice.checkList.where((p) => p.state == CandidatePairState.succeeded),
      isEmpty,
    );
    expect(ice.nominated, isNull);
  }

  test('a check keyed with the wrong password is dropped', () async {
    expect(
      await check(
        username: '${ice.localUsername}:$remoteUfrag',
        password: 'not-the-ice-pwd-at-all!!',
      ),
      isFalse,
    );
    expectNoPairTouched();
  });

  test('a check naming another session is dropped', () async {
    expect(
      await check(
        username: '${ice.localUsername}:otherUfr',
        password: ice.localPassword,
      ),
      isFalse,
    );
    expect(
      await check(
        username: 'otherUfr:$remoteUfrag',
        password: ice.localPassword,
      ),
      isFalse,
    );
    expectNoPairTouched();
  });

  test('the peer\'s own check proves and nominates a pair', () async {
    expect(
      await check(
        username: '${ice.localUsername}:$remoteUfrag',
        password: ice.localPassword,
      ),
      isTrue,
    );
    expect(ice.nominated?.remoteCandidate.port, attacker.port);
  });
}
