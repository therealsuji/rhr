import 'dart:typed_data';

import 'package:webrtc_dart/src/common/logging.dart';
import 'package:webrtc_dart/src/dtls/certificate/peer_certificate.dart';
import 'package:webrtc_dart/src/dtls/cipher/const.dart';
import 'package:webrtc_dart/src/dtls/cipher/ecdh.dart';
import 'package:webrtc_dart/src/dtls/cipher/key_derivation.dart';
import 'package:webrtc_dart/src/dtls/context/cipher_context.dart';
import 'package:webrtc_dart/src/dtls/context/dtls_context.dart';
import 'package:webrtc_dart/src/dtls/context/srtp_context.dart';
import 'package:webrtc_dart/src/dtls/flight/flight.dart';
import 'package:webrtc_dart/src/dtls/flight/server_flights.dart';
import 'package:webrtc_dart/src/dtls/handshake/const.dart';
import 'package:webrtc_dart/src/dtls/handshake/extensions/elliptic_curves.dart';
import 'package:webrtc_dart/src/dtls/handshake/extensions/use_srtp.dart';
import 'package:webrtc_dart/src/dtls/handshake/message/certificate.dart';
import 'package:webrtc_dart/src/dtls/handshake/message/certificate_verify.dart';
import 'package:webrtc_dart/src/dtls/handshake/message/client_hello.dart';
import 'package:webrtc_dart/src/dtls/handshake/message/client_key_exchange.dart';
import 'package:webrtc_dart/src/dtls/handshake/message/finished.dart';
import 'package:webrtc_dart/src/dtls/record/record_layer.dart';

final _log = WebRtcLogging.dtlsServer;

/// Server handshake state
enum ServerHandshakeState {
  initial,
  waitingForClientHello,
  waitingForClientHelloWithCookie,
  waitingForClientCertificate,
  waitingForClientKeyExchange,
  waitingForCertificateVerify,
  waitingForClientFinished,
  completed,
  failed,
}

/// Server handshake coordinator
/// Manages the DTLS server handshake flow
class ServerHandshakeCoordinator {
  final DtlsContext dtlsContext;
  final CipherContext cipherContext;
  final SrtpContext srtpContext;
  final DtlsRecordLayer recordLayer;
  final FlightManager flightManager;
  final List<CipherSuite> cipherSuites;
  final List<NamedCurve> supportedCurves;
  final Uint8List? certificate;
  final dynamic privateKey;

  /// Supported SRTP protection profiles (server preference order)
  /// Includes both AES-GCM (modern/preferred) and AES-CM-HMAC (legacy/compatible)
  static const List<SrtpProtectionProfile> supportedSrtpProfiles = [
    SrtpProtectionProfile.srtpAeadAes128Gcm,
    SrtpProtectionProfile.srtpAeadAes256Gcm,
    SrtpProtectionProfile.srtpAes128CmHmacSha1_80,
    SrtpProtectionProfile.srtpAes128CmHmacSha1_32,
  ];

  ServerHandshakeState _state = ServerHandshakeState.waitingForClientHello;

  ServerHandshakeCoordinator({
    required this.dtlsContext,
    required this.cipherContext,
    required this.srtpContext,
    required this.recordLayer,
    required this.flightManager,
    required this.cipherSuites,
    required this.supportedCurves,
    this.certificate,
    this.privateKey,
  });

  ServerHandshakeState get state => _state;

  /// Get current flight number for retransmit tracking
  /// Maps handshake state to DTLS flight numbers (server perspective):
  /// - Flight 2: HelloVerifyRequest
  /// - Flight 4: ServerHello, Certificate, ServerKeyExchange, ServerHelloDone
  /// - Flight 6: ChangeCipherSpec, Finished
  int get currentFlight {
    switch (_state) {
      case ServerHandshakeState.initial:
      case ServerHandshakeState.waitingForClientHello:
        return 0;
      case ServerHandshakeState.waitingForClientHelloWithCookie:
        return 2; // Sent HelloVerifyRequest, waiting for ClientHello with cookie
      case ServerHandshakeState.waitingForClientCertificate:
      case ServerHandshakeState.waitingForClientKeyExchange:
      case ServerHandshakeState.waitingForCertificateVerify:
      case ServerHandshakeState.waitingForClientFinished:
        return 4; // Sent flight 4, waiting for (the rest of) client flight 5
      case ServerHandshakeState.completed:
        return 6;
      case ServerHandshakeState.failed:
        return -1;
    }
  }

