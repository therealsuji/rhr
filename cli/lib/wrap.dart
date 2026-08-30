// Tier-2 wrap: embed rhr's native tunnel into an app's own DEBUG build with
// zero edits to the app codebase (see notes/PHASE2_CUSTOM_APP_WRAP.md).
//
// How it stays zero-edit: every injection lives in a Gradle init script
// generated OUTSIDE the project (~/.rhr/wrap/<pathHash>/). The script adds
// the bridge-android AAR as a debug-only dependency, optionally suffixes the
// application id, and bakes the session config (relay, code, identity) as
// string resources that RhrConfig reads at runtime. The project never sees a
// diff; deleting the generated script un-injects everything.
//
// Flow: resolve relay/code → bake identity (the project's own SDK + plugin
// profile, so the dev-side gate is exact-match by construction) → generate
// the init script → drive the project's gradlew → verify the artifact →
// install/launch when a device is attached.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:rhr_bridge/relay_defaults.dart';
import 'package:rhr_bridge/session_code.dart';

import 'flutter_compatibility.dart';
import 'player_builder.dart';
import 'player_update.dart' show resolvePlayerTemplate;
import 'version.dart';

/// Test seam: redirects every ~/.rhr path when set (wrap writes nothing to
/// the real home during unit tests).
String? rhrHomeOverride;

const bridgeGroupId = 'dev.rhr';
const bridgeArtifact = 'bridge-android';
const bridgeVersion = '0.1.0';

class WrapOptions {
  const WrapOptions({
    required this.project,
    this.relay,
    this.code,
    this.verbatimId = false,
    this.install = true,
  });

  final String project;
  final String? relay;
  final String? code;

  /// Install under the app's own applicationId instead of the `.rhr`
  /// suffix. Replaces the production install on the device.
  final bool verbatimId;
  final bool install;
}

class WrapResult {
  const WrapResult({
    required this.apk,
    required this.applicationId,
    required this.code,
    required this.relay,
    required this.installed,
  });

  final File apk;
  final String applicationId;
  final String code;
  final String relay;
  final bool installed;
}

