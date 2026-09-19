import 'dart:convert';
import 'dart:io';

final class FlutterCompatibility {
  const FlutterCompatibility({
    required this.frameworkVersion,
    required this.frameworkRevision,
    required this.engineRevision,
    required this.dartSdkVersion,
    this.channel,
  });

  factory FlutterCompatibility.fromJson(Map<String, dynamic> json) {
    String field(String name) {
      final value = json[name];
      if (value is! String || value.isEmpty) {
        throw FormatException('missing Flutter compatibility field "$name"');
      }
      return value;
    }

    final channel = json['channel'];
    return FlutterCompatibility(
      frameworkVersion: field('frameworkVersion'),
      frameworkRevision: field('frameworkRevision'),
      engineRevision: field('engineRevision'),
      dartSdkVersion: field('dartSdkVersion'),
      // Players predating channel reporting stay on the conservative
      // exact-identity gate below rather than failing to parse.
      channel: channel is String && channel.isNotEmpty ? channel : null,
    );
  }

  final String frameworkVersion;
  final String frameworkRevision;
  final String engineRevision;
  final String dartSdkVersion;

  /// Release channel ("stable", "beta", …) or null when unreported.
  final String? channel;

  /// Patch-level skew inside one stable series is supported: the kernel
  /// format and VM service protocol only move across minors, and Flutter's
  /// release branches routinely re-pin Dart patches mid-series (the release
  /// manifest shows e.g. 3.44.0 pins Dart 3.12.0 while 3.44.2 pins 3.12.2).
  /// Pairs we cannot prove are tagged stable builds of the same series —
  /// missing channels, beta/main, forks, cross-minor — fall back to exact
  /// identity matching.
  CompatibilityReport differencesFrom(FlutterCompatibility player) {
    if (_sameStableSeries(player)) {
      final skewed =
          frameworkVersion != player.frameworkVersion ||
          dartSdkVersion != player.dartSdkVersion ||
          frameworkRevision != player.frameworkRevision ||
          engineRevision != player.engineRevision;
      final warnings = <String>[
        if (skewed)
          'version skew: local Flutter $frameworkVersion '
              '(Dart $dartSdkVersion), player Flutter '
              '${player.frameworkVersion} (Dart ${player.dartSdkVersion}) — '
              'same stable series, supported',
      ];
      return CompatibilityReport(const [], warnings);
    }

    final blockers = <String>[];
    void compare(String label, String local, String installed) {
      if (local != installed) {
        blockers.add('$label: local $local, player $installed');
      }
    }

    compare('Flutter version', frameworkVersion, player.frameworkVersion);
    compare('Flutter revision', frameworkRevision, player.frameworkRevision);
    compare('engine revision', engineRevision, player.engineRevision);
    compare('Dart SDK', dartSdkVersion, player.dartSdkVersion);
    return CompatibilityReport(List.unmodifiable(blockers), const []);
  }

  bool _sameStableSeries(FlutterCompatibility player) {
    if (channel != 'stable' || player.channel != 'stable') return false;
    return _isSameMinor(frameworkVersion, player.frameworkVersion) &&
        _isSameMinor(dartSdkVersion, player.dartSdkVersion);
  }
}

/// Blockers stop the session; warnings are printed but allowed through.
final class CompatibilityReport {
  const CompatibilityReport(this.blockers, this.warnings);

  final List<String> blockers;
  final List<String> warnings;

  bool get isCompatible => blockers.isEmpty;
}

bool _isSameMinor(String a, String b) {
  final left = _sdkVersionParts(a);
  final right = _sdkVersionParts(b);
  if (left == null || right == null) return a == b;
  return left.$1 == right.$1 && left.$2 == right.$2;
}

/// Leading numeric semver of an SDK version string; tolerates suffixes like
/// "3.10.0 (build 3.10.0-290.4.beta)" and two-part "3.9" forms.
(int, int, int)? _sdkVersionParts(String version) {
  final match = RegExp(
    r'^v?(\d+)\.(\d+)(?:\.(\d+))?',
  ).firstMatch(version.trim());
  if (match == null) return null;
  return (
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3) ?? '0'),
  );
}

/// The compatibility inputs captured from one Flutter project. Both CLI
/// entrypoints use this same snapshot so their gates cannot drift apart.
final class ProjectCompatibilityProfile {
  const ProjectCompatibilityProfile({
    required this.flutter,
    required this.androidPlugins,
    required this.androidPermissions,
    required this.unsupportedAndroidInputs,
  });

  final FlutterCompatibility flutter;
  final Map<String, String> androidPlugins;
  final Set<String> androidPermissions;
  final List<String> unsupportedAndroidInputs;

