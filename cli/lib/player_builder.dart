import 'dart:convert';
import 'dart:io';

import 'package:rhr_cli/flutter_compatibility.dart';

final class PlayerBuildProfile {
  const PlayerBuildProfile({
    required this.id,
    required this.plugins,
    required this.permissions,
  });

  final String id;
  final Map<String, String> plugins;
  final Set<String> permissions;

  Map<String, Object> toJson() => {
    'id': id,
    'androidPlugins': plugins,
    'androidPermissions': permissions.toList()..sort(),
  };
}

Future<File> buildProjectPlayer({
  required String project,
  required String template,
  required String output,
  String flutterExecutable = 'flutter',
  String? targetPlatform,
}) async {
  final projectDirectory = Directory(project).absolute;
  final templateDirectory = Directory(template).absolute;
  if (!File('${projectDirectory.path}/pubspec.yaml').existsSync()) {
    throw StateError('${projectDirectory.path} is not a Flutter project');
  }
  if (!File('${templateDirectory.path}/pubspec.yaml').existsSync()) {
    throw StateError('player template not found at ${templateDirectory.path}');
  }

  final unsupported = readUnsupportedAndroidInputs(projectDirectory.path);
  if (unsupported.isNotEmpty) {
    throw UnsupportedError(
      'Automatic player generation cannot transplant these project-specific '
      'Android inputs yet:\n  - ${unsupported.join('\n  - ')}',
    );
  }

  final workspace = await Directory.systemTemp.createTemp('rhr_player_build_');
  try {
    await _copyTemplate(templateDirectory, workspace);
    absolutizeTemplatePathDeps(
      File('${workspace.path}/pubspec.yaml'),
      templateDirectory.path,
    );
    final profile = prepareProjectPlayer(
      project: projectDirectory.path,
      workspace: workspace.path,
    );
    stderr.writeln('[rhr] generated player profile ${profile.id}');
    stderr.writeln(
      '[rhr] ${profile.plugins.length} Android plugins, '
      '${profile.permissions.length} permissions',
    );

    await _runChecked(flutterExecutable, ['pub', 'get'], workspace.path);
    await _runChecked(flutterExecutable, [
      'build',
      'apk',
      '--debug',
      if (targetPlatform != null) ...['--target-platform', targetPlatform],
    ], workspace.path);

    final built = File(
      '${workspace.path}/build/app/outputs/flutter-apk/app-debug.apk',
    );
    if (!built.existsSync()) {
      throw StateError('Flutter completed without producing ${built.path}');
    }
    final destination = File(output).absolute;
    destination.parent.createSync(recursive: true);
    await built.copy(destination.path);
    final profileFile = File('${destination.path}.profile.json');
    profileFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(profile.toJson()),
    );
    return destination;
  } finally {
    if (workspace.existsSync()) {
      await workspace.delete(recursive: true);
    }
  }
}

PlayerBuildProfile prepareProjectPlayer({
  required String project,
  required String workspace,
}) {
  final pluginSources = readAndroidPluginSources(project);
  final permissions = readAndroidPermissionProfile(project);
  _injectPluginDependencies(File('$workspace/pubspec.yaml'), pluginSources);
  _injectPermissions(
    File('$workspace/android/app/src/main/AndroidManifest.xml'),
    permissions,
  );

  final plugins = <String, String>{
    for (final plugin in pluginSources) plugin.name: plugin.version,
  };
  return PlayerBuildProfile(
    id: _profileId(plugins, permissions),
    plugins: Map.unmodifiable(plugins),
    permissions: Set.unmodifiable(permissions),
  );
}

/// The profile id a [buildProjectPlayer] run would stamp for this project,
/// computed without building. Used as a cache key by the over-the-wire
/// update: same plugins + permissions + SDK means the same player APK.
String projectPlayerProfileId(String project) {
  final plugins = <String, String>{
    for (final plugin in readAndroidPluginSources(project))
      plugin.name: plugin.version,
  };
  return _profileId(plugins, readAndroidPermissionProfile(project));
}

String _profileId(Map<String, String> plugins, Set<String> permissions) {
  final canonical = jsonEncode({
    'plugins': Map.fromEntries(
      plugins.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    ),
    'permissions': permissions.toList()..sort(),
  });
  return 'android-${_fnv1a64(canonical)}';
}

