import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'flutter_compatibility.dart';

/// A content hash of everything that decides a project's native build: the
/// resolved dependencies, the Android plugins Flutter registered, the
/// project's own `android/` tree, and the Android sources of plugins that
/// come from a path rather than a published version.
///
/// A running session compares this against the value at its start. A native
/// change cannot reach a running app by hot reload or restart; noticing it is
/// what turns a silent MissingPluginException into a clear rebuild.
///
/// Published and git plugins are covered by `pubspec.lock`: their sources
/// never change for a given resolved version. `.flutter-plugins-dependencies`
/// is hashed by its plugin lists only, since Flutter rewrites its
/// `date_created` on every `pub get`.
Future<String> nativeFingerprint(String project) async {
  final root = Directory(project).absolute.path;
  final parts = <String>[];

  Future<void> addFile(File file) async {
    if (!file.existsSync()) return;
    parts.add('${file.path}:${await sha256.bind(file.openRead()).first}');
  }

  Future<void> addTree(Directory directory) async {
    if (!directory.existsSync()) return;
    await for (final entry in directory.list(followLinks: false)) {
      final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (_skipped.contains(name)) continue;
      if (entry is Directory) {
        await addTree(entry);
      } else if (entry is File) {
        await addFile(entry);
      }
    }
  }

  await addFile(File('$root/pubspec.lock'));
  await addTree(Directory('$root/android'));

  final plugins = File('$root/.flutter-plugins-dependencies');
  final local = readPathPackages(root);
  if (plugins.existsSync()) {
    try {
      final decoded = jsonDecode(plugins.readAsStringSync());
      final android =
          (decoded as Map<String, dynamic>)['plugins']?['android'] as List?;
      for (final plugin in android ?? const []) {
        if (plugin is! Map<String, dynamic>) continue;
        parts.add('plugin:${plugin['name']}:${plugin['path']}');
        final path = plugin['path'];
        if (path is String && local.contains(plugin['name'])) {
          await addTree(Directory('$path/android'));
        }
      }
    } on FormatException {
      await addFile(plugins);
    }
  }

  parts.sort();
  return sha256.convert(utf8.encode(parts.join('\n'))).toString();
}

/// Build output and machine-local files: they change with every build and
/// say nothing about the native code itself.
const _skipped = {
  'build',
  '.gradle',
  '.cxx',
  '.kotlin',
  '.idea',
  '.DS_Store',
  'local.properties',
  'GeneratedPluginRegistrant.java',
  'GeneratedPluginRegistrant.kt',
};
