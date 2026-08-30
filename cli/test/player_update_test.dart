import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:rhr_bridge/tunnel.dart';
import 'package:rhr_cli/player_update.dart';
import 'package:rhr_cli/relay_race.dart';
import 'package:test/test.dart';

/// Captures everything the sender emits and lets the test act as the device.
final class _FakeTransport implements SessionTransport {
  final sentText = <Map<String, dynamic>>[];
  final sentFrames = <({int op, int channel, Uint8List payload})>[];

  @override
  final Stream<Object> stream = const Stream.empty();

  @override
  Future<String> get selectedRelay async => 'fake';

  @override
  String? get closeReason => null;

  @override
  void send(Object message) {
    if (message is String) {
      sentText.add(jsonDecode(message) as Map<String, dynamic>);
    } else {
      sentFrames.add(decodeFrame(message as List<int>));
    }
  }

  @override
  Future<void> close() async {}
}

void main() {
  late Directory tmp;
  late File apk;
  final apkBytes = List<int>.generate(200 * 1024 + 17, (i) => i % 251);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rhr_update_test_');
    apk = File('${tmp.path}/player.apk')..writeAsBytesSync(apkBytes);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('transfer ids live in the reserved high-bit range', () {
    expect(PlayerUpdateSender.isUpdateAck(updateTransferIdBase | 1), isTrue);
    expect(PlayerUpdateSender.isUpdateAck(1), isFalse);
    expect(PlayerUpdateSender.isUpdateAck(42), isFalse);
  });

  test('happy path: begin, chunks, commit, committed', () async {
    final transport = _FakeTransport();
    final sender = PlayerUpdateSender(transport);

    final done = sender.send(apk);
    // Device acks the announcement.
    await _pumpUntil(() => transport.sentText.isNotEmpty);
    final begin = transport.sentText.single;
    expect(begin['t'], 'update_begin');
    expect(begin['size'], apkBytes.length);
    expect(begin['sha256'], sha256.convert(apkBytes).toString());
    final id = begin['id'] as int;
    sender.handleMessage({'t': 'update_status', 'id': id, 'state': 'ready'});

    // Wait for the commit message; the transfer is small enough to fit one
    // flow-control window, so no acks are needed along the way.
    await _pumpUntil(
      () => transport.sentText.any((m) => m['t'] == 'update_commit'),
    );
    final streamed = BytesBuilder();
    for (final frame in transport.sentFrames) {
      expect(frame.op, opUpdateData);
      expect(frame.channel, id);
      streamed.add(frame.payload);
    }
    expect(streamed.toBytes(), apkBytes);

    sender.handleMessage({
      't': 'update_status',
      'id': id,
      'state': 'committed',
    });
    expect(await done, PlayerUpdateOutcome.committed);
    sender.close();
  });

  test('pending_user surfaces as its own outcome', () async {
    final transport = _FakeTransport();
    final sender = PlayerUpdateSender(transport);
    final done = sender.send(apk);
    await _pumpUntil(() => transport.sentText.isNotEmpty);
    final id = transport.sentText.first['id'] as int;
    sender.handleMessage({'t': 'update_status', 'id': id, 'state': 'ready'});
    await _pumpUntil(
      () => transport.sentText.any((m) => m['t'] == 'update_commit'),
    );
    sender.handleMessage({
      't': 'update_status',
      'id': id,
      'state': 'pending_user',
    });
    expect(await done, PlayerUpdateOutcome.pendingUser);
    sender.close();
  });

  test('device failure report becomes a PlayerUpdateFailure', () async {
    final transport = _FakeTransport();
    final sender = PlayerUpdateSender(transport);
    final done = sender.send(apk);
    await _pumpUntil(() => transport.sentText.isNotEmpty);
    final id = transport.sentText.first['id'] as int;
    sender.handleMessage({'t': 'update_status', 'id': id, 'state': 'ready'});
    sender.handleMessage({
      't': 'update_status',
      'id': id,
      'state': 'failure',
      'message': 'sha256 mismatch',
    });
    await expectLater(
      done,
      throwsA(
        isA<PlayerUpdateFailure>().having(
          (f) => f.message,
          'message',
          contains('sha256 mismatch'),
        ),
      ),
    );
    sender.close();
  });

  test('a failure queued between waits is not lost', () async {
    final transport = _FakeTransport();
    final sender = PlayerUpdateSender(transport);
    final done = sender.send(apk);
    await _pumpUntil(() => transport.sentText.isNotEmpty);
    final id = transport.sentText.first['id'] as int;
    // Both statuses arrive back-to-back before the sender reaches its
    // commit wait.
    sender.handleMessage({'t': 'update_status', 'id': id, 'state': 'ready'});
    sender.handleMessage({
      't': 'update_status',
      'id': id,
      'state': 'failure',
      'message': 'out of disk',
    });
    await expectLater(done, throwsA(isA<PlayerUpdateFailure>()));
    sender.close();
  });

  test('a player that never answers ready fails with the manual hint',
      () async {
    final transport = _FakeTransport();
    final sender = PlayerUpdateSender(transport);
    final done = sender.send(apk);
    await _pumpUntil(() => transport.sentText.isNotEmpty);
    sender.close(); // simulate giving up: close unblocks the wait
    await expectLater(done, throwsA(isA<PlayerUpdateFailure>()));
  });

  test('messages for other transfers are left to the caller', () {
    final sender = PlayerUpdateSender(_FakeTransport());
    expect(sender.handleMessage({'t': 'info'}), isFalse);
    expect(
      sender.handleMessage({'t': 'update_status', 'id': 999, 'state': 'ready'}),
      isFalse,
    );
    sender.close();
  });

  test('flow control pauses at the window and resumes on ack', () async {
    final transport = _FakeTransport();
    final sender = PlayerUpdateSender(transport);
    // Larger than one 512 KB window so the sender must block on acks.
    final big = File('${tmp.path}/big.apk')
      ..writeAsBytesSync(List<int>.filled(windowBytes + 64 * 1024, 7));
    final done = sender.send(big);
    await _pumpUntil(() => transport.sentText.isNotEmpty);
    final id = transport.sentText.first['id'] as int;
    sender.handleMessage({'t': 'update_status', 'id': id, 'state': 'ready'});

    // The sender stalls once a full window is unacked.
    await _pumpUntil(
      () =>
          transport.sentFrames.fold<int>(
            0,
            (sum, f) => sum + f.payload.length,
          ) >=
          windowBytes,
    );
    expect(
      transport.sentText.any((m) => m['t'] == 'update_commit'),
      isFalse,
      reason: 'must not commit while the window is full',
    );

    // Device acks everything received so far — the window opens and the
    // remainder streams through to commit.
    sender.handleAck(id, windowBytes);
    await _pumpUntil(
      () => transport.sentText.any((m) => m['t'] == 'update_commit'),
    );
    sender.handleMessage({
      't': 'update_status',
      'id': id,
      'state': 'committed',
    });
    expect(await done, PlayerUpdateOutcome.committed);
    sender.close();
  });
}

Future<void> _pumpUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not reached within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
