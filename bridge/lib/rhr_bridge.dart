// Device-side bridge. Call RhrBridge.start() early in main() (guard with
// kDebugMode in Flutter apps). Discovers the local Dart VM Service, dials out
// to the relay, and serves TCP tunnel channels pointed at the VM service.
//
// Pure Dart on purpose - no Flutter dependency, so it can be exercised in a
// desktop `dart run` during development.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:developer' show Service;
import 'dart:io';

import 'package:web_socket_channel/io.dart';
import 'package:webrtc_dart/webrtc_dart.dart';

import 'direct_signaling.dart';
import 'direct_webrtc.dart';
import 'tunnel.dart';

class RhrBridge {
  RhrBridge._(
    this.relayUrl,
    this.sessionCode,
    this.assetStoreId,
    this.compatibility,
    this.preferDirect,
    [this.externalVmUri, this.host]
  );

  final String relayUrl;
  final String sessionCode;
  final String? assetStoreId;
  final Map<String, dynamic>? compatibility;
  final bool preferDirect;

  /// Top-level kind announced in the hello: "player" | "app" | "connector"
  /// (the dev-side gate routes on this).
  final String? host;

  /// When set, this bridge tunnels a DIFFERENT app's VM service (the M3
  /// connector mode: the target app's debug door was discovered out of
  /// band, e.g. via mDNS) instead of this isolate's own Service.getInfo().
  final Uri? externalVmUri;
  final _sockets = <int, Socket>{};
  final _subs = <int, StreamSubscription<Uint8List>>{};
  final _flow = FlowControl();
  // Data frames can arrive while the VM-service TCP connect for their channel
  // is still in flight; they buffer here until the socket is ready.
  final _pending = <int, List<int>>{};
  IOWebSocketChannel? _ws;
  bool _stopped = false;
  Completer<void>? _wake;

  static RhrBridge? _instance;

  /// The running bridge, if [start] has been called.
  static RhrBridge? get instance => _instance;

  /// Gracefully closes the relay connection and stops reconnecting. Used by
  /// the desktop fake device on SIGTERM so the relay sees a clean close
  /// (equivalent to a phone process dying, minus the abrupt TCP drop).
  Future<void> dispose() async {
    _stopped = true;
    try {
      await _ws?.sink.close(1000, 'dispose');
    } catch (_) {}
    if (identical(_instance, this)) _instance = null;
  }

  /// Starts the bridge and keeps it connected (with backoff) forever.
  /// [relayUrl] like `ws://relay.example.com:8123`.
  /// [assetStoreId] and [compatibility] are announced in the info message so
  /// the dev CLI's compatibility gate can pass on desktop/testing devices
  /// (the Android player supplies these from BuildConfig).
  static RhrBridge start({
    required String relayUrl,
    required String sessionCode,
    String? assetStoreId,
    Map<String, dynamic>? compatibility,
    bool preferDirect = false,
  }) {
    final existing = _instance;
    if (existing != null && !existing._stopped) return existing;
    final b = RhrBridge._(
      relayUrl,
      sessionCode,
      assetStoreId,
      compatibility,
      preferDirect,
    );
    _instance = b;
    unawaited(b._run());
    return b;
  }

  /// Connector mode: tunnel a DIFFERENT app's VM service (discovered out of
  /// band — the target app contains no rhr code at all). [vmUri] points at
  /// the target's debug door, e.g. http://127.0.0.1:42595/<auth>/.
  static RhrBridge startExternal({
    required String relayUrl,
    required String sessionCode,
    required Uri vmUri,
    String? assetStoreId,
    Map<String, dynamic>? compatibility,
    bool preferDirect = false,
    String host = 'connector',
  }) {
    final existing = _instance;
    if (existing != null && !existing._stopped) return existing;
    final b = RhrBridge._(
      relayUrl,
      sessionCode,
      assetStoreId,
      compatibility,
      preferDirect,
      vmUri,
      host,
    );
    _instance = b;
    unawaited(b._run());
    return b;
  }

