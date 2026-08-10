import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:rhr_cli/asset_transport.dart';

const _playerPackage = 'dev.rhr.rhr_player';
const _usbChunkBytes = 16 * 1024 * 1024;
const _usbRangeBytes = 4 * 1024 * 1024;
const _usbChunkAttempts = 3;

final class UsbAssetTransport implements AssetTransport {
  const UsbAssetTransport._({
    required this.serial,
    required this.playerDataDir,
    this.adbExecutable = 'adb',
  });

  final String serial;
  final String playerDataDir;
  final String adbExecutable;

  @override
  String get label => 'USB ($serial)';

  /// Returns a USB adapter only when exactly one authorized, debuggable Player
  /// has the same persistent asset-store identity as the active relay session.
  /// This identity check prevents copying a project to the wrong connected
  /// phone when several adb devices are present.
  static Future<UsbAssetTransport?> discover({
    required String? assetStoreId,
    String adbExecutable = 'adb',
  }) async {
    if (assetStoreId == null || assetStoreId.isEmpty) return null;
    ProcessResult devices;
    try {
      devices = await Process.run(adbExecutable, ['devices', '-l']);
    } on ProcessException {
      return null;
    }
    if (devices.exitCode != 0) return null;

    final candidates = parseUsbAdbDevices(devices.stdout as String);
    final matches = <UsbAssetTransport>[];
    for (final serial in candidates) {
      final preferences = await Process.run(adbExecutable, [
        '-s',
        serial,
        'shell',
        'run-as',
        _playerPackage,
        'cat',
        'shared_prefs/rhr_native.xml',
      ]);
      if (preferences.exitCode != 0 ||
          !playerPreferencesHaveAssetStoreId(
            preferences.stdout as String,
            assetStoreId,
          )) {
        continue;
      }
      final workingDirectory = await Process.run(adbExecutable, [
        '-s',
        serial,
        'shell',
        'run-as',
        _playerPackage,
        'pwd',
      ]);
      final dataDir = (workingDirectory.stdout as String).trim();
      if (workingDirectory.exitCode == 0 && dataDir.startsWith('/data/')) {
        matches.add(
          UsbAssetTransport._(
            serial: serial,
            playerDataDir: dataDir,
            adbExecutable: adbExecutable,
          ),
        );
      }
    }
    return matches.length == 1 ? matches.single : null;
  }

  @override
  Future<AssetTransferResult> transfer(AssetTransferRequest request) async {
    if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(request.projectName)) {
      throw StateError(
        'USB transfer does not support project directory name '
        '"${request.projectName}"',
      );
    }
    for (final file in request.files) {
      if (!_safeRelativePath(file.relativePath)) {
        throw StateError('unsafe asset path: ${file.relativePath}');
      }
    }

    final destination =
        '$playerDataDir/files/assets/${request.projectName}/flutter_assets';
    final mkdir = await Process.run(adbExecutable, [
      '-s',
      serial,
      'shell',
      'run-as',
      _playerPackage,
      'mkdir',
      '-p',
      destination,
    ]);
    if (mkdir.exitCode != 0) {
      throw StateError('could not prepare Player USB cache: ${mkdir.stderr}');
    }

    final stopwatch = Stopwatch()..start();
    var wireBytes = 0;
    var completedSourceBytes = 0;
    // Hash the sources once before transfer. Each bounded USB chunk is checked
    // against these fingerprints immediately, so an adb stream that exits 0
    // after silently truncating is retried without resending the whole bundle.
    final completed = <String, AssetFingerprint>{};
    for (final file in request.files) {
      final digest = await sha256.bind(file.source.openRead()).first;
      completed[file.relativePath] = AssetFingerprint(
        size: file.size,
        sha256: digest.toString(),
      );
    }

