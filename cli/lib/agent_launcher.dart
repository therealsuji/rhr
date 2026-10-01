import 'dart:convert';
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

/// What setup did about one MCP client.
typedef McpRegistration = ({bool ok, String message});

/// Registers `rhr mcp` with every installed MCP client the way `argent init`
/// registers argent: Claude Code, Codex and OpenCode, each for all projects.
/// It runs through [launcherPath], so it works however the client was
/// started. Each client starts it in the project directory, which is how it
/// finds that project's rhr session.
Future<List<McpRegistration>> registerMcp() async => [
  await _registerClaude(),
  await _registerCodex(),
  await _registerOpenCode(),
];

/// Whether `claude mcp get rhr` describes `rhr mcp` started through
/// [launcherPath] for every project.
bool mcpRegistrationCurrent(String claudeMcpGet) =>
    claudeMcpGet.contains('Scope: User config') &&
    claudeMcpGet.contains('Command: $launcherPath') &&
    RegExp(r'^\s*Args: mcp\s*$', multiLine: true).hasMatch(claudeMcpGet);

Future<McpRegistration> _registerClaude() async {
  const add = 'claude mcp add --scope user rhr -- $launcherPath mcp';
  try {
    final current = await Process.run('claude', ['mcp', 'get', 'rhr']);
    if (current.exitCode == 0 && mcpRegistrationCurrent('${current.stdout}')) {
      return (ok: true, message: 'Claude Code: rhr mcp is registered');
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
        ? (ok: true, message: 'Claude Code: registered rhr mcp')
        : (
            ok: false,
            message:
                'Claude Code: could not register rhr mcp '
                '(${'${added.stderr}'.trim()}). To add it: $add',
          );
  } on ProcessException {
    return (ok: true, message: 'Claude Code is not installed; skipped');
  }
}

/// Whether `codex mcp get rhr --json` describes `rhr mcp` started through
/// [launcherPath].
bool codexRegistrationCurrent(String codexMcpGetJson) {
  try {
    final transport = (jsonDecode(codexMcpGetJson) as Map)['transport'];
    return transport is Map &&
        transport['command'] == launcherPath &&
        '${transport['args']}' == '[mcp]';
  } on FormatException {
    return false;
  }
}

Future<McpRegistration> _registerCodex() async {
  const add = 'codex mcp add rhr -- $launcherPath mcp';
  try {
    final current = await Process.run('codex', ['mcp', 'get', 'rhr', '--json']);
    if (current.exitCode == 0) {
      if (codexRegistrationCurrent('${current.stdout}')) {
        return (ok: true, message: 'Codex: rhr mcp is registered');
      }
      await Process.run('codex', ['mcp', 'remove', 'rhr']);
    }
    final added = await Process.run('codex', [
      'mcp',
      'add',
      'rhr',
      '--',
      launcherPath,
      'mcp',
    ]);
    return added.exitCode == 0
        ? (ok: true, message: 'Codex: registered rhr mcp')
        : (
            ok: false,
            message:
                'Codex: could not register rhr mcp '
                '(${'${added.stderr}'.trim()}). To add it: $add',
          );
  } on ProcessException {
    return (ok: true, message: 'Codex is not installed; skipped');
  }
}

/// OpenCode's entry for `rhr mcp`.
const _openCodeEntry = {
  'type': 'local',
  'command': [launcherPath, 'mcp'],
  'enabled': true,
};

/// [config] (OpenCode's opencode.json) with `rhr mcp` registered, or null
/// when it already is. Everything else in the file is kept, in order, and
/// written back with the indent the file already uses.
String? withOpenCodeRhr(String config) {
  final decoded = config.trim().isEmpty
      ? <String, dynamic>{}
      : jsonDecode(config);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('opencode.json is not a JSON object');
  }
  final mcp = decoded['mcp'];
  if (mcp != null && mcp is! Map<String, dynamic>) {
    throw const FormatException(
      'opencode.json has an "mcp" that is not an object',
    );
  }
  if (jsonEncode(mcp?['rhr']) == jsonEncode(_openCodeEntry)) return null;
  decoded['mcp'] = {...?mcp, 'rhr': _openCodeEntry};
  final indent =
      RegExp(r'^([ \t]+)"', multiLine: true).firstMatch(config)?.group(1) ??
      '  ';
  return '${JsonEncoder.withIndent(indent).convert(decoded)}\n';
}

Future<McpRegistration> _registerOpenCode() async {
  final env = Platform.environment;
  final configHome = env['XDG_CONFIG_HOME'] ?? '${env['HOME']}/.config';
  final directory = Directory('$configHome/opencode');
  final file = File('${directory.path}/opencode.json');
  const entry =
      '"mcp": {"rhr": {"type": "local", "command": ["$launcherPath", "mcp"], '
      '"enabled": true}}';
  final installed = await () async {
    try {
      return (await Process.run('opencode', ['--version'])).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }();
  if (!installed && !directory.existsSync()) {
    return (ok: true, message: 'OpenCode is not installed; skipped');
  }
  // A .jsonc file has comments that a JSON rewrite would drop.
  if (!file.existsSync() &&
      File('${directory.path}/opencode.jsonc').existsSync()) {
    return (
      ok: false,
      message:
          'OpenCode: add rhr mcp to ${directory.path}/opencode.jsonc '
          'yourself: $entry',
    );
  }
  try {
    final updated = withOpenCodeRhr(
      file.existsSync() ? file.readAsStringSync() : '',
    );
    if (updated == null) {
      return (ok: true, message: 'OpenCode: rhr mcp is registered');
    }
    directory.createSync(recursive: true);
    final staged = File('${file.path}.rhr')..writeAsStringSync(updated);
    staged.renameSync(file.path);
    return (ok: true, message: 'OpenCode: registered rhr mcp');
  } on FormatException catch (error) {
    return (
      ok: false,
      message: 'OpenCode: ${file.path} could not be read ($error). Add: $entry',
    );
  }
}
