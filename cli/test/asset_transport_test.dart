import 'dart:io';

import 'package:rhr_cli/asset_transport.dart';
import 'package:rhr_cli/usb_asset_transport.dart';
import 'package:test/test.dart';

void main() {
  test(
    'fallback retries the complete batch through the reliable transport',
    () async {
      final root = await Directory.systemTemp.createTemp('rhr_transport_');
      addTearDown(() => root.delete(recursive: true));
      final source = File('${root.path}/a.txt')..writeAsStringSync('hello');
      final file = AssetTransferFile(
        source: source,
        relativePath: 'a.txt',
        size: source.lengthSync(),
      );
      final preferred = _FakeTransport(
        'USB',
        (_) => throw StateError('cable disconnected'),
      );
      final fallback = _FakeTransport(
        'DevFS',
        (_) async => AssetTransferResult(
          completed: {
            'a.txt': const AssetFingerprint(size: 5, sha256: 'verified'),
          },
          wireBytes: 5,
          elapsed: const Duration(milliseconds: 1),
          transportLabel: 'DevFS',
        ),
      );
      Object? fallbackReason;
      final progress = <int>[];
      final transport = FallbackAssetTransport(
        preferred: preferred,
        fallback: fallback,
        onFallback: (error) => fallbackReason = error,
      );

      final result = await transport.transfer(
        AssetTransferRequest(
          assetRoot: root,
          projectName: 'project',
          files: [file],
          onProgress: progress.add,
        ),
      );

      expect(preferred.calls, 1);
      expect(fallback.calls, 1);
      expect(fallbackReason, isA<StateError>());
      expect(progress, [0]);
      expect(result.transportLabel, 'DevFS');
      expect(result.completed, contains('a.txt'));
    },
  );

  test('adb discovery considers physical authorized USB devices only', () {
    const output = '''
List of devices attached
RFCY80LPLEJ device product:a56 model:SM_A566B transport_id:1
192.168.1.16:5555 device product:a56 model:SM_A566B transport_id:2
emulator-5554 device product:sdk model:sdk transport_id:3
adb-RFCY80._adb-tls-connect._tcp device product:a56 transport_id:4
OTHER unauthorized transport_id:5
OFFLINE offline transport_id:6
''';

    expect(parseUsbAdbDevices(output), ['RFCY80LPLEJ']);
  });

  test('matches the Player asset-store identity written by Android', () {
    const xml = '''
<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
    <string name="asset_store_id">store-123</string>
</map>
''';

    expect(playerPreferencesHaveAssetStoreId(xml, 'store-123'), isTrue);
    expect(playerPreferencesHaveAssetStoreId(xml, 'another-phone'), isFalse);
  });

  test('USB archives split before the host argument limit', () {
    final files = [
      for (var index = 0; index < 5; index++)
        AssetTransferFile(
          source: File('unused-$index'),
          relativePath: 'asset-$index.bin',
          size: 1,
        ),
    ];

    final batches = usbTransferBatches(files, maxArgumentBytes: 25);

    expect(batches.map((batch) => batch.length), [2, 2, 1]);
    expect(batches.expand((batch) => batch), files);
  });

  test('USB archives split into byte-bounded chunks', () {
    final files = [
      AssetTransferFile(
        source: File('unused-a'),
        relativePath: 'a.bin',
        size: 7,
      ),
      AssetTransferFile(
        source: File('unused-b'),
        relativePath: 'b.bin',
        size: 7,
      ),
      AssetTransferFile(
        source: File('unused-large'),
        relativePath: 'large.bin',
        size: 20,
      ),
      AssetTransferFile(
        source: File('unused-c'),
        relativePath: 'c.bin',
        size: 4,
      ),
    ];

    final batches = usbTransferBatches(files, maxSourceBytes: 10);

    expect(
      batches.map((batch) => batch.map((file) => file.relativePath).toList()),
      [
        ['a.bin'],
        ['b.bin'],
        ['large.bin'],
        ['c.bin'],
      ],
    );
  });

  test('USB chunk retries after a verification mismatch', () async {
    var transfers = 0;
    var verifications = 0;

    final attempts = await transferVerifiedUsbChunk(
      transfer: () async => transfers++,
      verify: () async {
        verifications++;
        return verifications == 1 ? ['assets/missing.png'] : const [];
      },
    );

    expect(attempts, 2);
    expect(transfers, 2);
    expect(verifications, 2);
  });

  test('USB retry waits for adb recovery after a broken pipe', () async {
    final events = <String>[];
    var transfers = 0;

    final attempts = await transferVerifiedUsbChunk(
      transfer: () async {
        transfers++;
        events.add('transfer-$transfers');
        if (transfers == 1) {
          throw const SocketException('Write failed: broken pipe');
        }
      },
      verify: () async {
        events.add('verify');
        return const [];
      },
      recover: (nextAttempt, error) async {
        events.add('recover-$nextAttempt');
      },
    );

    expect(attempts, 2);
    expect(events, ['transfer-1', 'recover-2', 'transfer-2', 'verify']);
  });

  test('USB chunk fails after its verification retry budget', () async {
    var transfers = 0;

    await expectLater(
      transferVerifiedUsbChunk(
        transfer: () async => transfers++,
        verify: () async => ['assets/missing.png'],
        maxAttempts: 3,
      ),
      throwsA(isA<UsbChunkVerificationException>()),
    );
    expect(transfers, 3);
  });

  test('USB verifier keeps the remote sh script grouped for adb', () {
    expect(
      usbVerificationShellCommand('/data/user/0/dev.rhr/files/assets/project'),
      "'cd /data/user/0/dev.rhr/files/assets/project && "
      "xargs -0 -r sha256sum --'",
    );
  });

  test('large USB files split into independently retryable byte ranges', () {
    final ranges = usbByteRanges(35, chunkBytes: 16);

    expect(
      ranges
          .map((range) => (offset: range.offset, length: range.length))
          .toList(),
      [
        (offset: 0, length: 16),
        (offset: 16, length: 16),
        (offset: 32, length: 3),
      ],
    );
  });

  test('USB transfer plan routes oversized files away from tar archives', () {
    final small = AssetTransferFile(
      source: File('small'),
      relativePath: 'small.bin',
      size: 8,
    );
    final large = AssetTransferFile(
      source: File('large'),
      relativePath: 'large.bin',
      size: 17,
    );

    final plan = usbTransferPlan([small, large], chunkBytes: 16);

    expect(plan.archiveBatches.expand((batch) => batch), [small]);
    expect(plan.rangeFiles, [large]);
  });

  test('range digest verification accepts only the expected SHA-256', () {
    const expected =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

    expect(usbRangeDigestMatches(expected, '$expected  -\n'), isTrue);
    expect(
      usbRangeDigestMatches(
        expected,
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  -\n',
      ),
      isFalse,
    );
  });

  test('USB range writer waits for remote dd completion without a PTY', () {
    expect(
      usbRangeWriteAdbArguments('/data/player/assets/kernel_blob.bin', 3),
      [
        'shell',
        '-T',
        'run-as',
        'dev.rhr.rhr_player',
        'dd',
        'of=/data/player/assets/kernel_blob.bin',
        'bs=4194304',
        'seek=3',
        'conv=notrunc',
      ],
    );
  });

  test('USB archive writer waits for remote tar completion without a PTY', () {
    expect(
      usbArchiveWriteAdbArguments('/data/player/assets/flutter_assets'),
      [
        'shell',
        '-T',
        'run-as',
        'dev.rhr.rhr_player',
        'tar',
        '-xf',
        '-',
        '-C',
        '/data/player/assets/flutter_assets',
      ],
    );
  });

  test('USB inventory rejects missing and corrupt remote files', () {
    final files = [
      AssetTransferFile(
        source: File('unused-a'),
        relativePath: 'assets/a.png',
        size: 120,
      ),
      AssetTransferFile(
        source: File('unused-b'),
        relativePath: 'assets/b.png',
        size: 240,
      ),
      AssetTransferFile(
        source: File('unused-c'),
        relativePath: 'assets/c.png',
        size: 360,
      ),
    ];

    final mismatches = usbDigestMismatches(
      files: files,
      destination: '/data/player/flutter_assets',
      expected: {
        'assets/a.png': const AssetFingerprint(
          size: 120,
          sha256:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ),
        'assets/b.png': const AssetFingerprint(
          size: 240,
          sha256:
              'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        ),
        'assets/c.png': const AssetFingerprint(
          size: 360,
          sha256:
              'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
        ),
      },
      digestOutput: '''
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  /data/player/flutter_assets/assets/a.png
bbb  /data/player/flutter_assets/assets/b.png
''',
    );

    expect(mismatches, ['assets/b.png', 'assets/c.png']);
  });
}

final class _FakeTransport implements AssetTransport {
  _FakeTransport(this.label, this._transfer);

  @override
  final String label;
  final Future<AssetTransferResult> Function(AssetTransferRequest) _transfer;
  int calls = 0;

  @override
  Future<AssetTransferResult> transfer(AssetTransferRequest request) {
    calls++;
    return _transfer(request);
  }
}