    final plan = usbTransferPlan(request.files);
    final batches = plan.archiveBatches;
    for (var batchIndex = 0; batchIndex < batches.length; batchIndex++) {
      final batch = batches[batchIndex];
      final batchSourceBytes = batch.fold<int>(
        0,
        (sum, file) => sum + file.size,
      );
      await transferVerifiedUsbChunk(
        maxAttempts: _usbChunkAttempts,
        transfer: () async {
          request.onProgress(completedSourceBytes);
          final tar = await Process.start(
            'tar',
            [
              '-cf',
              '-',
              '-C',
              request.assetRoot.path,
              '--',
              ...batch.map((file) => file.relativePath),
            ],
            environment: {'COPYFILE_DISABLE': '1'},
          );
          final adb = await Process.start(adbExecutable, [
            '-s',
            serial,
            'exec-in',
            'run-as',
            _playerPackage,
            'tar',
            '-xf',
            '-',
            '-C',
            destination,
          ]);
          final tarError = tar.stderr.transform(systemEncoding.decoder).join();
          final adbError = adb.stderr.transform(systemEncoding.decoder).join();
          final adbOutput = adb.stdout.drain<void>();
          final estimatedTarBytes = _estimatedTarBytes(batch);
          var batchWireBytes = 0;
          Object? streamError;
          try {
            await adb.stdin.addStream(
              tar.stdout.map((chunk) {
                batchWireBytes += chunk.length;
                wireBytes += chunk.length;
                final fraction = estimatedTarBytes == 0
                    ? 1.0
                    : (batchWireBytes / estimatedTarBytes).clamp(0.0, 1.0);
                request.onProgress(
                  completedSourceBytes + (batchSourceBytes * fraction).round(),
                );
                return chunk;
              }),
            );
            await adb.stdin.close();
          } on Object catch (error) {
            streamError = error;
            tar.kill();
            adb.kill();
          }
          final exits = await Future.wait([
            _waitForExit(
              tar,
              timeout: const Duration(seconds: 30),
              operation: 'host tar',
            ),
            _waitForExit(
              adb,
              timeout: const Duration(seconds: 30),
              operation: 'USB archive transfer',
            ),
          ]);
          final errors = await Future.wait([tarError, adbError]);
          await adbOutput;
          if (streamError != null) throw streamError;
          if (exits[0] != 0 || exits[1] != 0) {
            throw StateError(
              'USB archive transfer failed '
              '(tar ${exits[0]}: ${errors[0].trim()}, '
              'adb ${exits[1]}: ${errors[1].trim()})',
            );
          }
        },
        verify: () => _verifyUsbChunk(
          files: batch,
          destination: destination,
          expected: completed,
        ),
        onRetry: (nextAttempt, error) {
          stderr.writeln(
            '[rhr] USB chunk ${batchIndex + 1}/${batches.length} was not '
            'complete; retrying ($nextAttempt/$_usbChunkAttempts): $error',
          );
        },
        recover: _recoverUsbTransport,
      );
      completedSourceBytes += batchSourceBytes;
      request.onProgress(completedSourceBytes);
    }

