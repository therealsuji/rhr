import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart' show ECPrivateKey, ECPublicKey;
import 'package:webrtc_dart/webrtc_dart.dart'
    show CertificateInfo, generateSelfSignedCertificate;

/// A single-session relay embedded in `rhr run` for same-LAN transfers.
///
/// It deliberately mirrors the public relay's interface, so every byte above
/// this seam uses the same tunnel implementation regardless of transport.
///
/// The phone reaches it over TLS with a certificate minted for this run. No CA
/// can vouch for a laptop's LAN address, so the connection link carries the
/// certificate's SHA-256 ([certificatePin]) and the phone accepts nothing
/// else. In plaintext, anyone on the same Wi-Fi could read the session code
/// off the wire and take the phone's VM service. This process dials its own
/// end over loopback, where nothing crosses a network.
final class LocalRelay {
  LocalRelay._(
    this._lanServer,
    this._loopbackServer,
    this.sessionCode,
    this.lanAddress,
    this.certificatePin,
  );

  final HttpServer _lanServer;
  final HttpServer _loopbackServer;
  final String sessionCode;
  final InternetAddress lanAddress;

  /// SHA-256 of the LAN certificate, base64url without padding.
  final String certificatePin;

  WebSocket? _device;
  WebSocket? _host;
  String? _lastDeviceInfo;
  final _subscriptions = <WebSocket, StreamSubscription<Object?>>{};

  int get activeSubscriptionCount => _subscriptions.length;
  String get loopbackUrl => 'ws://127.0.0.1:${_loopbackServer.port}';
  String get advertisedUrl => 'wss://${lanAddress.address}:${_lanServer.port}';

  static Future<LocalRelay?> start(
    String sessionCode, {
    InternetAddress? advertisedAddress,
  }) async {
    final address = advertisedAddress ?? await _preferredLanAddress();
    if (address == null) return null;
    final (:context, :pin) = await _mintCertificate();
    // Bound to the advertised address only, not every interface: a VPN or a
    // public interface has no business reaching a session meant for the
    // phone on this LAN.
    final lan = await HttpServer.bindSecure(address, 0, context);
    final loopback = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final relay = LocalRelay._(lan, loopback, sessionCode, address, pin);
    relay._serve(lan);
    relay._serve(loopback);
    return relay;
  }

  /// A self-signed P-256 certificate for this run, and its pin.
  static Future<({SecurityContext context, String pin})>
  _mintCertificate() async {
    final now = DateTime.now().toUtc();
    final pair = await generateSelfSignedCertificate(
      info: CertificateInfo(
        commonName: 'rhr local relay',
        // A phone whose clock runs behind must not see a certificate from
        // the future. The pin, not the dates, is what the phone trusts.
        notBefore: now.subtract(const Duration(days: 1)),
        notAfter: now.add(const Duration(days: 7)),
      ),
    );
    final context = SecurityContext()
      ..useCertificateChainBytes(
        utf8.encode(_pem('CERTIFICATE', pair.certificate)),
      )
      ..usePrivateKeyBytes(
        utf8.encode(
          _pem('EC PRIVATE KEY', _sec1(pair.privateKey, pair.publicKey)),
        ),
      );
    final pin = base64Url
        .encode(sha256.convert(pair.certificate).bytes)
        .replaceAll('=', '');
    return (context: context, pin: pin);
  }

  static String _pem(String label, List<int> der) {
    final body = base64.encode(der);
    final lines = [
      for (var i = 0; i < body.length; i += 64)
        body.substring(i, (i + 64).clamp(0, body.length)),
    ];
    return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
  }

  /// The P-256 key as SEC 1 `ECPrivateKey` DER (RFC 5915), the form
  /// `EC PRIVATE KEY` PEM carries. Every field has a fixed size for this
  /// curve, so the encoding is spelled out rather than built.
  static Uint8List _sec1(ECPrivateKey privateKey, ECPublicKey publicKey) {
    final d = privateKey.d!.toRadixString(16).padLeft(64, '0');
    final scalar = [
      for (var i = 0; i < 64; i += 2)
        int.parse(d.substring(i, i + 2), radix: 16),
    ];
    final point = publicKey.Q!.getEncoded(false); // 0x04 || X || Y
    return Uint8List.fromList([
      0x30, 0x77, // SEQUENCE
      0x02, 0x01, 0x01, // version 1
      0x04, 0x20, ...scalar, // privateKey
      0xa0, 0x0a, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07,
      0xa1, 0x44, 0x03, 0x42, 0x00, ...point, // publicKey
    ]);
  }