/// Bounds of one top-level pubspec section: (start of the line after the
/// `name:` header, index of the next top-level key or end of file).
(int, int)? _sectionBounds(String contents, String name) {
  final header = RegExp('^$name:\\s*\$', multiLine: true).firstMatch(contents);
  if (header == null) return null;
  final start = contents.indexOf('\n', header.start) + 1;
  final next = RegExp(
    r'^[a-zA-Z_]',
    multiLine: true,
  ).firstMatch(contents.substring(start));
  return (start, next == null ? contents.length : start + next.start);
}

void _injectPluginDependencies(
  File pubspec,
  List<AndroidPluginSource> plugins,
) {
  var contents = pubspec.readAsStringSync();
  final dependencies = _sectionBounds(contents, 'dependencies');
  if (dependencies == null) {
    throw const FormatException('player pubspec has no dependencies section');
  }
  final (depsStart, depsEnd) = dependencies;
  final existing = RegExp(r'^  ([a-zA-Z0-9_]+):', multiLine: true)
      .allMatches(contents.substring(depsStart, depsEnd))
      .map((match) => match.group(1)!)
      .toSet();
  final additions = StringBuffer();
  for (final plugin in plugins.where((p) => !existing.contains(p.name))) {
    additions.writeln('  ${plugin.name}:');
    additions.writeln('    path: ${plugin.path}');
  }
  contents = contents.replaceRange(depsEnd, depsEnd, additions.toString());

  // Overrides pin every plugin to the project's resolved source. The
  // template may already carry a dependency_overrides section (the vendored
  // webrtc_dart); a second section is a YAML duplicate-key error, so merge
  // into the existing one.
  final overrides = StringBuffer();
  for (final plugin in plugins) {
    overrides.writeln('  ${plugin.name}:');
    overrides.writeln('    path: ${plugin.path}');
  }
  final existingOverrides = _sectionBounds(contents, 'dependency_overrides');
  if (existingOverrides != null) {
    final (start, _) = existingOverrides;
    contents = contents.replaceRange(start, start, overrides.toString());
    pubspec.writeAsStringSync(contents);
  } else {
    pubspec.writeAsStringSync('$contents\ndependency_overrides:\n$overrides');
  }
}

/// The template's own `path:` dependencies are relative to the template
/// checkout (e.g. `../third_party/webrtc_dart`). The build runs in a temp
/// workspace copy, so anchor them back to the template as absolute paths.
void absolutizeTemplatePathDeps(File pubspec, String templateRoot) {
  final templateUri = Directory(templateRoot).absolute.uri;
  final contents = pubspec.readAsStringSync();
  final rewritten = contents.replaceAllMapped(
    RegExp(r'^(\s+path:\s+)(\.\.?/\S+)\s*$', multiLine: true),
    (match) =>
        '${match[1]}${templateUri.resolve(match[2]!).toFilePath()}',
  );
  if (rewritten != contents) pubspec.writeAsStringSync(rewritten);
}

void _injectPermissions(File manifest, Set<String> permissions) {
  var contents = manifest.readAsStringSync();
  final insertAt = contents.indexOf('>');
  if (insertAt < 0 || !contents.substring(0, insertAt).contains('<manifest')) {
    throw const FormatException('invalid player AndroidManifest.xml');
  }
  final additions = StringBuffer();
  for (final permission in permissions.toList()..sort()) {
    if (contents.contains('android:name="$permission"')) continue;
    additions.write('\n    <uses-permission android:name="$permission"/>');
  }
  contents = contents.replaceRange(
    insertAt + 1,
    insertAt + 1,
    additions.toString(),
  );
  manifest.writeAsStringSync(contents);
}

Future<void> _copyTemplate(Directory source, Directory destination) async {
  const excluded = {'.dart_tool', '.gradle', '.idea', 'build'};
  await for (final entity in source.list(recursive: false)) {
    final name = entity.uri.pathSegments.where((part) => part.isNotEmpty).last;
    if (excluded.contains(name)) continue;
    final target = '${destination.path}/$name';
    if (entity is Directory) {
      final child = Directory(target)..createSync(recursive: true);
      await _copyTemplate(entity, child);
    } else if (entity is File) {
      await entity.copy(target);
    }
  }
}

Future<void> _runChecked(
  String executable,
  List<String> arguments,
  String workingDirectory,
) async {
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    mode: ProcessStartMode.inheritStdio,
  );
  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    throw ProcessException(executable, arguments, 'command failed', exitCode);
  }
}

String _fnv1a64(String value) {
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(value)) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