  Future<void> _run() async {
    // The VM service can take a moment to come up in a freshly launched app.
    Uri? vm;
    while (vm == null) {
      vm = externalVmUri ?? (await Service.getInfo()).serverUri;
      if (vm == null) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    final vmUri = vm;
    var backoff = const Duration(seconds: 1);

    while (!_stopped) {
      try {
        final ws = IOWebSocketChannel.connect(
          '$relayUrl/s/$sessionCode/device',
          pingInterval: const Duration(seconds: 20),
        );
        _ws = ws;
        await ws.ready;
        backoff = const Duration(seconds: 1);
        _log('connected to relay, vm=$vmUri');

        DirectWebRtcPeer? direct;
        var directReady = false;
        var directStarted = false;

        Future<void> sendFrame(Uint8List frame) async {
          final peer = direct;
          if (!directReady || peer == null) {
            ws.sink.add(frame);
            return;
          }
          try {
            await peer.send(frame);
          } catch (_) {
            directReady = false;
            try {
              ws.sink.add(frame);
            } on StateError {
              // The relay can be closing at the same time as the direct peer.
            }
          }
        }

        void handleFrame(Object raw) {
          final f = decodeFrame(raw as List<int>);
          switch (f.op) {
            case opOpen:
              _pending[f.channel] = [];
              unawaited(_openChannel(ws, f.channel, vmUri, sendFrame));
            case opData:
              final sock = _sockets[f.channel];
              if (sock != null) {
                sock.add(f.payload);
              } else {
                _pending[f.channel]?.addAll(f.payload);
              }
              // Ack on receipt: buffered bytes are bounded by the window.
              unawaited(sendFrame(encodeAck(f.channel, f.payload.length)));
            case opAck:
              _flow.acked(f.channel, decodeAckCount(f.payload));
            case opClose:
              _pending.remove(f.channel);
              _flow.forget(f.channel);
              _subs.remove(f.channel)?.cancel();
              _sockets.remove(f.channel)?.destroy();
          }
        }

        ws.sink.add(
          jsonEncode({
            't': 'info',
            'vm': vmUri.toString(),
            'host': host,
            if (assetStoreId != null) 'assetStoreId': assetStoreId,
            if (compatibility != null) 'compatibility': compatibility,
          }),
        );

        if (preferDirect) {
          direct = DirectWebRtcPeer(
            onSignal: (signal) {
              try {
                ws.sink.add(signal.encode());
              } on StateError {
                // Relay shutdown is handled by the outer reconnect loop.
              }
            },
          );
          direct.messages.listen(handleFrame);
          direct.connectionStates.listen((state) {
            if (state == PeerConnectionState.failed ||
                state == PeerConnectionState.disconnected ||
                state == PeerConnectionState.closed) {
              directReady = false;
            }
          });
        }

        await for (final msg in ws.stream) {
          if (msg is String) {
            if (preferDirect &&
                direct != null &&
                !directStarted &&
                _isHello(msg)) {
              directStarted = true;
              final peer = direct;
              unawaited(
                peer
                    .startOffer()
                    .then<void>((_) async {
                      try {
                        await peer.waitUntilOpen(
                          timeout: const Duration(seconds: 20),
                        );
                        directReady = true;
                        _log('direct WebRTC/STUN path is ready');
                      } catch (error) {
                        _log(
                          'direct WebRTC path unavailable; using relay: $error',
                        );
                      }
                    })
                    .catchError((error) {
                      _log('direct WebRTC offer failed; using relay: $error');
                    }),
              );
            }
            if (direct != null) {
              final peer = direct;
              try {
                final signal = DirectSignal.decode(msg);
                switch (signal) {
                  case DirectDescriptionSignal(:final type):
                    if (type == 'answer') {
                      unawaited(peer.acceptAnswer(signal));
                    }
                  case DirectCandidateSignal():
                    unawaited(peer.addCandidate(signal));
                  case DirectEndSignal():
                    break;
                }
              } on FormatException {
                // Other text is the normal application-level control channel.
              }
            }
            continue;
          }
          handleFrame(msg);
        }
        await direct?.close();
        direct = null;
        directReady = false;
      } catch (e) {
        _log('relay connection error: $e');
      }
      // Snapshot: destroy() fires onDone handlers that remove entries from
      // _sockets, which would be concurrent modification mid-iteration.
      for (final s in _sockets.values.toList()) {
        s.destroy();
      }
      _sockets.clear();
      _pending.clear();
      for (final s in _subs.values.toList()) {
        s.cancel();
      }
      _subs.clear();
      _flow.clear();
      if (_stopped) break;
      // Backoff, but let kick() cut it short (e.g. app came back to
      // foreground after Android froze us — reconnect immediately).
      final wake = _wake = Completer<void>();
      await Future.any([Future<void>.delayed(backoff), wake.future]);
      _wake = null;
      backoff *= 2;
      if (backoff > const Duration(seconds: 30)) {
        backoff = const Duration(seconds: 30);
      }
    }
  }

  Future<void> _openChannel(
    IOWebSocketChannel ws,
    int channel,
    Uri vm,
    Future<void> Function(Uint8List frame) sendFrame,
  ) async {
    try {
      final sock = await Socket.connect(vm.host, vm.port);
      final buffered = _pending.remove(channel);
      if (buffered == null) {
        // Channel was closed while we were connecting.
        sock.destroy();
        return;
      }
      sock.done.catchError((_) {});
      if (buffered.isNotEmpty) sock.add(buffered);
      _sockets[channel] = sock;
      late final StreamSubscription<Uint8List> sub;
      sub = sock.listen(
        (data) {
          unawaited(sendFrame(encodeFrame(opData, channel, data)));
          if (_flow.sent(channel, data.length)) {
            sub.pause();
            _flow.onWindowOpen(channel, sub.resume);
          }
        },
        onDone: () {
          _subs.remove(channel);
          _flow.forget(channel);
          if (_sockets.remove(channel) != null) {
            unawaited(sendFrame(encodeFrame(opClose, channel)));
          }
        },
        onError: (_) {
          _subs.remove(channel);
          _flow.forget(channel);
          if (_sockets.remove(channel) != null) {
            unawaited(sendFrame(encodeFrame(opClose, channel)));
          }
        },
      );
      _subs[channel] = sub;
    } catch (e) {
      _log('channel $channel: VM service connect failed: $e');
      unawaited(sendFrame(encodeFrame(opClose, channel)));
    }
  }

  /// Skips any pending reconnect backoff. Call on app resume.
  void kick() {
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  void stop() {
    _stopped = true;
    _ws?.sink.close();
    if (identical(_instance, this)) _instance = null;
  }

  void _log(String m) => print('[rhr_bridge] $m');

  static bool _isHello(String message) {
    try {
      final decoded = jsonDecode(message);
      return decoded is Map<String, dynamic> && decoded['t'] == 'hello';
    } on FormatException {
      return false;
    }
  }
}
