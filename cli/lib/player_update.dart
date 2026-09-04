// Over-the-wire player update: when the compatibility gate blocks, the CLI
// builds a matching generic player with the local Flutter SDK and streams the
// APK to the device over the live session transport. The player installs it
// via Android's PackageInstaller and rejoins the session.
//
// Wire protocol (dev → device unless noted):
//   {"t":"update_begin","id":N,"size":S,"sha256":H}   announce the transfer
//   {"t":"update_status","id":N,"state":...}          device → dev acks:
//       "ready"         updater accepted the transfer, chunks may flow
//       "committed"     APK verified and handed to PackageInstaller
//       "pending_user"  Android is showing the install confirmation sheet
//       "failure"       verification or install failed ("message" says why)
//   binary opUpdateData frames                        APK chunks, flow-
//       controlled with opAck on the transfer id (high-bit range, so tunnel
//       channel ids can never collide)
//   {"t":"update_commit","id":N}                      transfer complete
//
// A player without the updater never answers "ready" — that is the supported
// downgrade signal, surfaced as a clear "update it manually once" error.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:rhr_bridge/tunnel.dart';

import 'player_builder.dart';
import 'relay_race.dart';

/// Locates the `player/` template that ships beside the CLI in the rhr
/// checkout. The package uri survives every launch style (dart run, the
/// pub-built executable under .dart_tool/pub, pub global activate);
/// Platform.script does not, so it is only the fallback.
Future<String> resolvePlayerTemplate() async {
  final lib = await Isolate.resolvePackageUri(
    Uri.parse('package:rhr_cli/player_update.dart'),
  );
  final roots = [
    if (lib != null) File(lib.toFilePath()).parent.parent.parent,
    File.fromUri(Platform.script).parent.parent.parent,
  ];
  for (final root in roots) {
    final template = '${root.path}/player';
    if (File('$template/pubspec.yaml').existsSync()) return template;
  }
  throw StateError(
    'could not locate the player template next to the rhr checkout '
    '(looked in ${roots.map((r) => r.path).join(', ')})',
  );
}

/// Builds (or reuses a cached) arm64-only debug player APK for [project]:
/// the player template plus the project's native plugins and permissions,
/// compiled with the project's Flutter SDK. The cache key is the framework
/// revision plus the project's plugin/permission profile, so the same SDK
/// and dependency set never builds twice, while adding a native plugin or
/// switching SDKs produces a fresh player.
Future<File> buildUpdatePlayerApk({
  required String project,
  required String template,
  required String frameworkRevision,
  String flutterExecutable = 'flutter',
  String? cacheDir,
  void Function(String line)? onLog,
}) async {
  final log = onLog ?? stderr.writeln;
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
  final cache = Directory(cacheDir ?? '$home/.rhr/player-cache');
  final profileId = projectPlayerProfileId(project);
  final cached = File('${cache.path}/$frameworkRevision-$profileId-arm64.apk');
  if (cached.existsSync() && cached.lengthSync() > 0) {
    log('[rhr] using cached update player ${cached.path}');
    return cached;
  }

  log(
    '[rhr] building the update player for this project '
    '(first time for this SDK + plugin set — this takes a few minutes)…',
  );
  cache.createSync(recursive: true);
  return buildProjectPlayer(
    project: project,
    template: template,
    output: cached.path,
    flutterExecutable: flutterExecutable,
    targetPlatform: 'android-arm64',
  );
}

final class PlayerUpdateFailure implements Exception {
  PlayerUpdateFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Terminal outcome of a streamed update, as reported by the device.
enum PlayerUpdateOutcome {
  /// PackageInstaller accepted the session; the install proceeds without
  /// further user action (Android 12+ self-update) and kills the player.
  committed,

  /// Android is showing the install confirmation sheet on the device.
  pendingUser,

  /// A foreign package (kind: app) finished installing; the player
  /// reported STATUS_SUCCESS from the result broadcast.
  installed,
}

/// Who receives the APK: `player` (the default — a self-update that may
/// kill the device process) or `app` (a foreign package — the tier-2
/// wrapped app — where the player survives and the system sheet's result
/// is reported back as the terminal `installed` state).
enum UpdateKind { player, app }

/// Streams one APK over the session transport. Construct it before sending,
/// route every incoming `update_status` message into [handleMessage] (the
/// transport stream has a single listener, owned by the caller), then await
/// [send].
final class PlayerUpdateSender {
  PlayerUpdateSender(
    this._transport, {
    int chunkBytes = 64 * 1024,
    this.kind = UpdateKind.player,
    this.target = '',
  }) : _chunkBytes = chunkBytes,
       _transferId = updateTransferIdBase | 1;

  final SessionTransport _transport;
  final UpdateKind kind;

