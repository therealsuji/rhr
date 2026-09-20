// rhr custom-device `runDebug` helper.
//
// A Flutter custom device drives a run through lifecycle commands. This is the
// runDebug command: it opens the relay tunnel to the player, waits for the
// phone to announce its Dart VM Service URI, exposes that URI on a localhost
// port, and prints it to STDOUT in the exact line Flutter's ProtocolDiscovery
// scans for:
//
//   The Dart VM service is listening on http://127.0.0.1:<port>/<auth>/
//
// Flutter then connects to that localhost port and drives hot reload / restart
// itself — so "save in VS Code" reloads the QA phone with zero rhr involvement
// in the reload path. We declare NO port forwarding in the device config; this
// process already presents the service on 127.0.0.1, so Flutter connects
// straight to it.
//
// Usage: dart run device_run.dart --relay <wss://...> --code <session>
//
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:rhr_bridge/session_code.dart';
import 'package:rhr_bridge/tunnel.dart';
import 'package:rhr_cli/asset_sync.dart';
import 'package:rhr_cli/direct_session_transport.dart';
import 'package:rhr_cli/flutter_compatibility.dart';
import 'package:rhr_cli/relay_config.dart';
import 'package:rhr_cli/relay_race.dart';
import 'package:rhr_cli/terminal_qr.dart';

Future<void> main(List<String> args) async {
  String? relay;
  String? code;
  var preferDirect = true;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--relay':
        relay = args[++i];
      case '--code':
        code = args[++i];
      case '--direct':
        preferDirect = true;
      case '--no-direct':
        preferDirect = false;
    }
  }
  relay ??= Platform.environment['RHR_RELAY'];
  code ??= Platform.environment['RHR_SESSION_CODE'];
  if (relay == null) {
    stderr.writeln(
      'usage: rhr device-run --relay <wss://...> [--code <session>]',
    );
    exit(64);
  }
  // Mint a fresh random code each run (Expo-style): unique, unguessable, and
  // avoids leftover sessions on the shared public relay.
  code ??= mintRhrSessionCode();

  // Show the QR the tester scans. Keep the payload SMALL so the QR stays small:
  // when the relay is the player's built-in default, encode just the bare code
  // (the player's scanner falls back to its default relay for a non-JSON
  // payload). Only when a custom relay is used do we encode the full {relay,
  // code} JSON. Printed to stderr so it never pollutes the stdout line Flutter's
  // ProtocolDiscovery parses.
  final payload = relay == defaultPublicRelay
      ? code
      : jsonEncode({'relay': relay, 'code': code});
  _printQr(payload, code);

  // Watchdog: exit if our parent (the `flutter run` that spawned us) dies.
  // stdin-close alone is unreliable — when a VS Code / flutter run stops
  // abruptly it can leave us orphaned, still holding the relay's single dev
  // slot and causing phantom "retrying" flaps. Poll the parent pid; when it's
  // gone (reparented to init/1), quit.
  final origPpid = _ppid();
  if (origPpid != null && origPpid != 1) {
    Timer.periodic(const Duration(seconds: 3), (t) {
      final now = _ppid();
      if (now == null || now == 1 || now != origPpid) {
        stderr.writeln('[rhr] parent flutter process exited — shutting down.');
        exit(0);
      }
    });
  }

  // Reconnect loop: the phone may not be connected yet, or the relay may drop.
  // Flutter keeps this process alive for the whole run, so we keep trying until
  // we hand it a live VM service, then keep the tunnel open until it exits.
  while (true) {
    final bool done;
    try {
      done = await _serve(relay, code, preferDirect);
    } on DirectTransportFailure catch (failure) {
      stderr.writeln('[rhr] direct connection failed: $failure');
      exit(69);
    }
    if (done) break; // Flutter's run ended (stdin closed) — stop.
    await Future<void>.delayed(const Duration(seconds: 2));
  }
}

