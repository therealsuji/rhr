// ignore_for_file: implementation_imports
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:webrtc_dart/src/dtls/cipher/const.dart';
import 'package:webrtc_dart/src/dtls/cipher/ecdh.dart';

void main() {
  test('P-256 peers agree on the pre-master secret', () async {
    final a = await generateEcdhKeypair(NamedCurve.secp256r1);
    final b = await generateEcdhKeypair(NamedCurve.secp256r1);
    final aPublic = await serializePublicKey(a, NamedCurve.secp256r1);
    final bPublic = await serializePublicKey(b, NamedCurve.secp256r1);
    expect(
      await computePreMasterSecret(a, bPublic, NamedCurve.secp256r1),
      await computePreMasterSecret(b, aPublic, NamedCurve.secp256r1),
    );
  });

  // An off-curve point lets the peer learn our private key from the result
  // (invalid-curve attack), so it is refused.
  test('a P-256 point off the curve is refused', () async {
    final local = await generateEcdhKeypair(NamedCurve.secp256r1);
    final offCurve = Uint8List(65)
      ..[0] = 0x04
      ..[32] = 1 // x = 1
      ..[64] = 1; // y = 1
    await expectLater(
      computePreMasterSecret(local, offCurve, NamedCurve.secp256r1),
      throwsArgumentError,
    );
  });
}
