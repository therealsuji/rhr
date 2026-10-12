import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart' as pc;
import 'package:webrtc_dart/src/dtls/dtls_transport.dart'
    show CertificateFingerprint;
import 'package:webrtc_dart/src/dtls/handshake/const.dart';

// Checks on the certificate the DTLS peer presents. WebRTC certificates are
// self-signed, so no chain is validated: the peer is authenticated by its
// certificate hashing to an a=fingerprint from the SDP the signaling channel
// carried (RFC 8122, RFC 8827 Section 6.5), and by a ServerKeyExchange or
// CertificateVerify signature proving it holds that certificate's key.

/// Hash functions an a=fingerprint may name that we can compute. RFC 8122
/// Section 5 forbids md2 and md5, so they never match.
final Map<String, crypto.Hash> _fingerprintHashes = {
  'sha-1': crypto.sha1,
  'sha-224': crypto.sha224,
  'sha-256': crypto.sha256,
  'sha-384': crypto.sha384,
  'sha-512': crypto.sha512,
};

/// Whether the DER [certificate] hashes to one of [fingerprints]. Hash names
/// and hex digits compare case-insensitively; fingerprints with a hash we
/// cannot compute are skipped, so they alone never match.
bool certificateMatchesFingerprints(
  Uint8List certificate,
  Iterable<CertificateFingerprint> fingerprints,
) =>
    fingerprints.any((fingerprint) {
      final hash = _fingerprintHashes[fingerprint.algorithm.toLowerCase()];
      if (hash == null) return false;
      final digest = hash
          .convert(certificate)
          .bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      return fingerprint.value.replaceAll(':', '').toLowerCase() == digest;
    });

/// Verifies a handshake [signature] over [message] with the key in the DER
/// [certificate]. Supports what this stack offers in signature_algorithms and
/// CertificateRequest: ECDSA P-256 and RSA PKCS#1 v1.5, both with SHA-256.
/// Anything else, or a malformed certificate or signature, fails.
bool verifyCertificateSignature({
  required Uint8List certificate,
  required SignatureScheme scheme,
  required Uint8List message,
  required Uint8List signature,
}) {
  try {
    final key = _subjectPublicKey(certificate);
    switch (scheme) {
      case SignatureScheme.ecdsaSecp256r1Sha256 when key is pc.ECPublicKey:
        final rs = _children(_readDer(signature, 0, whole: true).content);
        if (rs.length != 2 || rs.any((integer) => integer.tag != _integerTag)) {
          return false;
        }
        final verifier = pc.ECDSASigner(pc.SHA256Digest())
          ..init(false, pc.PublicKeyParameter<pc.ECPublicKey>(key));
        return verifier.verifySignature(
          message,
          pc.ECSignature(_unsigned(rs[0].content), _unsigned(rs[1].content)),
        );
      case SignatureScheme.rsaPkcs1Sha256 when key is pc.RSAPublicKey:
        final verifier = pc.RSASigner(pc.SHA256Digest(), _sha256DigestInfoOid)
          ..init(false, pc.PublicKeyParameter<pc.RSAPublicKey>(key));
        return verifier.verifySignature(message, pc.RSASignature(signature));
      default:
        return false;
    }
  } on Object {
    return false;
  }
}

/// DER prefix pointycastle's RSASigner wants for SHA-256 DigestInfo.
const _sha256DigestInfoOid = '0609608648016503040201';

const _integerTag = 0x02;
const _bitStringTag = 0x03;
const _oidTag = 0x06;
const _explicitVersionTag = 0xA0;

/// id-ecPublicKey (1.2.840.10045.2.1).
final _ecPublicKeyOid = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01];

/// prime256v1 (1.2.840.10045.3.1.7).
final _p256Oid = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07];

/// rsaEncryption (1.2.840.113549.1.1.1).
final _rsaEncryptionOid = [
  0x2A,
  0x86,
  0x48,
  0x86,
  0xF7,
  0x0D,
  0x01,
  0x01,
  0x01
];

/// The subjectPublicKey of an X.509 certificate (RFC 5280 Section 4.1): a
/// P-256 EC key or an RSA key.
pc.PublicKey _subjectPublicKey(Uint8List certificate) {
  final cert = _children(_readDer(certificate, 0, whole: true).content);
  final tbs = _children(cert.first.content);
  // tbsCertificate: [0] version (optional), serialNumber, signature, issuer,
  // validity, subject, subjectPublicKeyInfo, ...
  final spkiIndex = tbs.first.tag == _explicitVersionTag ? 6 : 5;
  final spki = _children(tbs[spkiIndex].content);
  final algorithm = _children(spki[0].content);
  final keyBits = spki[1];
  if (keyBits.tag != _bitStringTag ||
      keyBits.content.isEmpty ||
      keyBits.content[0] != 0) {
    throw const FormatException('Malformed subjectPublicKey');
  }
  final key = Uint8List.sublistView(keyBits.content, 1);

  if (_isOid(algorithm[0], _ecPublicKeyOid)) {
    if (algorithm.length < 2 || !_isOid(algorithm[1], _p256Oid)) {
      throw const FormatException('Unsupported EC curve');
    }
    final params = pc.ECCurve_secp256r1();
    final point = params.curve.decodePoint(key);
    if (point == null) throw const FormatException('Malformed EC point');
    return pc.ECPublicKey(point, params);
  }
  if (_isOid(algorithm[0], _rsaEncryptionOid)) {
    final rsa = _children(_readDer(key, 0, whole: true).content);
    return pc.RSAPublicKey(
      _unsigned(rsa[0].content),
      _unsigned(rsa[1].content),
    );
  }
  throw const FormatException('Unsupported public key algorithm');
}

typedef _DerElement = ({int tag, Uint8List content, int end});

/// Reads the DER element at [offset]. With [whole], it must span the rest of
/// [data].
_DerElement _readDer(Uint8List data, int offset, {bool whole = false}) {
  if (offset + 2 > data.length) throw const FormatException('Truncated DER');
  final tag = data[offset];
  var length = data[offset + 1];
  var pos = offset + 2;
  if (length & 0x80 != 0) {
    final lengthBytes = length & 0x7F;
    if (lengthBytes == 0 ||
        lengthBytes > 4 ||
        pos + lengthBytes > data.length) {
      throw const FormatException('Bad DER length');
    }
    length = 0;
    for (var i = 0; i < lengthBytes; i++) {
      length = (length << 8) | data[pos++];
    }
  }
  final end = pos + length;
  if (end > data.length || (whole && end != data.length)) {
    throw const FormatException('Bad DER length');
  }
  return (
    tag: tag,
    content: Uint8List.sublistView(data, pos, end),
    end: end,
  );
}

/// The elements of a constructed DER value's [content].
List<_DerElement> _children(Uint8List content) {
  final elements = <_DerElement>[];
  for (var offset = 0; offset < content.length;) {
    final element = _readDer(content, offset);
    elements.add(element);
    offset = element.end;
  }
  if (elements.isEmpty) throw const FormatException('Empty DER sequence');
  return elements;
}

bool _isOid(_DerElement element, List<int> oid) {
  if (element.tag != _oidTag || element.content.length != oid.length) {
    return false;
  }
  for (var i = 0; i < oid.length; i++) {
    if (element.content[i] != oid[i]) return false;
  }
  return true;
}

BigInt _unsigned(Uint8List bytes) =>
    bytes.fold(BigInt.zero, (value, b) => (value << 8) | BigInt.from(b));