  void _serve(HttpServer server) {
    server.listen((request) async {
      if (request.uri.path == '/healthz') {
        request.response
          ..statusCode = HttpStatus.ok
          ..write('ok');
        await request.response.close();
        return;
      }
      final segments = request.uri.pathSegments;
      if (segments.length != 3 ||
          segments[0] != 's' ||
          segments[1] != sessionCode ||
          (segments[2] != 'device' && segments[2] != 'host') ||
          !WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      // OkHttp rejects Dart's permessage-deflate response because it does not
      // offer that extension. Tunnel frames are already binary chunks, so
      // WebSocket compression would add CPU cost without helping transfers.
      // One host per phone, like the public relay: a second host end
      // is refused rather than allowed to evict the first.
      if (segments[2] == 'host' && _host != null) {
        request.response
          ..statusCode = HttpStatus.conflict
          ..write('busy: another host is connected to this device');
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(
        request,
        compression: CompressionOptions.compressionOff,
      );
      if (segments[2] == 'device') {
        _attachDevice(socket);
      } else {
        _attachHost(socket);
      }
    });
  }

  void _attachDevice(WebSocket socket) {
    _device?.close(4001, 'replaced by new connection');
    _device = socket;
    _lastDeviceInfo = null;
    _subscriptions[socket] = socket.listen(
      (message) {
        if (message is String) {
          try {
            final control = jsonDecode(message);
            if (control is Map<String, dynamic> && control['t'] == 'info') {
              _lastDeviceInfo = message;
            }
          } on FormatException {
            // Forward unrecognized messages without replacing the announcement.
          }
        }
        _safeAdd(_host, message);
      },
      onDone: () {
        _subscriptions.remove(socket);
        _deviceClosed(socket);
      },
      onError: (_) {
        _subscriptions.remove(socket);
        _deviceClosed(socket);
      },
    );
    final info = _lastDeviceInfo;
    if (info != null) _safeAdd(_host, info);
  }

  void _attachHost(WebSocket socket) {
    _host = socket;
    _subscriptions[socket] = socket.listen(
      (message) => _safeAdd(_device, message),
      onDone: () {
        _subscriptions.remove(socket);
        if (identical(_host, socket)) _host = null;
      },
      onError: (_) {
        _subscriptions.remove(socket);
        if (identical(_host, socket)) _host = null;
      },
    );
    final info = _lastDeviceInfo;
    if (info != null) _safeAdd(socket, info);
  }

  void _deviceClosed(WebSocket socket) {
    if (!identical(_device, socket)) return;
    _device = null;
    _lastDeviceInfo = null;
    _host?.close(4000, 'device disconnected');
    _host = null;
  }

  static void _safeAdd(WebSocket? socket, Object? message) {
    if (socket == null || message == null) return;
    try {
      socket.add(message);
    } on StateError {
      // The peer closed between lookup and send; its listener performs cleanup.
    }
  }

  Future<void> close() async {
    for (final subscription in _subscriptions.values.toList()) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _device?.close(1001, 'local relay stopped');
    await _host?.close(1001, 'local relay stopped');
    await _lanServer.close(force: true);
    await _loopbackServer.close(force: true);
  }

  static Future<InternetAddress?> _preferredLanAddress() async {
    final candidates = <({String interface, InternetAddress address})>[];
    for (final interface in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    )) {
      for (final address in interface.addresses) {
        if (_isPrivateIpv4(address.address)) {
          candidates.add((interface: interface.name, address: address));
        }
      }
    }
    candidates.sort((a, b) {
      int rank(String name) {
        if (name == 'en0' || name == 'wlan0' || name == 'Wi-Fi') return 0;
        if (name.startsWith('en')) return 1;
        if (name.startsWith('utun') || name.startsWith('tun')) return 3;
        return 2;
      }

      return rank(a.interface).compareTo(rank(b.interface));
    });
    return candidates.firstOrNull?.address;
  }

  static bool _isPrivateIpv4(String address) {
    final parts = address.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((part) => part == null)) return false;
    final a = parts[0]!;
    final b = parts[1]!;
    return a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168);
  }
}