    for (final file in plan.rangeFiles) {
      final remotePath = '$destination/${file.relativePath}';
      await transferVerifiedUsbChunk(
        maxAttempts: _usbChunkAttempts,
        transfer: () => _prepareRangeFile(remotePath),
        verify: () async => const [],
        onRetry: (nextAttempt, error) {
          stderr.writeln(
            '[rhr] USB could not prepare ${file.relativePath}; retrying '
            '($nextAttempt/$_usbChunkAttempts): $error',
          );
        },
        recover: _recoverUsbTransport,
      );
      final ranges = usbByteRanges(file.size, chunkBytes: _usbRangeBytes);
      stderr.writeln(
        '[rhr] USB large asset ${file.relativePath}: '
        '${(file.size / 1024 / 1024).toStringAsFixed(1)} MB in '
        '${ranges.length} verified ranges',
      );
      for (var rangeIndex = 0; rangeIndex < ranges.length; rangeIndex++) {
        final range = ranges[rangeIndex];
        final digest = await sha256
            .bind(file.source.openRead(range.offset, range.end))
            .first;
        final expectedDigest = digest.toString();
        await transferVerifiedUsbChunk(
          maxAttempts: _usbChunkAttempts,
          transfer: () => _transferFileRange(
            source: file.source,
            remotePath: remotePath,
            range: range,
            rangeIndex: rangeIndex,
            onWireBytes: (deltaBytes, rangeBytes) {
              wireBytes += deltaBytes;
              request.onProgress(completedSourceBytes + rangeBytes);
            },
          ),
          verify: () async =>
              await _verifyFileRange(
                remotePath: remotePath,
                rangeIndex: rangeIndex,
                expectedDigest: expectedDigest,
              )
              ? const []
              : ['${file.relativePath}@${range.offset}+${range.length}'],
          onRetry: (nextAttempt, error) {
            stderr.writeln(
              '[rhr] USB file ${file.relativePath} range '
              '${rangeIndex + 1}/${ranges.length} was not complete; retrying '
              '($nextAttempt/$_usbChunkAttempts): $error',
            );
          },
          recover: _recoverUsbTransport,
        );
        completedSourceBytes += range.length;
        request.onProgress(completedSourceBytes);
      }

      // Range hashes prove every section independently. Keep one final whole-
      // file check so an offset/truncation bug cannot enter the host manifest.
      await transferVerifiedUsbChunk(
        maxAttempts: _usbChunkAttempts,
        transfer: () async {},
        verify: () => _verifyUsbChunk(
          files: [file],
          destination: destination,
          expected: completed,
        ),
        onRetry: (nextAttempt, error) {
          stderr.writeln(
            '[rhr] USB final verification for ${file.relativePath} failed; '
            'retrying ($nextAttempt/$_usbChunkAttempts): $error',
          );
        },
        recover: _recoverUsbTransport,
      );
    }

