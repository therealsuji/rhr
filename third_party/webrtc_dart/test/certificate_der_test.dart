import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:webrtc_dart/webrtc_dart.dart';

void main() {
  // The serial number is random, so a single certificate proves little: half
  // of all serials used to encode as negative and BoringSSL refused them.
  test('every generated certificate parses in BoringSSL', () async {
    for (var i = 0; i < 64; i++) {
      final pair = await generateSelfSignedCertificate();
      final pem = '-----BEGIN CERTIFICATE-----\n'
          '${base64.encode(pair.certificate)}\n'
          '-----END CERTIFICATE-----\n';
      SecurityContext().useCertificateChainBytes(utf8.encode(pem));
    }
  });

  test('the certificate verifies against its own key', () async {
    final pair = await generateSelfSignedCertificate();
    final dir = Directory.systemTemp.createTempSync('rhr-cert-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final der = File('${dir.path}/cert.der')
      ..writeAsBytesSync(pair.certificate);
    final pem = await Process.run('openssl', [
      'x509',
      '-inform',
      'DER',
      '-in',
      der.path,
      '-out',
      '${dir.path}/cert.pem',
    ]);
    expect(pem.exitCode, 0, reason: '${pem.stderr}');
    // Checks the signature only; the certificate is not a CA, so chain
    // building is not the question.
    final result = await Process.run('openssl', [
      'x509',
      '-in',
      '${dir.path}/cert.pem',
      '-noout',
      '-text',
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final verify = await Process.run('openssl', [
      'verify',
      '-check_ss_sig',
      '-partial_chain',
      '-trusted',
      '${dir.path}/cert.pem',
      '${dir.path}/cert.pem',
    ]);
    expect('${verify.stdout}${verify.stderr}', contains('OK'));
  });
}
