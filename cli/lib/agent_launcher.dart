import 'dart:io';

/// Where the launcher goes: the one folder every shell searches, including
/// an SSH command and an agent's tool shell, which read no shell config and
/// get only `/usr/local/bin:/usr/bin:/bin`.
const launcherPath = '/usr/local/bin/rhr';

/// The `rhr` that `dart pub global activate` installed, or null when this
/// process runs from somewhere else (a source checkout).
String? installedRhr() {
  final home = Platform.environment['HOME'];
  final cache =
      Platform.environment['PUB_CACHE'] ??
      (home == null ? null : '$home/.pub-cache');
  if (cache == null) return null;
  final rhr = File('$cache/bin/rhr');
  return rhr.existsSync() ? rhr.path : null;
}

/// The folders `dart`, `flutter` and `adb` resolve to on this PATH. Left as
/// found, not resolved through links: `~/fvm/default/bin` should follow fvm
/// when its default changes. adb is optional; it enables the USB asset path.
List<String> toolFolders() {
  final path = (Platform.environment['PATH'] ?? '').split(':');
  final folders = <String>[];
  for (final tool in const ['dart', 'flutter', 'adb']) {
    for (final folder in path) {
      if (folder.isEmpty) continue;
      if (File('$folder/$tool').existsSync()) {
        if (!folders.contains(folder)) folders.add(folder);
        break;
      }
    }
  }
  return folders;
}

/// The launcher script: this terminal's tools, then the installed `rhr`.
/// JAVA_HOME and ANDROID_HOME apply only when the caller did not set them.
String launcherScript({
  required String rhr,
  required List<String> folders,
  String? javaHome,
  String? androidHome,
}) {
  String quoted(String value) => "'${value.replaceAll("'", r"'\''")}'";
  return [
    '#!/bin/sh',
    '# Written by `rhr setup`. It lets any shell run rhr, including SSH',
    '# commands and agent tools that read no shell config. Run `rhr setup`',
    '# again after moving Flutter, Java or the Android SDK.',
    if (folders.isNotEmpty) 'PATH=${quoted(folders.join(':'))}:"\$PATH"',
    'export PATH',
    if (javaHome != null)
      '[ -n "\$JAVA_HOME" ] || JAVA_HOME=${quoted(javaHome)}; export JAVA_HOME',
    if (androidHome != null)
      '[ -n "\$ANDROID_HOME" ] || ANDROID_HOME=${quoted(androidHome)}; '
          'export ANDROID_HOME',
    'exec ${quoted(rhr)} "\$@"',
    '',
  ].join('\n');
}

/// Whether `rhr` runs from a bare shell: the system PATH and no shell
/// config, which is what an SSH command or an agent's tool gets. They still
/// have HOME and USER, which pub needs to find its cache.
Future<bool> rhrOnBarePath() async {
  if (Platform.isWindows) return true;
  final env = Platform.environment;
  try {
    final result = await Process.run('/usr/bin/env', [
      '-i',
      'PATH=/usr/local/bin:/usr/bin:/bin',
      for (final name in const ['HOME', 'USER', 'PUB_CACHE'])
        if (env[name] != null) '$name=${env[name]}',
      'sh',
      '-c',
      'rhr --version',
    ], includeParentEnvironment: false);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// Writes the launcher to [launcherPath], asking for sudo when this terminal
/// can answer. Returns a message for the developer.
Future<({bool ok, String message})> installLauncher() async {
  if (Platform.isWindows) {
    return (ok: true, message: 'no launcher needed on Windows');
  }
  final rhr = installedRhr();
  if (rhr == null) {
    return (
      ok: false,
      message:
          'rhr is not installed with `dart pub global activate`, so there is '
          'no installed rhr for the launcher to run.',
    );
  }
  final env = Platform.environment;
  final script = launcherScript(
    rhr: rhr,
    folders: toolFolders(),
    javaHome: env['JAVA_HOME'],
    androidHome: env['ANDROID_HOME'] ?? env['ANDROID_SDK_ROOT'],
  );
  final existing = File(launcherPath);
  if (existing.existsSync() && existing.readAsStringSync() == script) {
    return (ok: true, message: '$launcherPath is up to date');
  }
  // One fixed place, so a repeated setup does not leave copies behind and
  // the command it prints stays the same.
  final staged = File(
    '${Directory.systemTemp.path}/rhr-launcher-${Platform.environment['USER'] ?? 'user'}',
  )..writeAsStringSync(script);
  // The folder can be missing on a fresh machine (Apple Silicon Macs keep
  // Homebrew elsewhere).
  final args = [
    '-c',
    'mkdir -p "\${1%/*}" && install -m 755 "\$0" "\$1"',
    staged.path,
    launcherPath,
  ];
  try {
    var installed = (await Process.run('sh', args)).exitCode == 0;
    if (!installed && stdin.hasTerminal) {
      stderr.writeln(
        '[rhr] Writing $launcherPath needs sudo; it lets any shell and agent '
        'run rhr.',
      );
      final sudo = await Process.start('sudo', [
        'sh',
        ...args,
      ], mode: ProcessStartMode.inheritStdio);
      installed = await sudo.exitCode == 0;
    }
    if (installed) {
      staged.deleteSync();
      return (ok: true, message: 'installed $launcherPath');
    }
    return (
      ok: false,
      message:
          'could not write $launcherPath. To install it: '
          'sudo install -m 755 ${staged.path} $launcherPath',
    );
  } on ProcessException catch (error) {
    return (ok: false, message: 'could not write $launcherPath: $error');
  }
}

/// Whether `claude mcp get rhr` describes `rhr mcp` started through
/// [launcherPath] for every project.
bool mcpRegistrationCurrent(String claudeMcpGet) =>
    claudeMcpGet.contains('Scope: User config') &&
    claudeMcpGet.contains('Command: $launcherPath') &&
    RegExp(r'^\s*Args: mcp\s*$', multiLine: true).hasMatch(claudeMcpGet);

/// Registers `rhr mcp` with Claude Code for every project (user scope), the
/// way `argent init` registers argent. It runs through [launcherPath], so it
/// works however Claude Code was started, and finds the session from the
/// project directory it is launched in.
Future<({bool ok, String message})> registerMcp() async {
  const add = 'claude mcp add --scope user rhr -- $launcherPath mcp';
  try {
    final current = await Process.run('claude', ['mcp', 'get', 'rhr']);
    if (current.exitCode == 0 && mcpRegistrationCurrent('${current.stdout}')) {
      return (ok: true, message: 'rhr mcp is registered with Claude Code');
    }
    // Registered differently (another scope or command): replace it.
    if (current.exitCode == 0) {
      for (final scope in const ['user', 'local', 'project']) {
        await Process.run('claude', ['mcp', 'remove', 'rhr', '-s', scope]);
      }
    }
    final added = await Process.run('claude', [
      'mcp',
      'add',
      '--scope',
      'user',
      'rhr',
      '--',
      launcherPath,
      'mcp',
    ]);
    return added.exitCode == 0
        ? (
            ok: true,
            message:
                'registered rhr mcp with Claude Code: agents can see and drive '
                'the phone of the rhr session in their project',
          )
        : (
            ok: false,
            message:
                'could not register rhr mcp with Claude Code '
                '(${'${added.stderr}'.trim()}). To add it: $add',
          );
  } on ProcessException {
    return (
      ok: true,
      message:
          'Claude Code is not installed, so rhr mcp was not registered. '
          'Another MCP client can run: $launcherPath mcp',
    );
  }
}
