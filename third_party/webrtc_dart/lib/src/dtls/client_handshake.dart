import 'dart:typed_data';

import 'package:webrtc_dart/src/common/logging.dart';
import 'package:webrtc_dart/src/dtls/certificate/peer_certificate.dart';
import 'package:webrtc_dart/src/dtls/cipher/const.dart';
import 'package:webrtc_dart/src/dtls/cipher/ecdh.dart';
import 'package:webrtc_dart/src/dtls/cipher/key_derivation.dart';
import 'package:webrtc_dart/src/dtls/context/cipher_context.dart';
import 'package:webrtc_dart/src/dtls/context/dtls_context.dart';
import 'package:webrtc_dart/src/dtls/context/srtp_context.dart';
import 'package:webrtc_dart/src/dtls/flight/client_flights.dart';
import 'package:webrtc_dart/src/dtls/flight/flight.dart';
import 'package:webrtc_dart/src/dtls/handshake/const.dart';
import 'package:webrtc_dart/src/dtls/handshake/message/certificate.dart';
import 'package:webrtc_dart/src/dtls/handshake/message/finished.dart';
import 'package:webrtc_dart/src/dtls/handshake/message/hello_verify_request.dart';
import 'package:webrtc_dart/src/dtls/handshake/message/server_hello.dart';
import 'package:webrtc_dart/src/dtls/handshake/message/server_hello_done.dart';
import 'package:webrtc_dart/src/dtls/handshake/message/server_key_exchange.dart';
import 'package:webrtc_dart/src/dtls/record/record_layer.dart';

final _log = WebRtcLogging.dtlsClient;

/// Client handshake state
enum ClientHandshakeState {
  initial,
  waitingForHelloVerifyRequest,
  waitingForServerHello,
  waitingForCertificate,
  waitingForServerKeyExchange,
  waitingForServerHelloDone,
  waitingForServerFinished,
  completed,
  failed,
}

/// Client handshake coordinator
/// Manages the DTLS client handshake flow
class ClientHandshakeCoordinator {
  final DtlsContext dtlsContext;
  final CipherContext cipherContext;
  final SrtpContext? srtpContext;
  final DtlsRecordLayer recordLayer;
  final FlightManager flightManager;
  final List<CipherSuite> cipherSuites;
  final List<NamedCurve> supportedCurves;

  ClientHandshakeState _state = ClientHandshakeState.initial;
  bool _certificateRequested = false;

  ClientHandshakeCoordinator({
    required this.dtlsContext,
    required this.cipherContext,
    this.srtpContext,
    required this.recordLayer,
    required this.flightManager,
    required this.cipherSuites,
    required this.supportedCurves,
  });

  ClientHandshakeState get state => _state;

  /// Get current flight number for retransmit tracking
  /// Maps handshake state to DTLS flight numbers:
  /// - Flight 1: ClientHello
  /// - Flight 3: ClientHello with cookie (after HelloVerifyRequest)
  /// - Flight 5: Certificate, ClientKeyExchange, CertificateVerify, ChangeCipherSpec, Finished
  /// - Flight 6: Handshake complete
  int get currentFlight {
    switch (_state) {
      case ClientHandshakeState.initial:
        return 0;
      case ClientHandshakeState.waitingForHelloVerifyRequest:
        return 1;
      case ClientHandshakeState.waitingForServerHello:
        return 3; // After cookie, waiting for server flight 4
      case ClientHandshakeState.waitingForCertificate:
      case ClientHandshakeState.waitingForServerKeyExchange:
      case ClientHandshakeState.waitingForServerHelloDone:
        return 3; // Still in server's flight 4
      case ClientHandshakeState.waitingForServerFinished:
        return 5; // Sent flight 5, waiting for server flight 6
      case ClientHandshakeState.completed:
        return 6;
      case ClientHandshakeState.failed:
        return -1;
    }
  }

  /// Start the handshake by sending initial ClientHello
  Future<void> start() async {
    if (_state != ClientHandshakeState.initial) {
      throw StateError('Handshake already started');
    }

    // Create and send Flight 1 (initial ClientHello)
    final flight1 = ClientFlight1(
      dtlsContext: dtlsContext,
      cipherContext: cipherContext,
      recordLayer: recordLayer,
      cipherSuites: cipherSuites,
      supportedCurves: supportedCurves,
    );

    final messages = await flight1.generateMessages();
    flightManager.addFlight(flight1, messages);

    _state = ClientHandshakeState.waitingForHelloVerifyRequest;
  }