/// When the player signals that the guest kernel's DevFS is ready, push the
/// project's asset bundle through that same DevFS and report real progress to
/// the native phone overlay. Only then tell the user it is safe to restart.
///
/// We CANNOT auto-hot-restart from here under an IDE, and this is verified, not
/// assumed: there is no hot-restart VM Service RPC (the isolate exposes only
/// reassemble/reload + exit); SIGUSR2 works for a terminal `flutter run` but
/// kills an IDE debug-adapter process; and ext.flutter.exit terminates the run
/// instead of relaunching. Hot restart lives solely in the Flutter tool/adapter
/// (the IDE's ⟳ button or terminal `R`). The supported IDE flow leaves this
/// explicit: after sync the native
/// player overlay asks the developer to use Flutter's normal Hot Restart.
Future<void> _syncAssetsOnReady(
  Future<void> ready,
  Uri vmService,
  String project,
  SessionTransport transport,
  String assetStoreId,
) async {
  try {
    await syncAssets(
      vmService: vmService,
      project: project,
      assetStoreId: assetStoreId,
      forceResync: Platform.environment['RHR_RESYNC_ASSETS'] == '1',
      devFsReady: ready,
      onProgress: (phase, done, total) {
        transport.sendControl(
          jsonEncode({
            't': 'progress',
            'phase': phase,
            'done': done,
            'total': total,
          }),
        );
      },
    );
    transport.sendControl(
      jsonEncode({
        't': 'progress',
        'phase': 'awaiting_restart',
        'done': 0,
        'total': 0,
      }),
    );
    stderr.writeln(
      '[rhr] ✅ kernel + assets synced — press ⟳ Hot Restart '
      '(or R) to launch the app in the player.',
    );
  } catch (error, stackTrace) {
    transport.sendControl(
      jsonEncode({'t': 'progress', 'phase': '', 'done': 0, 'total': 0}),
    );
    stderr.writeln('[rhr] asset sync failed: $error');
    stderr.writeln(stackTrace);
  }
}

/// Our parent process id, or null if it can't be determined. Used to detect an
/// orphaned run (parent reparented to init when flutter dies).
int? _ppid() {
  try {
    final r = Process.runSync('ps', ['-o', 'ppid=', '-p', '$pid']);
    return int.tryParse((r.stdout as String).trim());
  } catch (_) {
    return null;
  }
}

