import 'dart:io';

final class ApkIdentity {
  const ApkIdentity(this.package, this.certificate);
  final String package;
  final String certificate;
}

Future<ApkIdentity> readApkIdentity(File apk) async {
  final home = Platform.environment['HOME'] ?? '';
  final roots = [
    Platform.environment['ANDROID_HOME'],
    Platform.environment['ANDROID_SDK_ROOT'],
    '$home/Library/Android/sdk',
    '$home/Android/Sdk',
  ];
  for (final root in roots.whereType<String>()) {
    final directory = Directory('$root/build-tools');
    if (!directory.existsSync()) continue;
    final versions = directory.listSync().whereType<Directory>().toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    for (final version in versions) {
      final aapt = File('${version.path}/aapt');
      final signer = File('${version.path}/apksigner');
      if (!aapt.existsSync() || !signer.existsSync()) continue;
      final manifest = await Process.run(aapt.path, [
        'dump',
        'badging',
        apk.path,
      ]);
      final signatures = await Process.run(signer.path, [
        'verify',
        '--print-certs',
        apk.path,
      ]);
      final package = RegExp(
        "^package: name='([^']+)'",
      ).firstMatch('${manifest.stdout}')?.group(1);
      final certificate = RegExp(
        r'Signer #1 certificate SHA-256 digest: ([a-fA-F0-9]+)',
      ).firstMatch('${signatures.stdout}')?.group(1)?.toLowerCase();
      if (manifest.exitCode != 0 ||
          signatures.exitCode != 0 ||
          package == null ||
          certificate == null) {
        throw StateError(
          'Could not verify the built APK package and signing identity with Android build tools.',
        );
      }
      if (!'${manifest.stdout}'.contains('application-debuggable')) {
        throw StateError(
          'The built APK is not debuggable. RHR requires a debug build.',
        );
      }
      return ApkIdentity(package, certificate);
    }
  }
  throw StateError(
    'Android build tools are missing. Install them through the Android SDK manager.',
  );
}