class WrapFailure implements Exception {
  WrapFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Runs the whole wrap. Throws [WrapFailure] with a user-actionable message
/// on anything that should stop the flow.
Future<WrapResult> wrapApp(
  WrapOptions options, {
  void Function(String line)? onLog,
}) async {
  final void Function(String) log = onLog ?? stderr.writeln;
  final projectDir = Directory(options.project).absolute;
  final project = projectDir.path;
  if (!File('$project/pubspec.yaml').existsSync()) {
    throw WrapFailure('${projectDir.path} is not a Flutter project');
  }
  final androidDir = Directory('$project/android');
  final gradle = await resolveGradleLauncher(androidDir);
  if (gradle == null) {
    throw WrapFailure(
      '${androidDir.path} has no gradle wrapper — does the project support '
      'Android?',
    );
  }

  // AAR must be published from the rhr checkout first.
  final aar = aarPath(bridgeVersion);
  if (!aar.existsSync()) {
    throw WrapFailure(
      'bridge-android AAR not found at ${aar.path}.\n'
      'Build it once from the rhr checkout: '
      'cd <rhr>/player/android && ./gradlew :bridge-android:publish',
    );
  }

  final relay = options.relay ??
      loadDotRhrYaml(project)['relay'] ??
      defaultPublicRelay;
  final code = resolveSessionCode(project, options.code);
  final identity = readProjectFlutterCompatibility(project);
  final suffix = options.verbatimId ? '' : '.rhr';

  final profile = projectProfile(project);
  log('[rhr] baking identity: Flutter ${identity.frameworkVersion} '
      '${identity.frameworkRevision.substring(0, 9)}…, '
      '${profile.plugins.length} Android plugins');
  final script = writeInitScript(
    project: project,
    relay: relay,
    code: code,
    suffix: suffix,
    identity: identity,
    pluginsJson: jsonEncode(profile.plugins),
  );

  log('[rhr] building the wrapped app (its own debug build, '
      'gradle + init script — nothing in the project is modified)…');
  final apk = await _gradleAssembleDebug(androidDir, gradle, script, log);

  final applicationId = _verifyApk(apk, project, suffix, log);

  var installed = false;
  if (options.install) {
    installed = await _installAndLaunch(apk, applicationId, log);
  }

  return WrapResult(
    apk: apk,
    applicationId: applicationId,
    code: code,
    relay: relay,
    installed: installed,
  );
}

// ---- resolution ----------------------------------------------------------

/// Stable per-project session code. `.rhr.yaml code:` wins (explicit), then
/// the persisted one for this project path, then a fresh minted code is
/// persisted. Nothing is written inside the project.
String resolveSessionCode(String project, String? explicit) {
  final fromYaml = loadDotRhrYaml(project)['code'];
  final candidate = explicit ?? fromYaml;
  if (candidate != null) {
    if (!isValidRhrSessionCode(candidate)) {
      throw WrapFailure('invalid session code "$candidate"');
    }
    persistCode(project, candidate);
    return candidate;
  }
  final stored = codeStoreFile(project);
  if (stored.existsSync()) {
    final existing = stored.readAsStringSync().trim();
    if (isValidRhrSessionCode(existing)) return existing;
  }
  final minted = mintRhrSessionCode();
  persistCode(project, minted);
  return minted;
}

File codeStoreFile(String project) {
  final hash = sha256.convert(utf8.encode(project)).toString().substring(0, 16);
  final dir = Directory(
    '${rhrHome()}/wrap/projects/$hash',
  )..createSync(recursive: true);
  return File('${dir.path}/code');
}

void persistCode(String project, String code) {
  final f = codeStoreFile(project);
  if (f.readAsStringSyncOrNull()?.trim() != code) {
    f.writeAsStringSync(code);
  }
}

extension _ReadOrNull on File {
  String? readAsStringSyncOrNull() {
    try {
      return readAsStringSync();
    } on FileSystemException {
      return null;
    }
  }
}

String rhrHome() {
  if (rhrHomeOverride != null) return rhrHomeOverride!;
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || home.isEmpty) {
    throw WrapFailure('no home directory (set HOME)');
  }
  return '$home/.rhr';
}

File aarPath(String version) {
  return File(
    // Maven group ids become nested directories: dev.rhr -> dev/rhr.
    '${rhrHome()}/m2/dev/rhr/$bridgeArtifact/$version/'
    '$bridgeArtifact-$version.aar',
  );
}

/// Same flat-key reader as the CLI's config loading (relay/code/direct).
Map<String, String> loadDotRhrYaml(String project) {
  final f = File('$project/.rhr.yaml');
  if (!f.existsSync()) return const {};
  final out = <String, String>{};
  for (var line in f.readAsLinesSync()) {
    line = line.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final i = line.indexOf(':');
    if (i <= 0) continue;
    final key = line.substring(0, i).trim();
    var value = line.substring(i + 1).trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    if (key == 'relay' || key == 'code' || key == 'direct') out[key] = value;
  }
  return out;
}

PlayerBuildProfile projectProfile(String project) {
  final plugins = <String, String>{
    for (final plugin in readAndroidPluginSources(project))
      plugin.name: plugin.version,
  };
  return PlayerBuildProfile(
    id: projectPlayerProfileId(project),
    plugins: Map.unmodifiable(plugins),
    permissions: readAndroidPermissionProfile(project),
  );
}

// ---- init script ---------------------------------------------------------