  /// Process received handshake record
  Future<void> processHandshake(Uint8List data) async {
    // For now, assume data is just the message body without header
    // In production, we'd parse the handshake header first
  }

  /// Process handshake message with type
  /// [body] is the message body (without header)
  /// [fullMessage] is the complete message with header (for handshake buffer)
  Future<void> processHandshakeWithType(
    HandshakeType messageType,
    Uint8List body, {
    Uint8List? fullMessage,
  }) async {
    _log.fine('Processing $messageType in state $_state');
    switch (messageType) {
      case HandshakeType.clientHello:
        await _processClientHello(body, fullMessage: fullMessage);
        break;
      case HandshakeType.certificate:
        await _processCertificate(body, fullMessage: fullMessage);
        break;
      case HandshakeType.clientKeyExchange:
        await _processClientKeyExchange(body, fullMessage: fullMessage);
        break;
      case HandshakeType.certificateVerify:
        await _processCertificateVerify(body, fullMessage: fullMessage);
        break;
      case HandshakeType.finished:
        await _processFinished(body, fullMessage: fullMessage);
        break;
      default:
        // Ignore other message types for now
        break;
    }
  }

  /// Process ClientHello from client
  Future<void> _processClientHello(Uint8List data,
      {Uint8List? fullMessage}) async {
    // Parse ClientHello
    final clientHello = ClientHello.parse(data);
    dtlsContext.clientHello = clientHello;
    dtlsContext.remoteRandom = clientHello.random.bytes;

    // Check if client wants extended master secret
    dtlsContext.useExtendedMasterSecret = clientHello.hasExtendedMasterSecret;

    // Negotiate SRTP profile if client offered any
    final clientSrtpProfiles = clientHello.srtpProfiles;
    if (clientSrtpProfiles.isNotEmpty && srtpContext.profile == null) {
      // Find first matching profile (server preference)
      for (final serverProfile in supportedSrtpProfiles) {
        if (clientSrtpProfiles.contains(serverProfile)) {
          srtpContext.profile = serverProfile;
          _log.fine('Selected SRTP profile: $serverProfile');
          break;
        }
      }
    }

    _log.fine(
        'Processing ClientHello (cookie length: ${clientHello.cookie.length}, ems=${dtlsContext.useExtendedMasterSecret}, srtp=${srtpContext.profile})');

    // Check if cookie is present
    if (clientHello.cookie.isEmpty) {
      // First ClientHello without cookie - send HelloVerifyRequest
      // Handle retransmission: if we're in waitingForClientHelloWithCookie state,
      // the client may not have received our HelloVerifyRequest (packet loss).
      // Per RFC 6347, we should re-send the HelloVerifyRequest.
      if (_state == ServerHandshakeState.waitingForClientHelloWithCookie) {
        _log.fine(
            'Retransmitted first ClientHello (no cookie) detected, re-sending HelloVerifyRequest');
        final currentFlight = flightManager.currentFlight;
        if (currentFlight != null) {
          // Mark as not sent so it gets retransmitted
          currentFlight.markNotSent();
        }
        return;
      }

      if (_state != ServerHandshakeState.waitingForClientHello) {
        throw StateError('Unexpected first ClientHello in state $_state');
      }

      // Send Flight 2 (HelloVerifyRequest)
      final flight2 = ServerFlight2(
        dtlsContext: dtlsContext,
        recordLayer: recordLayer,
      );

      final messages = await flight2.generateMessages();
      flightManager.addFlight(flight2, messages);

      _state = ServerHandshakeState.waitingForClientHelloWithCookie;
    } else {
      // Second ClientHello with cookie - verify and proceed
      _log.fine('Second ClientHello - verifying cookie');

      // Handle retransmission: if we're in a later state, this is a retransmit
      // We should re-send the last flight (RFC 6347 Section 4.2.4)
      if (_state == ServerHandshakeState.waitingForClientCertificate ||
          _state == ServerHandshakeState.waitingForClientKeyExchange ||
          _state == ServerHandshakeState.waitingForCertificateVerify ||
          _state == ServerHandshakeState.waitingForClientFinished) {
        _log.fine(
            'Retransmitted ClientHello detected in state $_state, re-sending last flight');
        // Just re-send the current flight - the caller will handle it via _sendPendingFlights
        final currentFlight = flightManager.currentFlight;
        if (currentFlight != null) {
          // Mark as not sent so it gets retransmitted
          currentFlight.markNotSent();
        }
        return;
      }

      if (_state != ServerHandshakeState.waitingForClientHelloWithCookie) {
        throw StateError('Unexpected second ClientHello in state $_state');
      }

      // Verify cookie matches
      if (clientHello.cookie.length != dtlsContext.cookie?.length ||
          !_bytesEqual(clientHello.cookie, dtlsContext.cookie!)) {
        throw StateError('Cookie mismatch');
      }

      _log.fine('Cookie verified, generating key pair');

      // Pick what both sides support before committing to anything
      final cipherSuite = clientHello.cipherSuites
          .where(cipherSuites.contains)
          .firstOrNull;
      if (cipherSuite == null) {
        _fail('No cipher suite in common with the client');
      }
      final curve = _selectCurve(clientHello);

      // Add to handshake messages (use fullMessage if available, includes header)
      dtlsContext.addHandshakeMessage(fullMessage ?? data);

      // Mark Flight 2 as complete (received response)
      flightManager.moveToNextFlight();

      // Generate our ECDH key pair
      await _generateKeyPair(curve);

      _log.fine('Key pair generated, creating Flight 4');

      // Send Flight 4 (ServerHello + Certificate + ServerKeyExchange +
      // CertificateRequest + ServerHelloDone). WebRTC authenticates both
      // ends (RFC 8827 Section 6.5), so the client's certificate is required.
      final flight4 = ServerFlight4(
        dtlsContext: dtlsContext,
        cipherContext: cipherContext,
        recordLayer: recordLayer,
        cipherSuite: cipherSuite,
        certificate: certificate,
        privateKey: privateKey,
        requireClientCert: true,
        srtpProfile: srtpContext.profile,
      );

      final messages = await flight4.generateMessages();
      _log.fine('Flight 4 has ${messages.length} messages');
      flightManager.addFlight(flight4, messages);

      _state = ServerHandshakeState.waitingForClientCertificate;
    }
  }