  /// Process received handshake record
  Future<void> processHandshake(Uint8List data) async {
    // For now, assume data is just the message body without header
    // In production, we'd parse the handshake header first
    // The message type should be passed separately or we need to look at context

    // This is a simplified version - in reality we need proper message routing
    // based on current state expectations

    // For testing purposes, we'll handle raw message bodies
    // The test will pass the serialized message directly
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
      case HandshakeType.helloVerifyRequest:
        await _processHelloVerifyRequest(body);
        break;
      case HandshakeType.serverHello:
        await _processServerHello(body, fullMessage: fullMessage);
        break;
      case HandshakeType.certificate:
        await _processCertificate(body, fullMessage: fullMessage);
        break;
      case HandshakeType.serverKeyExchange:
        await _processServerKeyExchange(body, fullMessage: fullMessage);
        break;
      case HandshakeType.serverHelloDone:
        await _processServerHelloDone(body, fullMessage: fullMessage);
        break;
      case HandshakeType.finished:
        await _processFinished(body, fullMessage: fullMessage);
        break;
      case HandshakeType.certificateRequest:
        await _processCertificateRequest(body, fullMessage: fullMessage);
        break;
      default:
        // Ignore other message types for now
        break;
    }
  }

  /// Process HelloVerifyRequest from server
  Future<void> _processHelloVerifyRequest(Uint8List data) async {
    if (_state != ClientHandshakeState.waitingForHelloVerifyRequest) {
      throw StateError('Unexpected HelloVerifyRequest in state $_state');
    }

    // Parse HelloVerifyRequest
    final hvr = HelloVerifyRequest.parse(data);
    dtlsContext.cookie = hvr.cookie;

    // Clear handshake messages - handshake is restarted with cookie
    // Per RFC 6347: "the handshake is restarted and the first ClientHello is not included"
    dtlsContext.clearHandshakeMessages();
    // Also reset message sequence number since handshake is restarted
    dtlsContext.handshakeMessageSeq = 0;

    // Mark Flight 1 as complete
    flightManager.moveToNextFlight();

    // Send Flight 3 (ClientHello with cookie + key exchange)
    final flight3 = ClientFlight3(
      dtlsContext: dtlsContext,
      cipherContext: cipherContext,
      recordLayer: recordLayer,
      cipherSuites: cipherSuites,
    );

    final messages = await flight3.generateMessages();
    flightManager.addFlight(flight3, messages);

    _state = ClientHandshakeState.waitingForServerHello;
  }

  /// Process ServerHello from server
  Future<void> _processServerHello(Uint8List data,
      {Uint8List? fullMessage}) async {
    // RFC 6347 Section 4.2.1: HelloVerifyRequest is optional
    // Server may skip it and send ServerHello directly
    if (_state == ClientHandshakeState.waitingForHelloVerifyRequest) {
      _log.fine('Server skipped HelloVerifyRequest, proceeding directly');
      // Mark Flight 1 as complete
      flightManager.moveToNextFlight();
      _state = ClientHandshakeState.waitingForServerHello;

      // Important: The ClientHello is already in the handshake buffer from Flight 1
      // Server will include it in its verify_data calculation
      _log.fine(
          'Handshake buffer has ${dtlsContext.handshakeMessages.length} messages after ClientHello');
    }

    if (_state != ClientHandshakeState.waitingForServerHello) {
      // DTLS retransmission - silently ignore duplicate messages from previous flights
      _log.fine('Ignoring retransmitted ServerHello in state $_state');
      return;
    }

    // Parse ServerHello
    final serverHello = ServerHello.parse(data);
    if (!cipherSuites.contains(serverHello.cipherSuite)) {
      _fail('Server chose ${serverHello.cipherSuite}, which we did not offer');
    }
    dtlsContext.serverHello = serverHello;
    dtlsContext.remoteRandom = serverHello.random.bytes;

    // Store selected cipher suite
    cipherContext.cipherSuite = serverHello.cipherSuite;
    _log.fine('Selected cipher suite: ${serverHello.cipherSuite}');

    // Check if server echoed extended master secret extension
    dtlsContext.useExtendedMasterSecret = serverHello.hasExtendedMasterSecret;
    _log.fine('Extended master secret: ${dtlsContext.useExtendedMasterSecret}');

    // Extract negotiated SRTP profile from ServerHello
    final negotiatedSrtpProfile = serverHello.srtpProfile;
    if (negotiatedSrtpProfile != null && srtpContext != null) {
      srtpContext!.profile = negotiatedSrtpProfile;
      _log.fine('Negotiated SRTP profile: $negotiatedSrtpProfile');
    } else if (srtpContext != null) {
      _log.fine('No SRTP profile in ServerHello');
    }

    // Add to handshake messages (use fullMessage if available, includes header)
    dtlsContext.addHandshakeMessage(fullMessage ?? data);
    _log.fine(
        'Added ServerHello to buffer, now ${dtlsContext.handshakeMessages.length} messages');

    _state = ClientHandshakeState.waitingForCertificate;
  }

  /// Process Certificate from server
  ///
  /// The server's certificate is required, and must match an a=fingerprint
  /// from the remote SDP: that is what authenticates the peer in WebRTC,
  /// whose certificates are self-signed (RFC 8827 Section 6.5).
  Future<void> _processCertificate(Uint8List data,
      {Uint8List? fullMessage}) async {
    if (_state != ClientHandshakeState.waitingForCertificate) {
      // A retransmission, or a message ahead of the ServerHello it follows.
      // Neither belongs in the transcript; the server resends its flight.
      _log.fine('Ignoring Certificate in state $_state');
      return;
    }

    final certificate = Certificate.parse(data).entityCertificate;
    if (certificate == null) {
      _fail('Server sent no certificate');
    }
    if (!certificateMatchesFingerprints(
        certificate, cipherContext.remoteFingerprints)) {
      _fail('Server certificate does not match the remote SDP fingerprint');
    }
    cipherContext.remoteCertificate = certificate;

    dtlsContext.addHandshakeMessage(fullMessage ?? data);

    _state = ClientHandshakeState.waitingForServerKeyExchange;
  }

  /// Process ServerKeyExchange from server
  ///
  /// Its signature, by the key in the certificate just checked, is what
  /// proves the server holds that certificate and chose these ECDHE params.
  Future<void> _processServerKeyExchange(Uint8List data,
      {Uint8List? fullMessage}) async {
    if (_state != ClientHandshakeState.waitingForServerKeyExchange) {
      _log.fine('Ignoring ServerKeyExchange in state $_state');
      return;
    }

    // Parse ServerKeyExchange
    final ske = ServerKeyExchange.parse(data);
    if (!supportedCurves.contains(ske.curve)) {
      _fail('Server chose ${ske.curve}, which we did not offer');
    }
    final scheme = ske.signatureScheme;
    if (scheme == null ||
        !verifyCertificateSignature(
          certificate: cipherContext.remoteCertificate!,
          scheme: scheme,
          message: _serverKeyExchangeSignedData(ske),
          signature: ske.signature,
        )) {
      _fail('ServerKeyExchange signature does not verify');
    }

    // Store server's public key
    cipherContext.remotePublicKey = ske.publicKey;
    cipherContext.namedCurve = ske.curve;
    cipherContext.signatureScheme = scheme;
    _log.fine('Selected curve: ${ske.curve}');

    // Add to handshake messages
    dtlsContext.addHandshakeMessage(fullMessage ?? data);

    _state = ClientHandshakeState.waitingForServerHelloDone;
  }

  /// Process CertificateRequest from server
  Future<void> _processCertificateRequest(Uint8List data,
      {Uint8List? fullMessage}) async {
    // CertificateRequest comes between ServerKeyExchange and ServerHelloDone
    if (_state != ClientHandshakeState.waitingForServerHelloDone ||
        _certificateRequested) {
      _log.fine('Ignoring CertificateRequest in state $_state');
      return;
    }

    _log.fine('Server requested client certificate');
    _certificateRequested = true;

    // Add to handshake messages
    dtlsContext.addHandshakeMessage(fullMessage ?? data);

    // State remains waitingForServerHelloDone
  }

  /// Process ServerHelloDone from server
  Future<void> _processServerHelloDone(Uint8List data,
      {Uint8List? fullMessage}) async {
    if (_state != ClientHandshakeState.waitingForServerHelloDone) {
      _log.fine('Ignoring ServerHelloDone in state $_state');
      return;
    }

    // Parse ServerHelloDone
    ServerHelloDone.parse(data);
    dtlsContext.addHandshakeMessage(fullMessage ?? data);

    // Generate our ECDH key pair (but NOT master secret yet - that happens after ClientKeyExchange is added to buffer)
    await _generateKeyPairOnly();

    // Mark Flight 3 as complete (we're done waiting for ServerHello flight)
    flightManager.moveToNextFlight();

    // NOTE: Master secret derivation is deferred to ClientFlight3.generateMessages()
    // because extended master secret (RFC 7627) requires ClientKeyExchange to be in the buffer
    // The buffer needs: ClientHello + Server messages + Certificate (client) + ClientKeyExchange

    // Send Flight 5 (Certificate + ClientKeyExchange + ChangeCipherSpec + Finished)
    // This uses ClientFlight3 but without ClientHello since we already sent that
    final flight5 = ClientFlight3(
      dtlsContext: dtlsContext,
      cipherContext: cipherContext,
      recordLayer: recordLayer,
      cipherSuites: cipherSuites,
      includeClientHello: false,
      sendEmptyCertificate: _certificateRequested,
    );

    final messages = await flight5.generateMessages();
    flightManager.addFlight(flight5, messages);

    _state = ClientHandshakeState.waitingForServerFinished;
  }

  /// Process Finished from server
  Future<void> _processFinished(Uint8List data,
      {Uint8List? fullMessage}) async {
    if (_state != ClientHandshakeState.waitingForServerFinished) {
      // DTLS retransmission - silently ignore duplicate Finished messages
      // This can happen if our final ACK was lost and server retransmits
      _log.fine('Ignoring retransmitted Finished in state $_state');
      return;
    }

    // Parse Finished message
    final finished = Finished.parse(data);

    // Verify the verify_data matches expected value
    final isValid = KeyDerivation.verifyFinishedMessage(
      dtlsContext,
      finished.verifyData,
      false, // isClient=false for verifying server's Finished
    );

    if (!isValid) {
      _state = ClientHandshakeState.failed;
      throw StateError('Finished message verification failed');
    }

    dtlsContext.addHandshakeMessage(fullMessage ?? data);

    // Mark Flight 5 as complete
    flightManager.moveToNextFlight();

    dtlsContext.handshakeComplete = true;

    _state = ClientHandshakeState.completed;
  }

  /// Generate ECDH key pair only (without deriving master secret)
  Future<void> _generateKeyPairOnly() async {
    final curve = cipherContext.namedCurve;
    if (curve == null) {
      throw StateError('Named curve not selected');
    }

    // Generate key pair based on selected curve
    final keyPair = await generateEcdhKeypair(curve);
    cipherContext.localKeyPair = keyPair;
    cipherContext.localPublicKey = await serializePublicKey(keyPair, curve);

    // Compute shared secret if we have remote public key
    if (cipherContext.remotePublicKey != null) {
      final sharedSecret = await computePreMasterSecret(
        keyPair,
        cipherContext.remotePublicKey!,
        curve,
      );
      dtlsContext.preMasterSecret = sharedSecret;
    }
  }

  /// Check if handshake is complete
  bool get isComplete => _state == ClientHandshakeState.completed;

  /// Check if handshake failed
  bool get isFailed => _state == ClientHandshakeState.failed;

  /// Check if server requested client certificate
  bool get certificateRequested => _certificateRequested;

  /// Whether a ChangeCipherSpec from the server belongs here: only once our
  /// flight 5 is out and its keys exist, right before the server's Finished.
  bool get expectsChangeCipherSpec =>
      _state == ClientHandshakeState.waitingForServerFinished;

  /// Fails the handshake.
  Never _fail(String reason) {
    _state = ClientHandshakeState.failed;
    throw StateError('DTLS handshake failed: $reason');
  }

  /// What the ServerKeyExchange signature covers (RFC 4492 Section 5.4):
  /// client_random + server_random + ServerECDHParams.
  Uint8List _serverKeyExchangeSignedData(ServerKeyExchange ske) {
    final clientRandom = dtlsContext.localRandom!;
    final serverRandom = dtlsContext.remoteRandom!;
    return Uint8List.fromList([
      ...clientRandom,
      ...serverRandom,
      3, // ECCurveType: named_curve
      (ske.curve.value >> 8) & 0xFF,
      ske.curve.value & 0xFF,
      ske.publicKey.length,
      ...ske.publicKey,
    ]);
  }
}
