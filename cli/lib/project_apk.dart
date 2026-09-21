import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'flutter_compatibility.dart';

/// A receipt is only reusable while both the build inputs and APK are unchanged.
Future<String> projectBuildIdentity(
  String project,
  FlutterCompatibility sdk,
) async {
  final root = Directory(project).absolute;
  final roots = <String>{root.resolveSymbolicLinksSync()};
  final config = File('${root.path}/.dart_tool/package_config.json');
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
        inputs.add(
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
  inputs.sort();
  return sha256.convert(utf8.encode(inputs.join('\n'))).toString();
}

Future<File?> cachedProjectApk(String project, String identity) async {
  final receipt = File('$project/.dart_tool/rhr/app-build.json');
  if (!receipt.existsSync()) return null;
  try {
    final data = jsonDecode(await receipt.readAsString());
    if (data is! Map<String, dynamic> || data['inputs'] != identity)
      return null;
    final apk = File('$project/.dart_tool/rhr/app-debug.apk');
    if (!apk.existsSync()) return null;
    final digest = (await sha256.bind(apk.openRead()).first).toString();
    return digest == data['apk'] ? apk : null;
  } on FormatException {
    return null;
  }
}

Future<void> recordProjectApk(String project, String identity, File apk) async {
  final receipt = File('$project/.dart_tool/rhr/app-build.json');
  await receipt.parent.create(recursive: true);
  final temporary = File('${receipt.path}.tmp');
  await temporary.writeAsString(
    jsonEncode({
      'inputs': identity,
      'apk': (await sha256.bind(apk.openRead()).first).toString(),
    }),
    flush: true,
  );
  await temporary.rename(receipt.path);
}