    stopwatch.stop();
    return AssetTransferResult(
      completed: completed,
      wireBytes: wireBytes,
      elapsed: stopwatch.elapsed,
      transportLabel: label,
    );
  }

  Future<List<String>> _verifyUsbChunk({
    required List<AssetTransferFile> files,
    required String destination,
    required Map<String, AssetFingerprint> expected,
  }) async {
    // Feed NUL-separated names over stdin so spaces and shell metacharacters in
    // valid Flutter asset paths never become shell syntax or separate args.
    final command = usbVerificationShellCommand(destination);
    final input = BytesBuilder(copy: false);
    for (final file in files) {
      input.add(utf8.encode('${file.relativePath}\x00'));
    }
    final result = await _runAdb([
      'shell',
      'run-as',
      _playerPackage,
      'sh',
      '-c',
      command,
    ], input: input.takeBytes());
    if (result.exitCode != 0) {
      throw StateError(
        'USB verification command failed (${result.exitCode}): '
        '${result.stderr.trim()}',
      );
    }
    return usbDigestMismatches(
      files: files,
      destination: destination,
      expected: expected,
      digestOutput: result.stdout,
    );
  }

  Future<void> _prepareRangeFile(String remotePath) async {
    final slash = remotePath.lastIndexOf('/');
    final parent = remotePath.substring(0, slash);
    final result = await _runAdb([
      'shell',
      'run-as',
      _playerPackage,
      'sh',
      '-c',
      _groupRemoteShellScript(
        'mkdir -p ${_shellQuote(parent)} && : > ${_shellQuote(remotePath)}',
      ),
    ]);
    if (result.exitCode != 0) {
      throw StateError(
        'could not prepare large USB asset: ${result.stderr.trim()}',
      );
    }
  }

  Future<void> _transferFileRange({
    required File source,
    required String remotePath,
    required UsbByteRange range,
    required int rangeIndex,
    required void Function(int deltaBytes, int rangeBytes) onWireBytes,
  }) async {
    final adb = await Process.start(adbExecutable, [
      '-s',
      serial,
      ...usbRangeWriteAdbArguments(remotePath, rangeIndex),
    ]);
    final output = adb.stdout.drain<void>();
    final error = adb.stderr.transform(systemEncoding.decoder).join();
    var sent = 0;
    Object? streamError;
    try {
      await adb.stdin.addStream(
        source.openRead(range.offset, range.end).map((chunk) {
          sent += chunk.length;
          onWireBytes(chunk.length, sent);
          return chunk;
        }),
      );
      await adb.stdin.close();
    } on Object catch (error) {
      streamError = error;
      adb.kill();
    }
    final exitCode = await _waitForExit(
      adb,
      timeout: const Duration(seconds: 30),
      operation: 'USB range transfer',
    );
    await output;
    final errorOutput = await error;
    if (streamError != null) throw streamError;
    if (sent != range.length) {
      throw StateError(
        'USB range source ended early: sent $sent of ${range.length} bytes',
      );
    }
    if (exitCode != 0) {
      throw StateError(
        'USB range transfer failed ($exitCode): ${errorOutput.trim()}',
      );
    }
  }

  Future<bool> _verifyFileRange({
    required String remotePath,
    required int rangeIndex,
    required String expectedDigest,
  }) async {
    final result = await _runAdb([
      'shell',
      'run-as',
      _playerPackage,
      'sh',
      '-c',
      _groupRemoteShellScript(
        'dd if=${_shellQuote(remotePath)} bs=$_usbRangeBytes '
        'skip=$rangeIndex count=1 2>/dev/null | sha256sum',
      ),
    ]);
    if (result.exitCode != 0) {
      throw StateError(
        'USB range verification failed (${result.exitCode}): '
        '${result.stderr.trim()}',
      );
    }
    return usbRangeDigestMatches(expectedDigest, result.stdout);
  }

  Future<void> _recoverUsbTransport(int nextAttempt, Object error) async {
    final delay = nextAttempt == 2
        ? const Duration(milliseconds: 350)
        : const Duration(milliseconds: 800);
    stderr.writeln('[rhr] waiting for USB/adb to recover...');
    await Future<void>.delayed(delay);

    final wait = await _runAdb([
      'wait-for-device',
    ], timeout: const Duration(seconds: 10));
    if (wait.exitCode != 0) {
      throw StateError('adb device did not return: ${wait.stderr.trim()}');
    }
    Object? lastError;
    for (var probe = 0; probe < 5; probe++) {
      try {
        final health = await _runAdb([
          'shell',
          'run-as',
          _playerPackage,
          'true',
        ], timeout: const Duration(seconds: 3));
        if (health.exitCode == 0) return;
        lastError = StateError(health.stderr.trim());
      } on Object catch (error) {
        lastError = error;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw StateError('USB/adb did not become healthy: $lastError');
  }

  Future<({int exitCode, String stdout, String stderr})> _runAdb(
    List<String> arguments, {
    List<int>? input,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final process = await Process.start(adbExecutable, [
      '-s',
      serial,
      ...arguments,
    ]);
    final output = process.stdout.transform(systemEncoding.decoder).join();
    final error = process.stderr.transform(systemEncoding.decoder).join();
    try {
      if (input != null) process.stdin.add(input);
      await process.stdin.close();
    } on Object {
      process.kill();
      rethrow;
    }
    final exitCode = await _waitForExit(
      process,
      timeout: timeout,
      operation: 'adb ${arguments.first}',
    );
    return (exitCode: exitCode, stdout: await output, stderr: await error);
  }
}

Future<int> _waitForExit(
  Process process, {
  required Duration timeout,
  required String operation,
}) async {
  try {
    return await process.exitCode.timeout(timeout);
  } on TimeoutException {
    process.kill();
    await process.exitCode;
    throw TimeoutException('$operation timed out', timeout);
  }
}

String _shellQuote(String value) {
  final escaped = value.replaceAll("'", "'\"'\"'");
  return "'$escaped'";
}

String _groupRemoteShellScript(String script) => _shellQuote(script);

String usbVerificationShellCommand(String destination) {
  if (!RegExp(r'^/data/[A-Za-z0-9_./-]+$').hasMatch(destination)) {
    throw StateError('unsafe Player USB cache path: $destination');
  }
  // adb joins remote argv into a shell command. Keep the script quoted as one
  // argument to `sh -c`; otherwise only `cd` becomes the script and xargs runs
  // from the app's data root.
  return "'cd $destination && xargs -0 -r sha256sum --'";
}

final class UsbChunkVerificationException implements Exception {
  const UsbChunkVerificationException(this.mismatches);

  final List<String> mismatches;

  @override
  String toString() {
    final preview = mismatches.take(5).join(', ');
    return 'USB verification found ${mismatches.length} missing or corrupt '
        'asset(s): $preview${mismatches.length > 5 ? ', …' : ''}';
  }
}

Future<int> transferVerifiedUsbChunk({
  required Future<void> Function() transfer,
  required Future<List<String>> Function() verify,
  int maxAttempts = _usbChunkAttempts,
  void Function(int nextAttempt, Object error)? onRetry,
  Future<void> Function(int nextAttempt, Object error)? recover,
}) async {
  if (maxAttempts < 1) {
    throw ArgumentError.value(maxAttempts, 'maxAttempts', 'must be positive');
  }
  Object? lastError;
  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      await transfer();
      final mismatches = await verify();
      if (mismatches.isEmpty) return attempt;
      lastError = UsbChunkVerificationException(mismatches);
    } on Object catch (error) {
      lastError = error;
    }
    if (attempt < maxAttempts) {
      final nextAttempt = attempt + 1;
      onRetry?.call(nextAttempt, lastError);
      await recover?.call(nextAttempt, lastError);
    }
  }
  throw lastError!;
}