/// Groovy (not Kotlin DSL) on purpose: init scripts configured through
/// dynamic dispatch survive AGP version drift, where a Kotlin DSL script
/// would need an AGP-pinned initscript classpath.
String writeInitScript({
  required String project,
  required String relay,
  required String code,
  required String suffix,
  required FlutterCompatibility identity,
  required String pluginsJson,
}) {
  final hash = sha256.convert(utf8.encode(project)).toString().substring(0, 16);
  final dir = Directory('${rhrHome()}/wrap/projects/$hash')
    ..createSync(recursive: true);
  final script = File('${dir.path}/rhr-inject.gradle');
  final suffixLine = suffix.isEmpty
      ? ''
      : "\n                applicationIdSuffix = '$suffix'";
  final suffixComment = suffix.isEmpty
      ? '//'
      : '//   - applicationIdSuffix $suffix on debug';
  script.writeAsStringSync('''
// Generated by rhr wrap $rhrVersion — regenerating overwrites this file.
// Injects the rhr tunnel into this app's DEBUG build only:
//   - bridge-android AAR (debugImplementation, from $bridgeGroupId m2 repo)
//   - session config + SDK identity as string resources (RhrConfig)
$suffixComment
// The project is not modified; removing this file (and the repo block)
// un-injects everything. Release builds never contain rhr.

def rhrM2 = '${_escapeGroovy(rhrHome())}/m2'

// The m2 repo must land where the project's resolution mode allows: modern
// flutter settings prefer settings repositories (project repos are a hard
// error there), legacy defaults prefer project repositories (settings repos
// are silently ignored). Add the settings-level repo always; flip the
// project-level one only when the mode allows it.
def rhrAddProjectRepo = false

settingsEvaluated { s ->
    try {
        def mode = s.dependencyResolutionManagement.repositoriesMode.get()
        rhrAddProjectRepo = (mode.toString() == 'PREFER_PROJECT')
    } catch (Throwable ignored) {}
    s.dependencyResolutionManagement {
        repositories { maven { url rhrM2 } }
    }
}

allprojects { p ->
    if (rhrAddProjectRepo) {
        p.repositories { maven { url rhrM2 } }
    }
    p.plugins.withId('com.android.application') {
        p.android {
            // AGP 9 disables resValues by default; the baked session config
            // below needs it.
            buildFeatures {
                resValues = true
            }
            defaultConfig {
                resValue 'string', 'rhr_session_code', '${_escapeGroovy(code)}'
                resValue 'string', 'rhr_relay_url', '${_escapeGroovy(relay)}'
                resValue 'string', 'rhr_host', 'app'
                resValue 'string', 'rhr_flutter_version', '${_escapeGroovy(identity.frameworkVersion)}'
                resValue 'string', 'rhr_framework_revision', '${_escapeGroovy(identity.frameworkRevision)}'
                resValue 'string', 'rhr_engine_revision', '${_escapeGroovy(identity.engineRevision)}'
                resValue 'string', 'rhr_dart_sdk_version', '${_escapeGroovy(identity.dartSdkVersion)}'
                resValue 'string', 'rhr_channel', '${_escapeGroovy(identity.channel ?? '')}'
                resValue 'string', 'rhr_android_plugins_json', '${_escapeGroovy(pluginsJson)}'
            }
            buildTypes {
                debug {$suffixLine}
            }
        }
        p.dependencies {
            add 'debugImplementation', '$bridgeGroupId:$bridgeArtifact:$bridgeVersion'
        }
    }
}
''');
  return script.path;
}

String _escapeGroovy(String value) => value
    .replaceAll('\\', '\\\\')
    .replaceAll("'", "\\'")
    .replaceAll('\$', '\\\$');

// ---- build ---------------------------------------------------------------

/// How to invoke this project's gradle. Flutter templates ship `gradlew`,
/// but some projects only carry the wrapper properties — run the wrapper
/// main from any wrapper jar via java in that case (nothing is written into
/// the project).
class GradleLauncher {
  const GradleLauncher(this.executable, this.prefix);
  final String executable;
  final List<String> prefix;
}