  /// Process Certificate from client
  ///
  /// Required: it must match an a=fingerprint from the remote SDP, the same
  /// check the client makes of ours.
  Future<void> _processCertificate(Uint8List data,
      {Uint8List? fullMessage}) async {
    if (_state != ServerHandshakeState.waitingForClientCertificate) {
      // A retransmission or a reordered message; it is not part of the
      // transcript here.
      _log.fine('Ignoring client Certificate in state $_state');
      return;
    }

    final certificate = Certificate.parse(data).entityCertificate;
    if (certificate == null) {
      _fail('Client sent no certificate');
    }
    if (!certificateMatchesFingerprints(
        certificate, cipherContext.remoteFingerprints)) {
      _fail('Client certificate does not match the remote SDP fingerprint');
    }
    cipherContext.remoteCertificate = certificate;

    dtlsContext.addHandshakeMessage(fullMessage ?? data);
    _state = ServerHandshakeState.waitingForClientKeyExchange;
  }

  /// Process ClientKeyExchange from client
  Future<void> _processClientKeyExchange(Uint8List data,
      {Uint8List? fullMessage}) async {
    if (_state != ServerHandshakeState.waitingForClientKeyExchange) {
      // Before the client's Certificate it would skip authentication; after
      // it, it is a retransmission. Neither belongs in the transcript.
      _log.fine('Ignoring ClientKeyExchange in state $_state');
      return;
    }

    // Parse ClientKeyExchange
    final cke = ClientKeyExchange.parse(data);

    // Store client's public key
    cipherContext.remotePublicKey = cke.publicKey;

    // Add to handshake messages (use fullMessage if available, includes header)
    dtlsContext.addHandshakeMessage(fullMessage ?? data);

    // Mark Flight 4 as complete (client has received it and is responding)
    flightManager.moveToNextFlight();

    // Compute shared secret
    if (cipherContext.localKeyPair != null &&
        cipherContext.namedCurve != null) {
      final sharedSecret = await computePreMasterSecret(
        cipherContext.localKeyPair!,
        cke.publicKey,
        cipherContext.namedCurve!,
      );
      dtlsContext.preMasterSecret = sharedSecret;

      // Derive master secret from pre-master secret
      // Only use extended master secret if negotiated with client (RFC 7627)
      _log.fine(
          'Deriving master secret (extended=${dtlsContext.useExtendedMasterSecret})');
      final masterSecret = KeyDerivation.deriveMasterSecret(
        dtlsContext,
        cipherContext,
        dtlsContext.useExtendedMasterSecret,
      );
      dtlsContext.masterSecret = masterSecret;

      // Derive encryption keys from master secret
      final encryptionKeys = KeyDerivation.deriveEncryptionKeys(
        dtlsContext,
        cipherContext,
      );
      cipherContext.encryptionKeys = encryptionKeys;

      // Initialize ciphers for encryption/decryption
      if (cipherContext.cipherSuite != null) {
        cipherContext.initializeCiphers(
            encryptionKeys, cipherContext.cipherSuite!);
      }
    }

    _state = ServerHandshakeState.waitingForCertificateVerify;
  }