final class UsbByteRange {
  const UsbByteRange({required this.offset, required this.length});

  final int offset;
  final int length;

  int get end => offset + length;
}

typedef UsbTransferPlan = ({
  List<List<AssetTransferFile>> archiveBatches,
  List<AssetTransferFile> rangeFiles,
});

UsbTransferPlan usbTransferPlan(
  List<AssetTransferFile> files, {
  int chunkBytes = _usbChunkBytes,
  int maxArgumentBytes = 64 * 1024,
}) {
  final archiveFiles = <AssetTransferFile>[];
  final rangeFiles = <AssetTransferFile>[];
  for (final file in files) {
    (file.size > chunkBytes ? rangeFiles : archiveFiles).add(file);
  }
  return (
    archiveBatches: usbTransferBatches(
      archiveFiles,
      maxArgumentBytes: maxArgumentBytes,
      maxSourceBytes: chunkBytes,
    ),
    rangeFiles: rangeFiles,
  );
}

List<UsbByteRange> usbByteRanges(
  int fileSize, {
  int chunkBytes = _usbChunkBytes,
}) {
  if (fileSize < 0) {
    throw ArgumentError.value(fileSize, 'fileSize', 'must not be negative');
  }
  if (chunkBytes < 1) {
    throw ArgumentError.value(chunkBytes, 'chunkBytes', 'must be positive');
  }
  return [
    for (var offset = 0; offset < fileSize; offset += chunkBytes)
      UsbByteRange(
        offset: offset,
        length: (fileSize - offset).clamp(0, chunkBytes),
      ),
  ];
}

bool usbRangeDigestMatches(String expected, String output) {
  final firstLine = output.split('\n').first.trimLeft();
  if (firstLine.length < 64) return false;
  final digest = firstLine.substring(0, 64);
  return RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) && digest == expected;
}

