import 'dart:convert';

import 'package:rhr_bridge/direct_signaling.dart';
import 'package:test/test.dart';

void main() {
  test('description signals round-trip with their type', () {
    final offer = DirectDescriptionSignal.offer('v=0\r\n');
    final decoded = DirectSignal.decode(offer.encode());

    expect(decoded, isA<DirectDescriptionSignal>());
    final description = decoded as DirectDescriptionSignal;
    expect(description.isOffer, isTrue);
    expect(description.sdp, 'v=0\r\n');
    expect(description.toJson(), {
      'v': 1,
      't': 'direct_offer',
      'sdp': 'v=0\r\n',
    });
  });

  test('candidate preserves nullable end-of-candidates fields', () {
    const signal = DirectCandidateSignal(
      candidate: null,
      sdpMid: 'data',
      sdpMLineIndex: 0,
    );

    final decoded = DirectSignal.decode(jsonEncode(signal.toJson()));
    expect(decoded, isA<DirectCandidateSignal>());
    final candidate = decoded as DirectCandidateSignal;
    expect(candidate.candidate, isNull);
    expect(candidate.sdpMid, 'data');
    expect(candidate.sdpMLineIndex, 0);
  });

  test('transport errors round-trip with their message', () {
    const signal = DirectErrorSignal('ICE failed');
    final decoded = DirectSignal.decode(signal.encode());

    expect(decoded, isA<DirectErrorSignal>());
    expect((decoded as DirectErrorSignal).message, 'ICE failed');
  });

  test('rejects unknown versions and malformed fields', () {
    expect(
      () => DirectSignal.decode({'v': 2, 't': 'direct_end'}),
      throwsFormatException,
    );
    expect(
      () => DirectSignal.decode({'v': 1, 't': 'direct_offer', 'sdp': ''}),
      throwsFormatException,
    );
    expect(
      () => DirectSignal.decode({
        'v': 1,
        't': 'direct_candidate',
        'sdpMLineIndex': '0',
      }),
      throwsFormatException,
    );
  });

  test('rejects non-object JSON', () {
    expect(() => DirectSignal.decode('[]'), throwsFormatException);
    expect(() => DirectSignal.decode(42), throwsFormatException);
  });
}