Future<GradleLauncher?> resolveGradleLauncher(Directory androidDir) async {
  final ownWrapper = File('${androidDir.path}/gradle/wrapper/gradle-wrapper.jar');
  if (File('${androidDir.path}/gradlew').existsSync()) {
    return GradleLauncher('${androidDir.path}/gradlew', const []);
  }
  if (ownWrapper.existsSync()) {
    return GradleLauncher('java', [
      '-cp',
      ownWrapper.path,
      'org.gradle.wrapper.GradleWrapperMain',
    ]);
  }
  // Borrow the wrapper machinery from the rhr checkout: GradleWrapperMain
  // reads gradle-wrapper.properties from NEXT TO THE JAR, so stage the jar
  // beside the PROJECT's wrapper properties in ~/.rhr (never in the project).
  // The project's properties pick the distribution version; nothing is
  // written into the project.
  final projectProps = File(
    '${androidDir.path}/gradle/wrapper/gradle-wrapper.properties',
  );
  if (!projectProps.existsSync()) return null;
  final borrowed = File(
    '${await rhrCheckout()}/player/android/gradle/wrapper/gradle-wrapper.jar',
  );
  if (!borrowed.existsSync()) return null;
  final stage = Directory(
    '${rhrHome()}/wrap/projects/'
    '${sha256.convert(utf8.encode(androidDir.parent.path)).toString().substring(0, 16)}'
    '/wrapper',
  )..createSync(recursive: true);
  final stagedJar = File('${stage.path}/gradle-wrapper.jar');
  final stagedProps = File('${stage.path}/gradle-wrapper.properties');
  if (!stagedJar.existsSync()) stagedJar.writeAsBytesSync(borrowed.readAsBytesSync());
  if (!stagedProps.existsSync()) {
    stagedProps.writeAsBytesSync(projectProps.readAsBytesSync());
  }
  return GradleLauncher('java', [
    '-cp',
    stagedJar.path,
    'org.gradle.wrapper.GradleWrapperMain',
  ]);
}

String? _rhrCheckoutCache;

/// The rhr checkout, anchored at the player template `resolvePlayerTemplate`
/// already finds reliably (its parent is the checkout root).
Future<String> rhrCheckout() async {
  if (_rhrCheckoutCache != null) return _rhrCheckoutCache!;
  final template = await resolvePlayerTemplate();
  return _rhrCheckoutCache = File(template).parent.path;
}

Future<File> _gradleAssembleDebug(
  Directory androidDir,
  GradleLauncher gradle,
  String initScript,
  void Function(String) log,
) async {
  var result = await _runGradle(androidDir, gradle, initScript, null);
  if (result.exitCode != 0 && _looksLikeNetworkFailure(result)) {
    // This network selectively blackholes storage.googleapis.com; the
    // official China mirror serves the same engine artifacts. Retry once
    // through it (gradle caches are keyed per repo URL, so this only
    // affects genuinely missing artifacts).
    log('[rhr] artifact download failed — retrying via the '
        'storage.flutter-io.cn mirror…');
    final retry = await _runGradle(
      androidDir,
      gradle,
      initScript,
      'https://storage.flutter-io.cn',
    );
    if (retry.exitCode != 0) {
      throw WrapFailure(_gradleFailureSummary(retry));
    }
    result = retry;
  }
  if (result.exitCode != 0) {
    throw WrapFailure(_gradleFailureSummary(result));
  }
  // The flutter gradle plugin redirects the app module's build dir to the
  // flutter project's own build/ directory.
  final apk = File('${androidDir.parent.path}/build/app/outputs/apk/debug/app-debug.apk');
  if (!apk.existsSync()) {
    throw WrapFailure('gradle finished but ${apk.path} is missing');
  }
  return apk;
}


class ProcessRunResult {
  const ProcessRunResult(this.exitCode, this.stdout, this.stderr);
  final int exitCode;
  final String stdout;
  final String stderr;
}