  /// Package name for kind: app (validated on-device against the APK).
  final String target;
  final int _chunkBytes;
  final int _transferId;
  final _flow = FlowControl();
  // Status messages queue until [send] consumes them, so nothing reported by
  // the device between two waits (e.g. a failure mid-stream) is ever lost.
  final _pendingStates = <Map<String, dynamic>>[];
  Completer<void>? _stateArrived;
  var _closed = false;

  /// Feed one decoded text message from the transport stream. Returns true
  /// when the message belonged to this transfer (callers skip their own
  /// handling for those). opAck binary frames for the transfer id must also
  /// be routed here via [handleAck].
  bool handleMessage(Map<String, dynamic> message) {
    if (message['t'] != 'update_status' || message['id'] != _transferId) {
      return false;
    }
    _pendingStates.add(message);
    _stateArrived?.complete();
    _stateArrived = null;
    return true;
  }

  /// Feed acked byte counts for this transfer (opAck frames whose channel
  /// field is in the update transfer id range).
  void handleAck(int channel, int bytes) {
    if (channel == _transferId) _flow.acked(channel, bytes);
  }

  static bool isUpdateAck(int channel) => channel & updateTransferIdBase != 0;

  Future<PlayerUpdateOutcome> send(
    File apk, {
    void Function(int sentBytes, int totalBytes)? onProgress,
  }) async {
    await _transport.payloadReady;
    final size = apk.lengthSync();
    final digest = await sha256.bind(apk.openRead()).first;
    _transport.sendControl(
      jsonEncode({
        't': 'update_begin',
        'id': _transferId,
        'size': size,
        'sha256': digest.toString(),
        'kind': kind.name,
        if (target.isNotEmpty) 'target': target,
      }),
    );
    await _awaitState(
      {'ready'},
      timeout: const Duration(seconds: 15),
      onTimeout: 'the player did not acknowledge the update — it predates '
          'self-update; reinstall it manually once',
    );

    var sent = 0;
    await for (final chunk in apk.openRead()) {
      final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      var offset = 0;
      while (offset < bytes.length) {
        final end = (offset + _chunkBytes).clamp(0, bytes.length);
        final piece = Uint8List.sublistView(bytes, offset, end);
        await _transport.sendPayload(
          encodeFrame(opUpdateData, _transferId, piece),
        );
        sent += piece.length;
        onProgress?.call(sent, size);
        if (_flow.sent(_transferId, piece.length)) {
          final window = Completer<void>();
          _flow.onWindowOpen(_transferId, window.complete);
          await window.future.timeout(
            const Duration(seconds: 60),
            onTimeout: () => throw PlayerUpdateFailure(
              'update transfer stalled — the device stopped acking',
            ),
          );
        }
        offset = end;
      }
    }

    _transport.sendControl(
      jsonEncode({'t': 'update_commit', 'id': _transferId}),
    );
    if (kind == UpdateKind.app) {
      // Foreign package: the player process survives, the system sheet
      // waits for a user tap, and the result broadcast carries the
      // terminal state. Wait generously — the tester may be away.
      await _awaitState(
        {'installed'},
        timeout: const Duration(minutes: 10),
        onTimeout: 'the wrapped app install was not confirmed on the device',
      );
      return PlayerUpdateOutcome.installed;
    }
    final state = await _awaitState(
      {'committed', 'pending_user'},
      timeout: const Duration(minutes: 2),
      onTimeout: 'the player never confirmed the install',
    );
    return state == 'pending_user'
        ? PlayerUpdateOutcome.pendingUser
        : PlayerUpdateOutcome.committed;
  }

  Future<String> _awaitState(
    Set<String> accepted, {
    required Duration timeout,
    required String onTimeout,
  }) async {
    final elapsed = Stopwatch()..start();
    while (true) {
      while (_pendingStates.isEmpty) {
        if (_closed) {
          throw PlayerUpdateFailure('session ended before the player answered');
        }
        final remaining = timeout - elapsed.elapsed;
        if (remaining <= Duration.zero) throw PlayerUpdateFailure(onTimeout);
        final arrived = _stateArrived = Completer<void>();
        try {
          await arrived.future.timeout(remaining);
        } on TimeoutException {
          throw PlayerUpdateFailure(onTimeout);
        }
      }
      final status = _pendingStates.removeAt(0);
      final state = status['state'];
      if (state is! String) continue;
      if (accepted.contains(state)) return state;
      if (state == 'failure') {
        throw PlayerUpdateFailure(
          'player update failed on the device: '
          '${status['message'] ?? 'unknown error'}',
        );
      }
      // Other states ("receiving") are informational; keep waiting.
    }
  }

  void close() {
    _closed = true;
    _flow.clear();
    _stateArrived?.complete();
    _stateArrived = null;
  }
}
