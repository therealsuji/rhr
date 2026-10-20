import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'flutter_compatibility.dart';

/// What a project's debug APK is built from, in two parts. [native] is
/// everything but Dart source: a change there needs a new APK. [dart] is the
/// Dart source: a change there reaches a running app by hot restart, a few
/// kilobytes, so it must not cost a 40 MB rebuild and reinstall.
typedef ProjectBuildIdentity = ({String native, String dart});

/// A receipt is only reusable while both the build inputs and APK are unchanged.
Future<ProjectBuildIdentity> projectBuildIdentity(
  String project,
  FlutterCompatibility sdk,
) async {
  final root = Directory(project).absolute;
  final roots = <String>{root.resolveSymbolicLinksSync()};
  final config = File('${pubRoot(root.path)}/.dart_tool/package_config.json');
  if (config.existsSync()) {
    final decoded =
        jsonDecode(await config.readAsString()) as Map<String, dynamic>;
    for (final package
        in (decoded['packages'] as List).cast<Map<String, dynamic>>()) {
      final uri = config.uri.resolve(package['rootUri'] as String);
      if (uri.scheme != 'file') continue;
      final directory = Directory.fromUri(uri);
      // Flutter's packages are identified by the SDK revisions below.
      if (directory.path.contains('/packages/flutter')) continue;
      final path = directory.resolveSymbolicLinksSync();
      if (path != root.path && !path.startsWith('${root.path}/'))
        roots.add(path);
    }
  }
  final inputs = <String>[
    sdk.frameworkRevision,
    sdk.engineRevision,
    sdk.dartSdkVersion,
  ];
  final dartInputs = <String>[];
  final visited = <String>{};
  Future<void> visit(Directory directory) async {
    final canonical = directory.resolveSymbolicLinksSync();
    if (!visited.add(canonical)) return;
    await for (final entry in Directory(canonical).list(followLinks: false)) {
      final name = entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
      if ({
        'build',
        '.dart_tool',
        '.gradle',
        '.git',
        '.idea',
        '.DS_Store',
        '.fvm',
        '.cxx',
        '.kotlin',
        '.flutter-plugins-dependencies',
        'local.properties',
        'GeneratedPluginRegistrant.java',
        'GeneratedPluginRegistrant.kt',
      }.contains(name))
        continue;
      if (entry is Directory) {
        await visit(entry);
      } else if (entry is File) {
        (entry.path.endsWith('.dart') ? dartInputs : inputs).add(
          '${entry.path}:${await sha256.bind(entry.openRead()).first}',
        );
      } else if (entry is Link) {
        final target = entry.resolveSymbolicLinksSync();
        inputs.add('${entry.path}:$target');
        if (Directory(target).existsSync()) {
          await visit(Directory(target));
        } else {
          inputs.add(
            '$target:${await sha256.bind(File(target).openRead()).first}',
          );
        }
      }
    }
  }

  for (final path in roots) await visit(Directory(path));
  String digest(List<String> lines) =>
      sha256.convert(utf8.encode((lines..sort()).join('\n'))).toString();
  return (native: digest(inputs), dart: digest(dartInputs));
}

