import 'dart:async';
import 'dart:io';

/// A single-session relay embedded in `rhr run` for same-LAN transfers.
///
/// It deliberately mirrors the public relay's interface, so every byte above
/// this seam uses the same tunnel implementation regardless of transport.
final class LocalRelay {
  LocalRelay._(this._server, this.sessionCode, this.lanAddress);

  final HttpServer _server;
  final String sessionCode;
  final InternetAddress lanAddress;

  WebSocket? _device;
  WebSocket? _dev;
  String? _lastDeviceInfo;
  final _subscriptions = <WebSocket, StreamSubscription<Object?>>{};

  int get port => _server.port;
  int get activeSubscriptionCount => _subscriptions.length;
  String get loopbackUrl => 'ws://127.0.0.1:$port';
  String get advertisedUrl => 'ws://${lanAddress.address}:$port';

  static Future<LocalRelay?> start(
    String sessionCode, {
    InternetAddress? advertisedAddress,
  }) async {
    final address = advertisedAddress ?? await _preferredLanAddress();
    if (address == null) return null;
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final relay = LocalRelay._(server, sessionCode, address);
    relay._serve();
    return relay;
  }

  void _serve() {
    _server.listen((request) async {
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
          (segments[2] != 'device' && segments[2] != 'dev') ||
          !WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      // OkHttp rejects Dart's permessage-deflate response because it does not
      // offer that extension. Tunnel frames are already binary chunks, so
      // WebSocket compression would add CPU cost without helping transfers.
      final socket = await WebSocketTransformer.upgrade(
        request,
        compression: CompressionOptions.compressionOff,
      );
      if (segments[2] == 'device') {
        _attachDevice(socket);
      } else {
        _attachDev(socket);
      }
    });
  }

  void _attachDevice(WebSocket socket) {
    _device?.close(4001, 'replaced by new connection');
    _device = socket;
    _subscriptions[socket] = socket.listen(
      (message) {
        if (message is String) _lastDeviceInfo = message;
        _safeAdd(_dev, message);
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
    if (info != null) _safeAdd(_dev, info);
  }

  void _attachDev(WebSocket socket) {
    _dev?.close(4001, 'replaced by new connection');
    _dev = socket;
    _subscriptions[socket] = socket.listen(
      (message) => _safeAdd(_device, message),
      onDone: () {
        _subscriptions.remove(socket);
        if (identical(_dev, socket)) _dev = null;
      },
      onError: (_) {
        _subscriptions.remove(socket);
        if (identical(_dev, socket)) _dev = null;
      },
    );
    final info = _lastDeviceInfo;
    if (info != null) _safeAdd(socket, info);
  }

  void _deviceClosed(WebSocket socket) {
    if (!identical(_device, socket)) return;
    _device = null;
    _lastDeviceInfo = null;
    _dev?.close(4000, 'device disconnected');
    _dev = null;
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
    await _dev?.close(1001, 'local relay stopped');
    await _server.close(force: true);
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
