import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef AssetProgress = void Function(String phase, int done, int total);

String devFsAssetUri(String relativePath) =>
    'build/flutter_assets/'
    '${relativePath.split('/').map(Uri.encodeComponent).join('/')}';

Future<void> syncAssets({
  required Uri vmService,
  required String project,
  Future<void>? devFsReady,
  String? assetStoreId,
  bool forceResync = false,
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

  bool unchanged(File file, String relativePath) {
    final entry = manifest[relativePath];
    if (entry is! Map) return false;
    final stat = file.statSync();
    return entry['size'] == stat.size &&
        entry['mtime'] == stat.modified.millisecondsSinceEpoch;
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

  final totalBytes = files.fold<int>(0, (sum, file) => sum + file.lengthSync());
  // Report KiB rather than file counts: files vary from a few bytes to several
  // megabytes, so byte-weighted progress is both smoother and truthful. KiB
  // also keeps Android's Int-based progress fields safe for very large apps.
  final totalKiB = (totalBytes / 1024).ceil();
  report('assets', 0, totalKiB);
  var sentFiles = 0;
  var sentBytes = 0;
  final stopwatch = Stopwatch()..start();
  final client = HttpClient();

  Future<bool> upload(File file) async {
    final relativePath = file.path.substring(assetDir.path.length + 1);
    final bytes = await file.readAsBytes();
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final request = await client.putUrl(vmService);
        request.headers.removeAll(HttpHeaders.acceptEncodingHeader);
        request.headers.add('dev_fs_name', fsName);
        request.headers.add(
          'dev_fs_uri_b64',
          base64.encode(utf8.encode(devFsAssetUri(relativePath))),
        );
        request.add(gzip.encode(bytes));
        final response = await request.close().timeout(
          const Duration(seconds: 60),
        );
        final body = await response.transform(utf8.decoder).join();
        if (body.contains('"error"')) {
          throw StateError('DevFS write rejected: $body');
        }
        final stat = file.statSync();
        manifest[relativePath] = {
          'size': stat.size,
          'mtime': stat.modified.millisecondsSinceEpoch,
        };
        return true;
      } on Exception catch (error) {
        if (attempt == 2) {
          stderr.writeln('[rhr] failed to push $relativePath: $error');
          return false;
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    return false;
  }

  // Probe serially so an invalid DevFS name fails before a large parallel push.
  if (!await upload(files.first)) {
    client.close();
    throw StateError('DevFS rejected the first asset upload.');
  }
  sentFiles = 1;
  sentBytes = files.first.lengthSync();
  // Persist the successful probe immediately. If a later parallel upload
  // fails, the retry can still reuse this known-good file.
  saveManifest();
  report('assets', (sentBytes / 1024).ceil(), totalKiB);

  final queue = List.of(files.skip(1));
  final failedPaths = <String>[];
  Future<void> worker() async {
    while (queue.isNotEmpty) {
      final file = queue.removeLast();
      final uploaded = await upload(file);
      if (!uploaded) {
        failedPaths.add(file.path.substring(assetDir.path.length + 1));
      }
      sentFiles++;
      sentBytes += file.lengthSync();
      report('assets', (sentBytes / 1024).ceil(), totalKiB);
      if (sentFiles % 50 == 0 || sentFiles == files.length) {
        saveManifest();
        final mb = (sentBytes / 1024 / 1024).toStringAsFixed(1);
        final totalMb = (totalBytes / 1024 / 1024).toStringAsFixed(1);
        stderr.writeln(
          '[rhr] assets: $sentFiles/${files.length} files, '
          '$mb/$totalMb MB, ${stopwatch.elapsed.inSeconds}s',
        );
      }
    }
  }

  await Future.wait([for (var index = 0; index < 4; index++) worker()]);
  client.close();
  saveManifest();
  if (failedPaths.isNotEmpty) {
    failedPaths.sort();
    throw StateError(
      'Asset sync incomplete; ${failedPaths.length} file(s) failed: '
      '${failedPaths.join(', ')}',
    );
  }
  stderr.writeln('[rhr] asset sync done in ${stopwatch.elapsed.inSeconds}s.');
  await afterSync?.call();
}
