import 'dart:io';

final class AssetTransferFile {
  const AssetTransferFile({
    required this.source,
    required this.relativePath,
    required this.size,
  });

  final File source;
  final String relativePath;
  final int size;
}

final class AssetFingerprint {
  const AssetFingerprint({required this.size, required this.sha256});

  final int size;
  final String sha256;
}

final class AssetTransferRequest {
  const AssetTransferRequest({
    required this.assetRoot,
    required this.projectName,
    required this.files,
    required this.onProgress,
  });

  final Directory assetRoot;
  final String projectName;
  final List<AssetTransferFile> files;
  final void Function(int sentBytes) onProgress;

  int get totalBytes => files.fold(0, (sum, file) => sum + file.size);
}

final class AssetTransferResult {
  const AssetTransferResult({
    required this.completed,
    required this.wireBytes,
    required this.elapsed,
    required this.transportLabel,
    this.compressionMilliseconds = 0,
  });

  final Map<String, AssetFingerprint> completed;
  final int wireBytes;
  final Duration elapsed;
  final String transportLabel;
  final int compressionMilliseconds;

  int get sourceBytes =>
      completed.values.fold(0, (sum, item) => sum + item.size);
}

final class AssetTransferException implements Exception {
  const AssetTransferException(this.message, this.partialResult);

  final String message;
  final AssetTransferResult partialResult;

  @override
  String toString() => message;
}

/// One delivery route beneath the asset manifest/cache module.
///
/// Implementations own transport-specific preparation, retries, verification,
/// and wire metrics. Callers only provide changed files and consume verified
/// fingerprints, so adding a route does not duplicate cache logic.
abstract interface class AssetTransport {
  String get label;

  Future<AssetTransferResult> transfer(AssetTransferRequest request);
}

/// Tries a preferred route once, then transfers the complete batch through the
/// reliable fallback. A failed preferred route never updates the manifest.
final class FallbackAssetTransport implements AssetTransport {
  const FallbackAssetTransport({
    required this.preferred,
    required this.fallback,
    this.onFallback,
  });

  final AssetTransport preferred;
  final AssetTransport fallback;
  final void Function(Object error)? onFallback;

  @override
  String get label => '${preferred.label} → ${fallback.label} fallback';

  @override
  Future<AssetTransferResult> transfer(AssetTransferRequest request) async {
    try {
      return await preferred.transfer(request);
    } on Object catch (error) {
      onFallback?.call(error);
      request.onProgress(0);
      return fallback.transfer(request);
    }
  }
}
