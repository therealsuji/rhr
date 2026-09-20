// The whole update conversation, both ends, no phone.
//
// player_update_test.dart drives the sender with hand-written replies, which
// is right for testing the sender's own edge cases but cannot catch the two
// ends disagreeing. Here the real PlayerUpdateSender talks to the real
// FakeUpdater — the same one fake_device.dart installs — so a change to
// either side that breaks the protocol fails here rather than on hardware.
//
// What it is really guarding is the progress the tester reads. That number
// was wrong for as long as the feature existed: the sender counted gzipped
// wire bytes against the uncompressed APK size, so a finished transfer
// reported 55% and the phone's bar stopped there, through the install and
// into the next screen.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:rhr_bridge/fake_updater.dart';
import 'package:rhr_bridge/tunnel.dart';
import 'package:rhr_cli/player_update.dart';
import 'package:rhr_cli/relay_race.dart';
import 'package:test/test.dart';

/// Wires the sender's output straight into a [FakeUpdater] and its answers
/// back, so the two halves actually talk to each other.
final class _LoopbackTransport implements SessionTransport {
  _LoopbackTransport();

  late final PlayerUpdateSender sender;
  late final FakeUpdater device;

  /// Every progress-bearing call the CLI would make, as (done, total).
  final progress = <({int done, int total})>[];

  @override
  final Stream<Object> stream = const Stream.empty();

  @override
  Future<String> get selectedRelay async => 'loopback';

  @override
  Future<void> get payloadReady async {}

  @override
  String? get closeReason => null;

  @override
  void sendControl(String message) {
    final decoded = jsonDecode(message) as Map<String, dynamic>;
    switch (decoded['t']) {
      case 'update_begin':
        device.handleBegin(decoded);
      case 'update_commit':
        device.handleCommit(decoded);
    }
  }

  @override
  Future<void> sendPayload(Uint8List message) async {
    final frame = decodeFrame(message);
    device.handleData(frame.payload);
    // The bridge acks payload frames on receipt; without this the sender
    // blocks forever at the first flow-control window.
    sender.handleAck(frame.channel, frame.payload.length);
  }

  @override
  Future<void> close() async {}

  /// The device answering the dev.
  void deviceSays(String message) =>
      sender.handleMessage(jsonDecode(message) as Map<String, dynamic>);
}

void main() {
  late Directory tmp;
  late File apk;

  // Shaped like an APK: native libraries are STORED so Android can mmap
  // them and gzip gets nowhere on them, while the rest compresses well. The
  // mix lands near half, which is where the tester's 54% came from. A
  // payload that compressed to nothing would pass this file's assertions
  // without ever exercising the mismatch they exist to catch.
  final apkBytes = () {
    const half = 1536 * 1024;
    final bytes = Uint8List(half * 2);
    // The incompressible half: a seeded LCG, so it is random enough that
    // gzip gets nowhere and identical on every run.
    var seed = 0x2545F491;
    for (var i = 0; i < half; i++) {
      seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
      bytes[i] = (seed >> 16) & 0xFF;
    }
    // The compressible half: repetitive, like a manifest or a dex string pool.
    for (var i = 0; i < half; i++) {
      bytes[half + i] = (i ~/ 64) % 7;
    }
    return bytes;
  }();

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rhr_loopback_');
    apk = File('${tmp.path}/payload.apk')..writeAsBytesSync(apkBytes);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  /// Runs one full transfer and returns what both ends saw.
  Future<({PlayerUpdateOutcome outcome, _LoopbackTransport transport})> run({
    required FakeInstallOutcome installs,
    bool acceptGzip = true,
    UpdateKind kind = UpdateKind.player,
    String target = '',
  }) async {
    final transport = _LoopbackTransport();
    transport.sender = PlayerUpdateSender(
      transport,
      kind: kind,
      target: target,
    );
    transport.device = FakeUpdater(
      sendText: transport.deviceSays,
      outcome: installs,
      acceptGzip: acceptGzip,
      confirmDelay: const Duration(milliseconds: 10),
    );
    final outcome = await transport.sender.send(
      apk,
      onProgress: (done, total) =>
          transport.progress.add((done: done, total: total)),
    );
    transport.sender.close();
    return (outcome: outcome, transport: transport);
  }

  test('a gzipped transfer reports progress that reaches 100%', () async {
    final result = await run(installs: FakeInstallOutcome.committed);
    expect(result.outcome, PlayerUpdateOutcome.committed);

    final progress = result.transport.progress;
    expect(progress, isNotEmpty);

    // The contract: the last report is complete. This is the assertion the
    // stuck bar would have failed — it reported roughly 55% and stopped.
    final last = progress.last;
    expect(
      last.done,
      last.total,
      reason: 'the tester reads ${(last.done * 100 / last.total).round()}% '
          'for a transfer that has finished',
    );

    // And every report along the way is a number a bar can draw.
    for (final report in progress) {
      expect(report.done, lessThanOrEqualTo(report.total));
      expect(report.done, greaterThanOrEqualTo(0));
    }

    // The device really did receive the APK: it verified the SHA-256 of the
    // decoded bytes before answering, so a corrupted stream could not have
    // got this far.
    expect(result.transport.device.decodedBytes, apkBytes.length);
  });

  test('the total is the compressed size, not the apk size', () async {
    final result = await run(installs: FakeInstallOutcome.committed);
    final total = result.transport.progress.last.total;

    // Compression actually happened, and by enough to matter: if the two
    // sizes were nearly equal, reporting one against the other would look
    // fine and this file would be proving nothing. The real GymApp payload
    // went 101.3 MB to 55.7 MB.
    final ratio = result.transport.device.wireBytes / apkBytes.length;
    expect(
      ratio,
      inExclusiveRange(0.3, 0.9),
      reason: 'the payload compressed to ${(ratio * 100).round()}%, which is '
          'not APK-shaped enough to exercise the mismatch',
    );
    expect(total, result.transport.device.wireBytes);
    expect(total, isNot(apkBytes.length));
  });

  test('a device that declines gzip still reports honestly', () async {
    final result = await run(
      installs: FakeInstallOutcome.committed,
      acceptGzip: false,
    );
    expect(result.outcome, PlayerUpdateOutcome.committed);

    final last = result.transport.progress.last;
    expect(last.done, last.total);
    // No compression was negotiated, so the wire carries the APK itself.
    expect(last.total, apkBytes.length);
    expect(result.transport.device.wireBytes, apkBytes.length);
  });

  test('an app payload waits for the install to be confirmed', () async {
    final result = await run(
      installs: FakeInstallOutcome.pendingUser,
      kind: UpdateKind.app,
      target: 'dev.rhrtest.native_skew',
    );
    // kind=app waits past pending_user for the terminal "installed" — the
    // tester's tap on Android's sheet.
    expect(result.outcome, PlayerUpdateOutcome.installed);
    expect(result.transport.progress.last.done, result.transport.progress.last.total);
  });

  test('a player payload surfaces pending_user as its own outcome', () async {
    final result = await run(installs: FakeInstallOutcome.pendingUser);
    expect(result.outcome, PlayerUpdateOutcome.pendingUser);
  });

  test('a refused install fails with the device\'s reason', () async {
    await expectLater(
      run(installs: FakeInstallOutcome.fail),
      throwsA(
        isA<PlayerUpdateFailure>().having(
          (f) => f.message,
          'message',
          contains('PackageInstaller'),
        ),
      ),
    );
  });
}
