import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:rhr_cli/asset_transport.dart';
import 'package:rhr_cli/usb_asset_transport.dart';

typedef AssetProgress = void Function(String phase, int done, int total);

typedef _PreparedAsset = ({
  Uint8List encoded,
  int sourceBytes,
  String sha256,
  int compressionMs,
});

String devFsAssetUri(String relativePath) =>
    'build/flutter_assets/'
    '${relativePath.split('/').map(Uri.encodeComponent).join('/')}';

Future<void> syncAssets({
  required Uri vmService,
  required String project,
  Future<void>? devFsReady,
  String? assetStoreId,
  bool forceResync = false,
  int maxConcurrentUploads = 4,
  AssetTransport? transport,
  AssetProgress? onProgress,
  FutureOr<void> Function()? afterSync,
}) async {
  void report(String phase, int done, int total) =>
      onProgress?.call(phase, done, total);

  await (devFsReady ?? Future<void>.value());

  final assetDir = Directory('$project/build/flutter_assets');
  if (!assetDir.existsSync()) {
    throw StateError(
      'Missing ${assetDir.path}; Flutter did not build the asset bundle.',
    );
  }

  final fsName = Uri.file(
    Directory(project).absolute.path,
  ).pathSegments.lastWhere((segment) => segment.isNotEmpty);
  stderr.writeln('[rhr] syncing assets to DevFS "$fsName"...');

  final manifestFile = File('$project/.dart_tool/rhr/pushed_assets.json');
  final manifest = <String, dynamic>{};
  if (forceResync) {
    stderr.writeln('[rhr] forced asset resync — ignoring local manifest');
  } else if (manifestFile.existsSync()) {
    final decoded = jsonDecode(manifestFile.readAsStringSync());
    if (decoded is Map<String, dynamic>) {
      if (assetStoreId == null) {
        final files = decoded['files'];
        manifest.addAll(files is Map<String, dynamic> ? files : decoded);
      } else if (decoded['assetStoreId'] == assetStoreId &&
          decoded['files'] is Map<String, dynamic>) {
        manifest.addAll(decoded['files'] as Map<String, dynamic>);
      } else {
        stderr.writeln(
          '[rhr] phone asset store changed — invalidating local manifest',
        );
      }
    }
  }

  void saveManifest() {
    manifestFile.parent.createSync(recursive: true);
    manifestFile.writeAsStringSync(
      jsonEncode(
        assetStoreId == null
            ? manifest
            : {'assetStoreId': assetStoreId, 'files': manifest},
      ),
    );
  }

  // Content hash, not mtime: a rebuild rewrites mtimes on files whose bytes
  // never changed (re-uploading them for nothing), and a restored/checked-out
  // file can change content while keeping size and mtime (silently skipping a
  // real change). Size is checked first so differing files skip the read.
  String hashOf(List<int> bytes) => sha256.convert(bytes).toString();

  bool unchanged(File file, String relativePath) {
    final entry = manifest[relativePath];
    if (entry is! Map) return false;
    final stat = file.statSync();
    if (entry['size'] != stat.size) return false;
    final hash = entry['sha256'];
    if (hash is! String) {
      // Manifest written by an older rhr (size+mtime only). Fall back to the
      // old check so upgrading doesn't force a full re-upload; the entry gains
      // a hash the next time this file is pushed.
      return entry['mtime'] == stat.modified.millisecondsSinceEpoch;
    }
    return hash == hashOf(file.readAsBytesSync());
  }

  final allFiles = assetDir
      .listSync(recursive: true)
      .whereType<File>()
      .toList(growable: false);
  final currentPaths = allFiles
      .map((file) => file.path.substring(assetDir.path.length + 1))
      .toSet();
  final deletedPaths = manifest.keys
      .where((path) => !currentPaths.contains(path))
      .toList(growable: false);
  for (final path in deletedPaths) {
    manifest.remove(path);
  }
  if (deletedPaths.isNotEmpty) {
    stderr.writeln(
      '[rhr] removed ${deletedPaths.length} deleted asset(s) from manifest',
    );
  }
  final files = allFiles
      .where((file) {
        final relativePath = file.path.substring(assetDir.path.length + 1);
        return !unchanged(file, relativePath);
      })
      .toList(growable: false);
  // Workers pop from the end, so this sends large files first. That prevents a
  // single large video/font from becoming a long serial tail after every small
  // file has finished.
  files.sort((a, b) => a.lengthSync().compareTo(b.lengthSync()));

  final skipped = allFiles.length - files.length;
  if (skipped > 0) {
    stderr.writeln(
      '[rhr] $skipped assets already on device (manifest), '
      'pushing ${files.length} changed',
    );
  }
  if (files.isEmpty) {
    saveManifest();
    stderr.writeln('[rhr] assets already in sync.');
    await afterSync?.call();
    return;
  }

  final transferFiles = files
      .map(
        (file) => AssetTransferFile(
          source: file,
          relativePath: file.path.substring(assetDir.path.length + 1),
          size: file.lengthSync(),
        ),
      )
      .toList(growable: false);
  final totalBytes = transferFiles.fold<int>(0, (sum, file) => sum + file.size);
  // Report KiB rather than file counts: files vary from a few bytes to several
  // megabytes, so byte-weighted progress is both smoother and truthful. KiB
  // also keeps Android's Int-based progress fields safe for very large apps.
  final totalKiB = (totalBytes / 1024).ceil();
  report('assets', 0, totalKiB);
  final devFsTransport = _DevFsAssetTransport(
    vmService: vmService,
    fsName: fsName,
    maxConcurrentUploads: maxConcurrentUploads,
  );
  AssetTransport selected = transport ?? devFsTransport;
  if (transport == null) {
    final usb = await UsbAssetTransport.discover(assetStoreId: assetStoreId);
    if (usb != null) {
      stderr.writeln(
        '[rhr] USB asset fast path: ${usb.serial} '
        '(wireless fallback enabled)',
      );
      selected = FallbackAssetTransport(
        preferred: usb,
        fallback: devFsTransport,
        onFallback: (error) => stderr.writeln(
          '[rhr] USB asset transfer failed: $error\n'
          '[rhr] falling back to the selected wireless tunnel...',
        ),
      );
    }
  }

  AssetTransferResult result;
  try {
    result = await selected.transfer(
      AssetTransferRequest(
        assetRoot: assetDir,
        projectName: fsName,
        files: transferFiles,
        onProgress: (sentBytes) =>
            report('assets', (sentBytes / 1024).ceil(), totalKiB),
      ),
    );
  } on AssetTransferException catch (error) {
    _applyFingerprints(manifest, error.partialResult.completed);
    saveManifest();
    throw StateError(error.message);
  }

  _applyFingerprints(manifest, result.completed);
  saveManifest();
  final missing = transferFiles
      .map((file) => file.relativePath)
      .where((path) => !result.completed.containsKey(path))
      .toList();
  if (missing.isNotEmpty) {
    throw StateError(
      'Asset sync incomplete; ${missing.length} file(s) were not verified: '
      '${missing.join(', ')}',
    );
  }
  final elapsedSeconds = result.elapsed.inMilliseconds / 1000;
  final rawMb = totalBytes / 1024 / 1024;
  final wireMb = result.wireBytes / 1024 / 1024;
  final throughput = elapsedSeconds == 0 ? 0 : wireMb / elapsedSeconds;
  stderr.writeln(
    '[rhr] asset sync via ${result.transportLabel} done in '
    '${elapsedSeconds.toStringAsFixed(1)}s: '
    '${rawMb.toStringAsFixed(1)} MB raw → ${wireMb.toStringAsFixed(1)} MB wire, '
    '${throughput.toStringAsFixed(1)} MB/s, '
    '${result.compressionMilliseconds}ms aggregate compression.',
  );
  await afterSync?.call();
}