  CompatibilityReport differencesFrom(Map<String, dynamic> player) {
    final report = flutter.differencesFrom(
      FlutterCompatibility.fromJson(player),
    );
    final blockers = [...report.blockers];
    blockers.addAll(
      androidPluginDifferences(
        required: androidPlugins,
        available: parseAndroidPluginProfile(player['androidPlugins']),
      ),
    );
    blockers.addAll(
      androidPermissionDifferences(
        required: androidPermissions,
        available: parseAndroidPermissionProfile(player['androidPermissions']),
      ),
    );
    blockers.addAll(unsupportedAndroidInputs);
    return CompatibilityReport(
      List.unmodifiable(blockers),
      report.warnings,
    );
  }
}

ProjectCompatibilityProfile readProjectCompatibilityProfile(String project) {
  return ProjectCompatibilityProfile(
    flutter: readProjectFlutterCompatibility(project),
    androidPlugins: readAndroidPluginProfile(project),
    androidPermissions: readAndroidPermissionProfile(project),
    unsupportedAndroidInputs: readUnsupportedAndroidInputs(project),
  );
}

/// The Flutter SDK root a project is pinned to via fvm, or null when the
/// project has no pin. The `.fvm/flutter_sdk` symlink (created by `fvm use`)
/// is authoritative; a bare `.fvmrc` falls back to fvm's version cache.
String? projectPinnedFlutterSdk(String project) {
  final link = Link('$project/.fvm/flutter_sdk');
  if (link.existsSync()) {
    try {
      return link.resolveSymbolicLinksSync();
    } on FileSystemException {
      // Dangling symlink (SDK removed): fall through to .fvmrc.
    }
  }
  final fvmrc = File('$project/.fvmrc');
  if (!fvmrc.existsSync()) return null;
  try {
    final decoded = jsonDecode(fvmrc.readAsStringSync());
    final version = decoded is Map<String, dynamic> ? decoded['flutter'] : null;
    if (version is! String || version.isEmpty) return null;
    final home = Platform.environment['HOME'] ?? '';
    for (final root in [
      Platform.environment['FVM_CACHE_PATH'],
      '$home/fvm/versions',
      '$home/.fvm/versions',
    ]) {
      if (root == null) continue;
      final sdk = Directory('$root/$version');
      if (sdk.existsSync()) return sdk.path;
    }
  } on FormatException {
    // Malformed .fvmrc: behave as unpinned.
  }
  return null;
}

/// The `flutter` command that matches [readProjectFlutterCompatibility] for
/// this project: the fvm-pinned SDK's binary when there is a pin, otherwise
/// whatever `flutter` resolves to on PATH.
String projectFlutterExecutable(String project) {
  final sdk = projectPinnedFlutterSdk(project);
  return sdk == null ? 'flutter' : '$sdk/bin/flutter';
}

/// The Flutter identity streaming into this project's player must match: the
/// project's fvm-pinned SDK when present, else the SDK that launched the CLI.
/// Keying off the pin matters — `flutter attach` and the kernel compiler run
/// with the project's SDK, not the CLI's.
FlutterCompatibility readProjectFlutterCompatibility(String project) {
  final sdk = projectPinnedFlutterSdk(project);
  if (sdk == null) return readLocalFlutterCompatibility();
  final versionFile = File('$sdk/bin/cache/flutter.version.json');
  if (!versionFile.existsSync()) {
    throw StateError(
      'the fvm-pinned Flutter SDK at $sdk has no bin/cache/'
      'flutter.version.json — run a flutter command with it once',
    );
  }
  final json = jsonDecode(versionFile.readAsStringSync());
  if (json is! Map<String, dynamic>) {
    throw const FormatException('invalid Flutter version metadata');
  }
  return FlutterCompatibility.fromJson(json);
}

final class AndroidPluginSource {
  const AndroidPluginSource({
    required this.name,
    required this.version,
    required this.path,
  });

  final String name;
  final String version;
  final String path;
}