  /// Process CertificateVerify from client
  ///
  /// Its signature over the transcript so far, by the key in the client's
  /// certificate, proves the client holds that certificate (RFC 5246
  /// Section 7.4.8). Without it a client could present anyone's.
  Future<void> _processCertificateVerify(Uint8List data,
      {Uint8List? fullMessage}) async {
    if (_state != ServerHandshakeState.waitingForCertificateVerify) {
      _log.fine('Ignoring CertificateVerify in state $_state');
      return;
    }

    final certificateVerify = CertificateVerify.parse(data);
    if (!verifyCertificateSignature(
      certificate: cipherContext.remoteCertificate!,
      scheme: certificateVerify.signatureScheme,
      message: dtlsContext.getAllHandshakeMessages(),
      signature: certificateVerify.signature,
    )) {
      _fail('CertificateVerify signature does not verify');
    }

    dtlsContext.addHandshakeMessage(fullMessage ?? data);
    _state = ServerHandshakeState.waitingForClientFinished;
  }

  /// Process Finished from client
  Future<void> _processFinished(Uint8List data,
      {Uint8List? fullMessage}) async {
    if (_state == ServerHandshakeState.completed) {
      // The client did not get our flight 6 and resent its flight 5: send
      // flight 6 again (RFC 6347 Section 4.2.4).
      _log.fine('Retransmitted Finished, re-sending flight 6');
      flightManager.currentFlight?.markNotSent();
      return;
    }
    if (_state != ServerHandshakeState.waitingForClientFinished) {
      _log.fine('Ignoring Finished in state $_state');
      return;
    }

    // Parse Finished message
    final finished = Finished.parse(data);

    // Verify the verify_data matches expected value
    final isValid = KeyDerivation.verifyFinishedMessage(
      dtlsContext,
      finished.verifyData,
      true, // isClient=true for verifying client's Finished
    );

    if (!isValid) {
      _state = ServerHandshakeState.failed;
      throw StateError('Finished message verification failed');
    }

    dtlsContext.addHandshakeMessage(fullMessage ?? data);

    // Send Flight 6 (ChangeCipherSpec + Finished)
    final flight6 = ServerFlight6(
      dtlsContext: dtlsContext,
      cipherContext: cipherContext,
      recordLayer: recordLayer,
    );

    final messages = await flight6.generateMessages();
    flightManager.addFlight(flight6, messages);

    dtlsContext.handshakeComplete = true;
    _state = ServerHandshakeState.completed;
  }

  /// The ECDHE curve: the first of ours, in preference order, that the
  /// client offers in supported_groups. A client that sends no
  /// supported_groups accepts any curve (RFC 8422 Section 4).
  NamedCurve _selectCurve(ClientHello clientHello) {
    final offered = clientHello.extensions
        .whereType<EllipticCurvesExtension>()
        .firstOrNull
        ?.curves;
    final curve = supportedCurves
        .where((curve) => offered == null || offered.contains(curve))
        .firstOrNull;
    if (curve == null) {
      _fail('No elliptic curve in common with the client');
    }
    return curve;
  }

  /// Generate ECDH key pair for key exchange
  Future<void> _generateKeyPair(NamedCurve curve) async {
    cipherContext.namedCurve = curve;

    // Generate key pair
    final keyPair = await generateEcdhKeypair(curve);
    cipherContext.localKeyPair = keyPair;
    cipherContext.localPublicKey = await serializePublicKey(keyPair, curve);

    // Set signature scheme
    cipherContext.signatureScheme = SignatureScheme.ecdsaSecp256r1Sha256;
  }

  /// Compare two byte arrays for equality
  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Check if handshake is complete
  bool get isComplete => _state == ServerHandshakeState.completed;

  /// Check if handshake failed
  bool get isFailed => _state == ServerHandshakeState.failed;

  /// Whether a ChangeCipherSpec from the client belongs here: only after its
  /// CertificateVerify, once the keys exist, right before its Finished.
  bool get expectsChangeCipherSpec =>
      _state == ServerHandshakeState.waitingForClientFinished;

  /// Fails the handshake.
  Never _fail(String reason) {
    _state = ServerHandshakeState.failed;
    throw StateError('DTLS handshake failed: $reason');
  }
}
