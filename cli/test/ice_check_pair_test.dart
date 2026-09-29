// ignore_for_file: implementation_imports
import 'package:test/test.dart';
import 'package:webrtc_dart/src/ice/candidate_pair.dart';
import 'package:webrtc_dart/webrtc_dart.dart';

RTCIceCandidate _candidate(
  String foundation,
  String host,
  int port, {
  String type = 'host',
}) => RTCIceCandidate(
  foundation: foundation,
  component: 1,
  transport: 'udp',
  priority: 1,
  host: host,
  port: port,
  type: type,
);

CandidatePair _pair(RTCIceCandidate local, RTCIceCandidate remote) =>
    CandidatePair(
      id: '${local.foundation}-${remote.foundation}',
      localCandidate: local,
      remoteCandidate: remote,
      iceControlling: false,
    );

void main() {
  // The cellular failure: a phone's check reached the laptop's global IPv6
  // socket, but the first pair listed for that remote was the Tailscale ULA
  // one, which cannot send to it.
  final phone = _candidate('remote', '2407:c00:e000:53e4::1', 48500);
  final ula = _candidate('ula', 'fd7a:115c:a1e0::3d33:f84f', 50001);
  final global = _candidate('global', '2402:d000:811c:2c4::2931', 60931);

  test('the pair is the one whose local socket received the check', () {
    final pairs = [_pair(ula, phone), _pair(global, phone)];
    final proven = pairProvenByCheck(
      pairs,
      phone.host,
      phone.port,
      (local) => local.foundation == 'global',
    );
    expect(proven?.localCandidate.foundation, 'global');
  });

  test('a host candidate beats a reflexive one on the same socket', () {
    final srflx = _candidate('srflx', '203.0.113.9', 4000, type: 'srflx');
    final host = _candidate('host', '192.168.1.12', 4000);
    final remote = _candidate('remote4', '198.51.100.7', 5000);
    final proven = pairProvenByCheck(
      [_pair(srflx, remote), _pair(host, remote)],
      remote.host,
      remote.port,
      (local) => true,
    );
    expect(proven?.localCandidate.type, 'host');
  });

  test('no pair on the receiving socket means none, not the first one', () {
    expect(
      pairProvenByCheck(
        [_pair(ula, phone)],
        phone.host,
        phone.port,
        (local) => local.foundation == 'global',
      ),
      isNull,
    );
  });
}