List<AndroidPluginSource> readAndroidPluginSources(String project) {
  final metadata = File('$project/.flutter-plugins-dependencies');
  final candidates = <({String name, String path})>[];
  if (metadata.existsSync()) {
    final decoded = jsonDecode(metadata.readAsStringSync());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('invalid .flutter-plugins-dependencies');
    }
    final plugins = decoded['plugins'];
    final android = plugins is Map<String, dynamic> ? plugins['android'] : null;
    if (android is List) {
      for (final entry in android) {
        if (entry is! Map<String, dynamic>) continue;
        final name = entry['name'];
        final path = entry['path'];
        if (name is String && path is String) {
          candidates.add((name: name, path: Directory(path).absolute.path));
        }
      }
    }
  } else {
    final packageConfig = File('$project/.dart_tool/package_config.json');
    if (!packageConfig.existsSync()) return const [];
    final decoded = jsonDecode(packageConfig.readAsStringSync());
    final packages = decoded is Map<String, dynamic>
        ? decoded['packages']
        : null;
    if (packages is List) {
      for (final entry in packages) {
        if (entry is! Map<String, dynamic>) continue;
        final name = entry['name'];
        final rootUri = entry['rootUri'];
        if (name is! String || rootUri is! String) continue;
        final root = packageConfig.uri.resolve(rootUri);
        if (root.scheme != 'file') continue;
        final path = Directory.fromUri(root).absolute.path;
        final pubspec = File('$path/pubspec.yaml');
        if (pubspec.existsSync() && _supportsAndroidPlugin(pubspec)) {
          candidates.add((name: name, path: path));
        }
      }
    }
  }

  final sources = <AndroidPluginSource>[];
  for (final candidate in candidates) {
    final pubspec = File('${candidate.path}/pubspec.yaml');
    if (!pubspec.existsSync()) {
      throw StateError(
        'plugin ${candidate.name} has no pubspec at ${pubspec.path}',
      );
    }
    final versionMatch = RegExp(
      r'^version:\s*([^\s#]+)',
      multiLine: true,
    ).firstMatch(pubspec.readAsStringSync());
    if (versionMatch == null) {
      throw FormatException(
        'plugin ${candidate.name} has no version in ${pubspec.path}',
      );
    }
    sources.add(
      AndroidPluginSource(
        name: candidate.name,
        version: versionMatch.group(1)!,
        path: candidate.path,
      ),
    );
  }
  sources.sort((a, b) => a.name.compareTo(b.name));
  return List.unmodifiable(sources);
}

bool _supportsAndroidPlugin(File pubspec) {
  final contents = pubspec.readAsStringSync();
  final flutter = RegExp(
    r'^flutter:\s*$',
    multiLine: true,
  ).firstMatch(contents);
  if (flutter == null) return false;
  final tail = contents.substring(flutter.end);
  final nextTopLevel = RegExp(r'^\S', multiLine: true).firstMatch(tail);
  final section = nextTopLevel == null
      ? tail
      : tail.substring(0, nextTopLevel.start);
  return RegExp(r'^\s+plugin:\s*$', multiLine: true).hasMatch(section) &&
      RegExp(r'^\s+android:', multiLine: true).hasMatch(section);
}

Map<String, String> readAndroidPluginProfile(String project) {
  final profile = {
    for (final source in readAndroidPluginSources(project))
      source.name: source.version,
  };
  return Map.unmodifiable(
    Map.fromEntries(
      profile.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    ),
  );
}

Set<String> readAndroidPermissionProfile(String project) {
  final manifests = <File>[
    File('$project/android/app/src/main/AndroidManifest.xml'),
    File('$project/android/app/src/debug/AndroidManifest.xml'),
  ];

  for (final plugin in readAndroidPluginSources(project)) {
    manifests.add(File('${plugin.path}/android/src/main/AndroidManifest.xml'));
  }

  final permissions = <String>{};
  final permissionPattern = RegExp(
    r'<uses-permission(?:-sdk-\d+)?\b[^>]*\bandroid:name\s*=\s*["\x27]([^"\x27]+)["\x27]',
    caseSensitive: false,
  );
  for (final manifest in manifests) {
    if (!manifest.existsSync()) continue;
    for (final match in permissionPattern.allMatches(
      manifest.readAsStringSync(),
    )) {
      permissions.add(match.group(1)!);
    }
  }
  return Set.unmodifiable(permissions.toList()..sort());
}

Set<String> parseAndroidPermissionProfile(Object? json) {
  if (json is! List) {
    throw const FormatException('player did not report Android permissions');
  }
  final permissions = <String>{};
  for (final permission in json) {
    if (permission is! String || permission.isEmpty) {
      throw const FormatException(
        'invalid Android permission in player profile',
      );
    }
    permissions.add(permission);
  }
  return Set.unmodifiable(permissions);
}

List<String> androidPermissionDifferences({
  required Set<String> required,
  required Set<String> available,
}) {
  final missing =
      required
          .difference(available)
          .map((permission) => '$permission: required, missing from player')
          .toList()
        ..sort();
  // WRITE_EXTERNAL_STORAGE is a maxSdkVersion=28 legacy permission: modern
  // Androids filter it out of the player's requestedPermissions list entirely,
  // and on API 29+ it is functionally inert anyway. A project that "requires"
  // it still runs fine on the player, so never block on it.
  missing.removeWhere(
    (line) => line.startsWith('android.permission.WRITE_EXTERNAL_STORAGE:'),
  );
  return missing;
}