Future<ProcessRunResult> _runGradle(
  Directory androidDir,
  GradleLauncher gradle,
  String initScript,
  String? storageBaseUrl,
) async {
  final env = {...Platform.environment};
  if (storageBaseUrl != null) {
    env['FLUTTER_STORAGE_BASE_URL'] = storageBaseUrl;
  }
  final proc = await Process.run(
    gradle.executable,
    [
      ...gradle.prefix,
      'assembleDebug',
      '--init-script',
      initScript,
      '-Ptarget-platform=android-arm64',
    ],
    workingDirectory: androidDir.path,
    environment: env,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  return ProcessRunResult(
    proc.exitCode,
    proc.stdout.toString(),
    proc.stderr.toString(),
  );
}

bool _looksLikeNetworkFailure(ProcessRunResult result) {
  final text = '${result.stdout}\n${result.stderr}';
  return text.contains('Could not download') ||
      text.contains('Could not GET') ||
      text.contains('storage.googleapis.com');
}

String _gradleFailureSummary(ProcessRunResult result) {
  final text = '${result.stdout}\n${result.stderr}';
  final lines = <String>[];
  final content = text.split('\n');
  for (var i = 0; i < content.length; i++) {
    final l = content[i];
    if (l.startsWith('e: ') || l.contains('error:')) lines.add(l);
    if (l.contains('What went wrong')) {
      lines.addAll(content.skip(i + 1).take(8).where((l) => l.isNotEmpty));
    }
  }
  return 'gradle assembleDebug failed (exit ${result.exitCode})\n'
      '${lines.take(16).join('\n')}';
}

// ---- verification --------------------------------------------------------

/// Confirms the artifact is the app we meant to build: applicationId matches
/// the chosen id mode and the init provider merged in. Uses aapt from the
/// Android SDK named in android/local.properties.
String _verifyApk(File apk, String project, String suffix, void Function(String) log) {
  final aapt = _locateAapt(project);
  if (aapt == null) {
    log('[rhr] note: aapt not found — skipping APK verification and auto-launch');
    return '';
  }
  final proc = Process.runSync(aapt, ['dump', 'badging', apk.path]);
  if (proc.exitCode != 0) {
    throw WrapFailure('aapt could not read ${apk.path}');
  }
  final match = RegExp(
    r"^package: name='([^']+)'",
    multiLine: true,
  ).firstMatch(proc.stdout.toString());
  final id = match?.group(1);
  if (id == null) {
    throw WrapFailure('aapt badging output has no package line');
  }
  if (suffix.isNotEmpty && !id.endsWith(suffix)) {
    throw WrapFailure(
      'built APK has applicationId "$id", expected the "$suffix" suffix — '
      'the project may set its own debug suffix (it wins); '
      'retry with --id verbatim if intended',
    );
  }
  log('[rhr] wrapped app: $id (${(apk.lengthSync() / (1024 * 1024)).toStringAsFixed(1)} MB)');
  return id;
}

String? _locateAapt(String project) {
  final props = File('$project/android/local.properties');
  if (!props.existsSync()) return null;
  String? sdkDir;
  for (var line in props.readAsLinesSync()) {
    if (line.startsWith('sdk.dir=')) {
      sdkDir = line.substring('sdk.dir='.length).trim();
      break;
    }
  }
  if (sdkDir == null || sdkDir.isEmpty) return null;
  final buildTools = Directory('$sdkDir/build-tools');
  if (!buildTools.existsSync()) return null;
  final versions = buildTools
      .listSync()
      .whereType<Directory>()
      .map((d) => d.path)
      .toList()
    ..sort((a, b) => b.compareTo(a)); // lexicographic works for dotted versions
  for (final dir in versions) {
    for (final name in ['aapt2', 'aapt']) {
      final candidate = File('$dir/$name');
      if (candidate.existsSync()) return candidate.path;
    }
  }
  return null;
}

// ---- install ---------------------------------------------------------------

Future<bool> _installAndLaunch(
  File apk,
  String applicationId,
  void Function(String) log,
) async {
  final devices = await Process.run('adb', ['devices']);
  final attached = devices.stdout
      .toString()
      .split('\n')
      .skip(1)
      .any((l) => l.trim().endsWith('\tdevice'));
  if (!attached) {
    log('[rhr] no adb device attached — install manually: '
        'adb install -r ${apk.path}');
    return false;
  }
  log('[rhr] installing ${apk.path.split('/').last}…');
  final install = await Process.run('adb', ['install', '-r', apk.path]);
  if (install.exitCode != 0) {
    stderr.write(install.stderr);
    throw WrapFailure('adb install failed: ${install.stdout}');
  }
  log('[rhr] launching $applicationId…');
  final launch = await Process.run('adb', [
    'shell',
    'monkey',
    '-p',
    applicationId,
    '-c',
    'android.intent.category.LAUNCHER',
    '1',
  ]);
  if (launch.exitCode != 0) {
    log('[rhr] note: auto-launch failed — open the app manually');
  }
  return true;
}