List<String> usbRangeWriteAdbArguments(String remotePath, int rangeIndex) => [
  'exec-in',
  'run-as',
  _playerPackage,
  'dd',
  'of=$remotePath',
  'bs=$_usbRangeBytes',
  'seek=$rangeIndex',
  'conv=notrunc',
];

List<String> parseUsbAdbDevices(String output) {
  final devices = <String>[];
  for (final line in output.split('\n').skip(1)) {
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.length < 2 || fields[1] != 'device') continue;
    final serial = fields.first;
    // adb-over-network serials are host:port. Physical USB serials are not.
    if (!serial.contains(':') &&
        !serial.startsWith('emulator-') &&
        !serial.contains('._adb-tls-')) {
      devices.add(serial);
    }
  }
  return devices;
}

List<List<AssetTransferFile>> usbTransferBatches(
  List<AssetTransferFile> files, {
  int maxArgumentBytes = 64 * 1024,
  int maxSourceBytes = _usbChunkBytes,
}) {
  if (maxArgumentBytes < 1) {
    throw ArgumentError.value(
      maxArgumentBytes,
      'maxArgumentBytes',
      'must be positive',
    );
  }
  if (maxSourceBytes < 1) {
    throw ArgumentError.value(
      maxSourceBytes,
      'maxSourceBytes',
      'must be positive',
    );
  }
  final batches = <List<AssetTransferFile>>[];
  var batch = <AssetTransferFile>[];
  var argumentBytes = 0;
  var sourceBytes = 0;
  for (final file in files) {
    final nextBytes = file.relativePath.length + 1;
    if (batch.isNotEmpty &&
        (argumentBytes + nextBytes > maxArgumentBytes ||
            sourceBytes + file.size > maxSourceBytes)) {
      batches.add(batch);
      batch = <AssetTransferFile>[];
      argumentBytes = 0;
      sourceBytes = 0;
    }
    batch.add(file);
    argumentBytes += nextBytes;
    sourceBytes += file.size;
  }
  if (batch.isNotEmpty) batches.add(batch);
  return batches;
}

bool playerPreferencesHaveAssetStoreId(String xml, String expected) {
  final value = RegExp.escape(expected);
  return RegExp(
        '<string\\s+name="asset_store_id"[^>]*>\\s*$value\\s*</string>',
      ).hasMatch(xml) ||
      RegExp('name="asset_store_id"\\s+value="$value"').hasMatch(xml);
}

List<String> usbDigestMismatches({
  required List<AssetTransferFile> files,
  required String destination,
  required Map<String, AssetFingerprint> expected,
  required String digestOutput,
}) {
  final remoteDigests = <String, String>{};
  final prefix = '$destination/';
  for (final line in digestOutput.split('\n')) {
    final separator = line.indexOf('  ');
    if (separator != 64) continue;
    final digest = line.substring(0, separator);
    final path = line.substring(separator + 2);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
      continue;
    }
    if (path.startsWith(prefix)) {
      remoteDigests[path.substring(prefix.length)] = digest;
    } else if (!path.startsWith('/')) {
      remoteDigests[path] = digest;
    }
  }
  return [
    for (final file in files)
      if (remoteDigests[file.relativePath] !=
          expected[file.relativePath]?.sha256)
        file.relativePath,
  ];
}

bool _safeRelativePath(String path) {
  if (path.isEmpty ||
      path.startsWith('/') ||
      path.contains('\\') ||
      path.contains('\n') ||
      path.contains('\r')) {
    return false;
  }
  final segments = path.split('/');
  return segments.every((segment) => segment.isNotEmpty && segment != '..');
}

int _estimatedTarBytes(List<AssetTransferFile> files) {
  var bytes = 1024; // End-of-archive blocks.
  for (final file in files) {
    bytes += 512 + ((file.size + 511) ~/ 512) * 512;
  }
  return bytes;
}