/// The key Gradle signs a debug build with when the project names none,
/// where the Android Gradle plugin looks for it. It is a build input like the
/// project's own files: an APK signed with another key cannot update the app
/// already on the phone.
File defaultDebugKeystore([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  final userHome = env['ANDROID_USER_HOME'];
  if (userHome != null && userHome.isNotEmpty) {
    return File('$userHome/debug.keystore');
  }
  final sdkHome = env['ANDROID_SDK_HOME'];
  if (sdkHome != null && sdkHome.isNotEmpty) {
    return File('$sdkHome/.android/debug.keystore');
  }
  final home = env['HOME'] ?? env['USERPROFILE'] ?? '';
  return File('$home/.android/debug.keystore');
}

/// Every debug keystore on this machine a past build may have signed with.
///
/// One machine often has several: `ANDROID_USER_HOME` set in an interactive
/// shell's config points Gradle at one, while an SSH or agent shell without
/// that config falls back to `~/.android` and Gradle makes a new key there.
List<File> debugKeystoreCandidates([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  final home = env['HOME'] ?? env['USERPROFILE'] ?? '';
  final sdkHome = env['ANDROID_SDK_HOME'];
  final paths = {
    defaultDebugKeystore(env).path,
    if (sdkHome != null && sdkHome.isNotEmpty)
      '$sdkHome/.android/debug.keystore',
    '$home/.android/debug.keystore',
    // The usual ANDROID_USER_HOME for people who keep dotfiles under XDG.
    '$home/.config/.android/debug.keystore',
  };
  return [
    for (final path in paths)
      if (File(path).existsSync()) File(path),
  ];
}

/// The SHA-256 digest of [keystore]'s debug certificate, in the form
/// apksigner prints and the phone reports, or null when keytool cannot read
/// it. Debug keystores all use the same well-known password and alias.
Future<String?> debugKeystoreCertificate(
  File keystore, [
  Map<String, String>? environment,
]) async {
  final env = environment ?? Platform.environment;
  final javaHome = env['JAVA_HOME'];
  final bundled = javaHome == null ? null : File('$javaHome/bin/keytool');
  try {
    final result = await Process.run(
      bundled != null && bundled.existsSync() ? bundled.path : 'keytool',
      [
        '-list',
        '-v',
        '-keystore',
        keystore.path,
        '-storepass',
        'android',
        '-alias',
        'androiddebugkey',
      ],
    );
    return result.exitCode == 0 ? keytoolSha256('${result.stdout}') : null;
  } on ProcessException {
    return null;
  }
}

/// The `SHA256:` fingerprint in `keytool -list -v` output, colons removed.
String? keytoolSha256(String output) => RegExp(
  r'SHA256:\s*([0-9A-Fa-f:]+)',
).firstMatch(output)?.group(1)!.replaceAll(':', '').toLowerCase();

File _signingPin(String project) =>
    File('$project/.dart_tool/rhr/android-user-home');

/// Records that [project]'s debug builds sign with the key in [userHome],
/// because that is the key the app already on the phone was signed with.
/// Under `.dart_tool`, so `flutter clean` drops it and the next mismatch
/// finds the key again.
Future<void> pinDebugSigning(String project, Directory userHome) async {
  final pin = _signingPin(project);
  await pin.parent.create(recursive: true);
  await pin.writeAsString('${userHome.absolute.path}\n');
}

/// The environment [project]'s debug build runs Gradle with: the pinned
/// `ANDROID_USER_HOME` when there is one, so Gradle signs with that key.
Future<Map<String, String>> debugSigningEnvironment(String project) async {
  final pin = _signingPin(project);
  if (!pin.existsSync()) return const {};
  final userHome = (await pin.readAsString()).trim();
  if (!File('$userHome/debug.keystore').existsSync()) return const {};
  return {'ANDROID_USER_HOME': userHome};
}

/// [defaultDebugKeystore]'s digest, or `none` before Gradle has made one.
Future<String> debugKeystoreDigest([Map<String, String>? environment]) async {
  final keystore = defaultDebugKeystore(environment);
  if (!keystore.existsSync()) return 'none';
  return (await sha256.bind(keystore.openRead()).first).toString();
}

/// The cached APK built from [identity], and the Dart source it carries.
Future<({File apk, String dart})?> cachedProjectApk(
  String project,
  String identity,
) async {
  final receipt = File('$project/.dart_tool/rhr/app-build.json');
  if (!receipt.existsSync()) return null;
  try {
    final data = jsonDecode(await receipt.readAsString());
    if (data is! Map<String, dynamic> || data['inputs'] != identity)
      return null;
    final apk = File('$project/.dart_tool/rhr/app-debug.apk');
    if (!apk.existsSync()) return null;
    final digest = (await sha256.bind(apk.openRead()).first).toString();
    final dart = data['dart'];
    return digest == data['apk'] && dart is String
        ? (apk: apk, dart: dart)
        : null;
  } on FormatException {
    return null;
  }
}

Future<void> recordProjectApk(
  String project,
  String identity,
  String dart,
  File apk,
) async {
  final receipt = File('$project/.dart_tool/rhr/app-build.json');
  await receipt.parent.create(recursive: true);
  final temporary = File('${receipt.path}.tmp');
  await temporary.writeAsString(
    jsonEncode({
      'inputs': identity,
      'dart': dart,
      'apk': (await sha256.bind(apk.openRead()).first).toString(),
    }),
    flush: true,
  );
  await temporary.rename(receipt.path);
}