/// Opens one relay session and, once the phone announces its VM service,
/// prints the Flutter-parseable line and tunnels until the relay drops.
/// Returns true when this process should exit (stdin/EOF), false to retry.
Future<bool> _serve(String relay, String code, bool preferDirect) async {
  final RelayRace relayTransport;
  try {
    relayTransport = await RelayRace.connect(relays: [relay], code: code);
  } catch (e) {
    stderr.writeln('[rhr] relay connect failed: $e');
    return false;
  }
  final SessionTransport transport = preferDirect
      ? DirectSessionTransport(relayTransport)
      : relayTransport;
  stderr.writeln(
    '[rhr] connected to relay (session $code) — waiting for phone…',
  );

  final vmReady = Completer<Uri>();
  final wsDied = Completer<void>();
  final guestReady = Completer<void>();
  final sockets = <int, Socket>{};
  final flow = FlowControl();
  DirectTransportFailure? directFailure;
  Uri? activeVm;
  String? assetStoreId;
  final compatibility = readProjectCompatibilityProfile(Directory.current.path);

  void sendPayload(Uint8List payload) {
    unawaited(
      transport.sendPayload(payload).catchError((
        Object error,
        StackTrace stack,
      ) {
        if (error is DirectTransportFailure) directFailure ??= error;
        if (!wsDied.isCompleted) wsDied.complete();
      }),
    );
  }

  transport.stream.listen(
    (msg) {
      if (msg is String) {
        final m = jsonDecode(msg) as Map<String, dynamic>;
        if (m['t'] == 'info') {
          final announcedAssetStoreId = m['assetStoreId'];
          if (announcedAssetStoreId is! String ||
              announcedAssetStoreId.isEmpty) {
            stderr.writeln(
              '[rhr] COMPATIBILITY_BLOCKED: the player does not report an '
              'asset-store identity. Rebuild and reinstall the player.',
            );
            exit(78);
          }
          assetStoreId = announcedAssetStoreId;
          if (m['ready'] == true && !guestReady.isCompleted) {
            guestReady.complete();
          }
          final rawCompatibility = m['compatibility'];
          if (rawCompatibility is! Map<String, dynamic>) {
            stderr.writeln(
              '[rhr] COMPATIBILITY_BLOCKED: the installed player does not '
              'report its Flutter runtime identity. Rebuild and reinstall the '
              'player with this rhr version.',
            );
            exit(78);
          }
          final report = compatibility.differencesFrom(rawCompatibility);
          for (final warning in report.warnings) {
            stderr.writeln('[rhr] note: $warning');
          }
          if (report.blockers.isNotEmpty) {
            stderr.writeln('[rhr] COMPATIBILITY_BLOCKED:');
            for (final difference in report.blockers) {
              stderr.writeln('  - $difference');
            }
            stderr.writeln(
              '[rhr] Rebuild and reinstall a player compatible with this '
              'Flutter project.',
            );
            exit(78);
          }
          final vmValue = m['vm'];
          if (vmValue is! String || vmValue.isEmpty) {
            stderr.writeln(
              '[rhr] COMPATIBILITY_BLOCKED: player announced no VM service.',
            );
            exit(78);
          }
          final announcedVm = Uri.parse(vmValue);
          if (!vmReady.isCompleted) {
            activeVm = announcedVm;
            vmReady.complete(announcedVm);
          } else if (announcedVm != activeVm &&
              Platform.environment['RHR_EXIT_ON_VM_CHANGE'] == '1') {
            stderr.writeln(
              '[rhr] phone VM changed; restarting the CLI-owned Flutter session…',
            );
            exit(75);
          }
        } else if (m['t'] == 'ready' && !guestReady.isCompleted) {
          // The player signals the guest kernel is synced + settled → auto-boot.
          guestReady.complete();
        }
        return;
      }
      final f = decodeFrame(msg as List<int>);
      switch (f.op) {
        case opData:
          sockets[f.channel]?.add(f.payload);
          sendPayload(encodeAck(f.channel, f.payload.length));
        case opAck:
          flow.acked(f.channel, decodeAckCount(f.payload));
        case opClose:
          flow.forget(f.channel);
          sockets.remove(f.channel)?.destroy();
      }
    },
    onDone: () {
      // Another dev on the same code kicked us (relay's one-dev rule). Don't
      // reconnect into a slot-stealing fight — exit the whole helper.
      if ((transport.closeReason ?? '').contains('replaced')) {
        stderr.writeln(
          '[rhr] another rhr session is using code "$code" — '
          'exiting (only one dev per session).',
        );
        exit(3);
      }
      // Same payload, same refusal, forever — say why once and stop.
      if ((transport.closeReason ?? '').contains(relayBinaryRefusal)) {
        stderr.writeln('[rhr] $relayBinaryUnsupported');
        exit(77);
      }
      if (!wsDied.isCompleted) wsDied.complete();
    },
    onError: (Object error) {
      if (error is DirectTransportFailure) directFailure ??= error;
      if (!wsDied.isCompleted) wsDied.complete();
    },
  );

  final keepalive = Timer.periodic(developerLeasePingInterval, (_) {
    try {
      transport.sendControl(jsonEncode({'t': 'ping'}));
    } catch (_) {}
  });

  final vmResult = await Future.any<Object>([
    vmReady.future,
    wsDied.future.then((_) => const _RelayEnded()),
  ]);
  if (vmResult is _RelayEnded) {
    keepalive.cancel();
    await transport.close();
    final failure = directFailure;
    if (failure != null) throw failure;
    return false; // relay dropped before the phone showed up — retry
  }
  if (vmResult is! Uri) {
    keepalive.cancel();
    throw StateError('relay returned an unexpected VM-service result');
  }
  final vm = vmResult;
  try {
    await transport.payloadReady;
  } on DirectTransportFailure {
    keepalive.cancel();
    await transport.close();
    rethrow;
  }

  // Reload activity indicator: the compile happens on THIS machine, so the
  // phone can't know a reload started until bytes arrive — leaving a silent gap
  // while the dev-side compiles. We can't cleanly parse the (WS-masked) VM
  // traffic, but a dev→phone data burst after a quiet period reliably marks a
  // reload/sync starting. On the first byte after idle, tell the phone to show
  // "Reloading…"; the phone clears it when its DevFS write settles.
  var reloadingShown = false;
  DateTime lastShown = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? clearReloading;
  void noteDevActivity() {
    final now = DateTime.now();
    // Show once per reload. A single reload's transfer has brief internal pauses;
    // don't re-fire on those. Only start a new "reloading" if we're not already
    // showing AND enough time passed since the last one (a genuinely new reload).
    if (!reloadingShown &&
        now.difference(lastShown) > const Duration(seconds: 1)) {
      reloadingShown = true;
      lastShown = now;
      transport.sendControl(jsonEncode({'t': 'reloading'}));
    }
    // Hide only after a longer quiet window, so mid-reload pauses don't clear it.
    clearReloading?.cancel();
    clearReloading = Timer(const Duration(milliseconds: 1200), () {
      if (reloadingShown) {
        reloadingShown = false;
        transport.sendControl(jsonEncode({'t': 'reloaded'}));
      }
    });
  }

  var nextChannel = 1;
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((sock) {
    final channel = nextChannel++;
    sockets[channel] = sock;
    sock.done.catchError((_) {});
    sendPayload(encodeFrame(opOpen, channel));
    late final StreamSubscription<Uint8List> sub;
    sub = sock.listen(
      (data) {
        noteDevActivity();
        sendPayload(encodeFrame(opData, channel, data));
        if (flow.sent(channel, data.length)) {
          sub.pause();
          flow.onWindowOpen(channel, sub.resume);
        }
      },
      onDone: () {
        flow.forget(channel);
        if (sockets.remove(channel) != null) {
          sendPayload(encodeFrame(opClose, channel));
        }
      },
      onError: (_) {
        flow.forget(channel);
        if (sockets.remove(channel) != null) {
          sendPayload(encodeFrame(opClose, channel));
        }
      },
    );
  });

  final local = vm.replace(host: '127.0.0.1', port: server.port);

  // THE line Flutter's ProtocolDiscovery scans stdout for. Must match the
  // engine's own wording so the custom-device runner extracts the URI.
  stdout.writeln('The Dart VM service is listening on $local');

  // The player knows when the guest kernel's DevFS is ready. Upload the generic
  // player's missing asset bundle before asking the user for the initial hot
  // restart; subsequent code-only reloads stay on Flutter's normal fast path.
  unawaited(
    _syncAssetsOnReady(
      guestReady.future,
      local,
      Directory.current.path,
      transport,
      assetStoreId!,
    ),
  );

  // Keep the tunnel alive until the relay drops or Flutter ends the run
  // (it closes our stdin on stop). Whichever comes first.
  final stdinClosed = Completer<void>();
  stdin.listen(
    (_) {},
    onDone: () {
      if (!stdinClosed.isCompleted) stdinClosed.complete();
    },
  );

  var flutterEnded = false;
  await Future.any<void>([
    wsDied.future,
    stdinClosed.future.then((_) => flutterEnded = true),
  ]);

  keepalive.cancel();
  await server.close();
  for (final s in sockets.values.toList()) {
    s.destroy();
  }
  sockets.clear();
  await transport.close();
  final failure = directFailure;
  if (failure != null) throw failure;
  return flutterEnded;
}

final class _RelayEnded {
  const _RelayEnded();
}

/// Render a scannable QR to the terminal (stderr, so it never pollutes the
/// stdout line Flutter parses). Each module is two terminal cells wide and has
/// an explicit background color so IDE line highlighting cannot corrupt it.
void _printQr(String data, String code) {
  final qr = renderTerminalQr(data);
  final b = StringBuffer('\n${qr.text}');
  b.write('\n  Scan with the rhr player  ·  or type:  $code\n\n');
  stderr.write(b.toString());
}