List<String> readUnsupportedAndroidInputs(String project) {
  final androidApp = Directory('$project/android/app');
  if (!androidApp.existsSync()) return const [];
  final unsupported = <String>[];

  final sourceRoot = Directory('${androidApp.path}/src');
  if (sourceRoot.existsSync()) {
    const nativeExtensions = {
      '.java',
      '.kt',
      '.kts',
      '.c',
      '.cc',
      '.cpp',
      '.h',
      '.hpp',
      '.so',
    };
    for (final file in sourceRoot.listSync(recursive: true).whereType<File>()) {
      final name = file.uri.pathSegments.last;
      final extension = name.contains('.')
          ? '.${name.split('.').last.toLowerCase()}'
          : '';
      if (!nativeExtensions.contains(extension)) continue;
      if (name == 'GeneratedPluginRegistrant.java' ||
          name == 'GeneratedPluginRegistrant.kt') {
        continue;
      }
      final projectRoot = Directory(project).absolute.path;
      final absolute = file.absolute.path;
      final relative = absolute.startsWith('$projectRoot/')
          ? absolute.substring(projectRoot.length + 1)
          : file.path;
      if ((name == 'MainActivity.kt' || name == 'MainActivity.java') &&
          _isTemplateMainActivity(file.readAsStringSync())) {
        continue;
      }
      unsupported.add(
        '$relative: custom Android code or native library is not in the '
        'generic player',
      );
    }
  }

  unsupported.sort();
  return List.unmodifiable(unsupported);
}

bool _isTemplateMainActivity(String source) {
  final withoutComments = source
      .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
      .replaceAll(RegExp(r'//.*'), '');
  final body = withoutComments
      .split('\n')
      .where((line) {
        final trimmed = line.trim();
        return trimmed.isNotEmpty &&
            !trimmed.startsWith('package ') &&
            !trimmed.startsWith('import ');
      })
      .join()
      .replaceAll(RegExp(r'\s+'), '');
  return body == 'classMainActivity:FlutterActivity()' ||
      body == 'publicclassMainActivityextendsFlutterActivity{}' ||
      body == 'classMainActivityextendsFlutterActivity{}';
}

Map<String, String> parseAndroidPluginProfile(Object? json) {
  if (json is! Map<String, dynamic>) {
    throw const FormatException('player did not report Android plugins');
  }
  return json.map((name, version) {
    if (version is! String || version.isEmpty) {
      throw FormatException('invalid version for Android plugin "$name"');
    }
    return MapEntry(name, version);
  });
}

List<String> androidPluginDifferences({
  required Map<String, String> required,
  required Map<String, String> available,
}) {
  final differences = <String>[];
  for (final entry in required.entries) {
    final installed = available[entry.key];
    if (installed == null) {
      differences.add(
        '${entry.key}: required ${entry.value}, missing from player',
      );
    } else if (!_isCompatiblePluginVersion(
      required: entry.value,
      installed: installed,
    )) {
      differences.add(
        '${entry.key}: required ${entry.value}, player has $installed',
      );
    }
  }
  return differences;
}

bool _isCompatiblePluginVersion({
  required String required,
  required String installed,
}) {
  final requiredParts = _numericVersion(required);
  final installedParts = _numericVersion(installed);
  if (requiredParts == null || installedParts == null) {
    return required == installed;
  }
  if (requiredParts.$1 == 0 || installedParts.$1 == 0) {
    return required == installed;
  }
  if (requiredParts.$1 != installedParts.$1) return false;
  return _compareVersions(installedParts, requiredParts) >= 0;
}

(int, int, int)? _numericVersion(String version) {
  final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(version);
  if (match == null) return null;
  return (
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  );
}

int _compareVersions((int, int, int) left, (int, int, int) right) {
  final major = left.$1.compareTo(right.$1);
  if (major != 0) return major;
  final minor = left.$2.compareTo(right.$2);
  if (minor != 0) return minor;
  return left.$3.compareTo(right.$3);
}

FlutterCompatibility readLocalFlutterCompatibility({
  String? dartExecutable,
  Map<String, String>? environment,
}) {
  final env = environment ?? Platform.environment;
  final candidates = <File>[];
  final flutterRoot = env['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    candidates.add(File('$flutterRoot/bin/cache/flutter.version.json'));
  }

  var directory = File(
    dartExecutable ?? Platform.resolvedExecutable,
  ).absolute.parent;
  for (var i = 0; i < 8; i++) {
    candidates.add(File('${directory.path}/bin/cache/flutter.version.json'));
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }

  final versionFile = candidates.where((file) => file.existsSync()).firstOrNull;
  if (versionFile == null) {
    throw StateError(
      'could not locate bin/cache/flutter.version.json for '
      '${dartExecutable ?? Platform.resolvedExecutable}',
    );
  }
  final json = jsonDecode(versionFile.readAsStringSync());
  if (json is! Map<String, dynamic>) {
    throw const FormatException('invalid Flutter version metadata');
  }
  return FlutterCompatibility.fromJson(json);
}