void _applyFingerprints(
  Map<String, dynamic> manifest,
  Map<String, AssetFingerprint> fingerprints,
) {
  for (final entry in fingerprints.entries) {
    manifest[entry.key] = {
      'size': entry.value.size,
      'sha256': entry.value.sha256,
    };
  }
}

final class _DevFsAssetTransport implements AssetTransport {
  const _DevFsAssetTransport({
    required this.vmService,
    required this.fsName,
    required this.maxConcurrentUploads,
  });

  final Uri vmService;
  final String fsName;
  final int maxConcurrentUploads;

  @override
  String get label => 'DevFS tunnel';

  @override
  Future<AssetTransferResult> transfer(AssetTransferRequest request) async {
    final stopwatch = Stopwatch()..start();
    final client = HttpClient();
    final completed = <String, AssetFingerprint>{};
    final queue = List.of(request.files);
    final failedPaths = <String>[];
    var sentFiles = 0;
    var sentBytes = 0;
    var encodedBytes = 0;
    var compressionMs = 0;

    Future<_PreparedAsset> prepare(AssetTransferFile file) async {
      final bytes = await file.source.readAsBytes();
      return Isolate.run(() {
        final timer = Stopwatch()..start();
        final encoded = Uint8List.fromList(
          ZLibEncoder(gzip: true, level: 6).convert(bytes),
        );
        timer.stop();
        return (
          encoded: encoded,
          sourceBytes: bytes.length,
          sha256: sha256.convert(bytes).toString(),
          compressionMs: timer.elapsedMilliseconds,
        );
      });
    }

    Future<bool> upload(AssetTransferFile file, _PreparedAsset prepared) async {
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          final httpRequest = await client.putUrl(vmService);
          httpRequest.headers.removeAll(HttpHeaders.acceptEncodingHeader);
          httpRequest.headers.add('dev_fs_name', fsName);
          httpRequest.headers.add(
            'dev_fs_uri_b64',
            base64.encode(utf8.encode(devFsAssetUri(file.relativePath))),
          );
          httpRequest.add(prepared.encoded);
          final response = await httpRequest.close().timeout(
            const Duration(seconds: 60),
          );
          final body = await response.transform(utf8.decoder).join();
          if (body.contains('"error"')) {
            throw Exception('DevFS write rejected: $body');
          }
          completed[file.relativePath] = AssetFingerprint(
            size: prepared.sourceBytes,
            sha256: prepared.sha256,
          );
          return true;
        } on Exception catch (error) {
          if (attempt == 2) {
            stderr.writeln('[rhr] failed to push ${file.relativePath}: $error');
            return false;
          }
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }
      return false;
    }

    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final file = queue.removeLast();
        final prepared = await prepare(file);
        compressionMs += prepared.compressionMs;
        encodedBytes += prepared.encoded.length;
        if (!await upload(file, prepared)) failedPaths.add(file.relativePath);
        sentFiles++;
        sentBytes += file.size;
        request.onProgress(sentBytes);
        if (sentFiles % 50 == 0 || sentFiles == request.files.length) {
          final mb = (sentBytes / 1024 / 1024).toStringAsFixed(1);
          final totalMb = (request.totalBytes / 1024 / 1024).toStringAsFixed(1);
          stderr.writeln(
            '[rhr] assets: $sentFiles/${request.files.length} files, '
            '$mb/$totalMb MB, ${stopwatch.elapsed.inSeconds}s',
          );
        }
      }
    }

    final workerCount = maxConcurrentUploads.clamp(1, request.files.length);
    await Future.wait([
      for (var index = 0; index < workerCount; index++) worker(),
    ]);
    client.close();
    stopwatch.stop();
    final result = AssetTransferResult(
      completed: completed,
      wireBytes: encodedBytes,
      elapsed: stopwatch.elapsed,
      transportLabel: label,
      compressionMilliseconds: compressionMs,
    );
    if (failedPaths.isNotEmpty) {
      failedPaths.sort();
      throw AssetTransferException(
        'Asset sync incomplete; ${failedPaths.length} file(s) failed: '
        '${failedPaths.join(', ')}',
        result,
      );
    }
    return result;
  }
}
