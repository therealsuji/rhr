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

/// The folders `dart`, `flutter`, `adb` and `java` resolve to on this
/// [environment]'s PATH. Left as found, not resolved through links:
/// `~/fvm/default/bin` should follow fvm when its default changes. adb is
/// optional; it enables the USB asset path. java is for the SDK's
/// `apksigner`, which runs `java` from PATH and ignores JAVA_HOME, so a JDK
/// set only through JAVA_HOME contributes its `bin`.
List<String> toolFolders([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  final path = (env['PATH'] ?? '').split(':');
  final folders = <String>[];
  for (final tool in const ['dart', 'flutter', 'adb', 'java']) {
    var found = false;
    for (final folder in path) {
      if (folder.isEmpty) continue;
      if (File('$folder/$tool').existsSync()) {
        if (!folders.contains(folder)) folders.add(folder);
        found = true;
        break;
      }
    }
    final javaHome = env['JAVA_HOME'];
    if (!found &&
        tool == 'java' &&
        javaHome != null &&
        File('$javaHome/bin/java').existsSync()) {
      folders.add('$javaHome/bin');
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
  final tools = 'tools from ${toolFolders().join(', ')}';
  if (existing.existsSync() && existing.readAsStringSync() == script) {
    return (ok: true, message: '$launcherPath is up to date ($tools)');
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
      return (ok: true, message: 'installed $launcherPath ($tools)');
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

/// What setup did about one MCP client. A registration that failed is a
/// warning: the rest of setup still stands, and [message] says what to do.
typedef McpRegistration = ({bool ok, String message});

/// Registers `rhr mcp` with every installed MCP client the way `argent init`
/// registers argent: Claude Code, Codex and OpenCode, each in the user's own
/// config for all projects, never in a project's checked-in config. It runs
/// through [launcherPath], so it works however the client was started. Each
/// client starts it in the project directory, which is how it finds that
/// project's rhr session.
Future<List<McpRegistration>> registerMcp() async => [
  await _registerClaude(),
  await _registerCodex(),
  await _registerOpenCode(),
];

/// Whether the client [command] runs on this machine.
Future<bool> _installed(String command) async {
  try {
    return (await Process.run(command, ['--version'])).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// Whether [entry], an MCP server entry from a client's config, starts
/// `rhr mcp` through [launcherPath].
bool _isRhrMcp(Object? entry) =>
    entry is Map &&
    entry['command'] == launcherPath &&
    '${entry['args']}' == '[mcp]';

/// Whether Claude Code's user config ([claudeJson], `~/.claude.json`)
/// already registers `rhr mcp` for every project.
bool claudeRegistrationCurrent(String claudeJson) {
  try {
    final servers = (jsonDecode(claudeJson) as Map)['mcpServers'];
    return servers is Map && _isRhrMcp(servers['rhr']);
  } on Object {
    return false;
  }
}

/// Claude Code's user config, which moves with `CLAUDE_CONFIG_DIR`.
File _claudeConfig() {
  final env = Platform.environment;
  return File('${env['CLAUDE_CONFIG_DIR'] ?? env['HOME']}/.claude.json');
}

Future<McpRegistration> _registerClaude() async {
  if (!await _installed('claude')) {
    return (ok: true, message: 'Claude Code is not installed; skipped');
  }
  const add = 'claude mcp add --scope user rhr -- $launcherPath mcp';
  final config = _claudeConfig();
  final text = config.existsSync() ? config.readAsStringSync() : '';
  if (claudeRegistrationCurrent(text)) {
    return (ok: true, message: 'Claude Code: rhr mcp is registered');
  }
  // An older user-scope entry is replaced. Local and project entries belong
  // to a project and stay as they are.
  await Process.run('claude', ['mcp', 'remove', 'rhr', '-s', 'user']);
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
      ? (ok: true, message: 'Claude Code: registered rhr mcp in ${config.path}')
      : (
          ok: false,
          message:
              'Claude Code: could not register rhr mcp '
              '(${'${added.stderr}'.trim()}). To add it: $add',
        );
}

/// Whether `codex mcp get rhr --json` describes `rhr mcp` started through
/// [launcherPath].
bool codexRegistrationCurrent(String codexMcpGetJson) {
  try {
    return _isRhrMcp((jsonDecode(codexMcpGetJson) as Map)['transport']);
  } on FormatException {
    return false;
  }
}

Future<McpRegistration> _registerCodex() async {
  if (!await _installed('codex')) {
    return (ok: true, message: 'Codex is not installed; skipped');
  }
  const add = 'codex mcp add rhr -- $launcherPath mcp';
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
      ? (ok: true, message: 'Codex: registered rhr mcp in ~/.codex/config.toml')
      : (
          ok: false,
          message:
              'Codex: could not register rhr mcp '
              '(${'${added.stderr}'.trim()}). To add it: $add',
        );
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
  if (!await _installed('opencode')) {
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
    return (ok: true, message: 'OpenCode: registered rhr mcp in ${file.path}');
  } on FormatException {
    return (
      ok: false,
      message:
          'OpenCode: ${file.path} has comments or is not plain JSON, so it was '
          'left alone. Add this yourself: $entry',
    );
  }
}

/// One `rhr doctor` line per installed MCP client: whether `rhr mcp` is
/// registered with it. Informational: rhr runs without any of them.
Future<List<String>> mcpDoctorLines() async {
  final home = Platform.environment['HOME'];
  final configHome = Platform.environment['XDG_CONFIG_HOME'] ?? '$home/.config';
  final lines = <String>[];
  String line(String client, bool current) => current
      ? '[OK] rhr mcp is registered with $client'
      : '[INFO] $client is installed but rhr mcp is not registered with it; '
            'run `rhr setup`';
  if (await _installed('claude')) {
    final config = _claudeConfig();
    lines.add(
      line(
        'Claude Code',
        config.existsSync() &&
            claudeRegistrationCurrent(config.readAsStringSync()),
      ),
    );
  }
  if (await _installed('codex')) {
    final get = await Process.run('codex', ['mcp', 'get', 'rhr', '--json']);
    lines.add(
      line(
        'Codex',
        get.exitCode == 0 && codexRegistrationCurrent('${get.stdout}'),
      ),
    );
  }
  if (await _installed('opencode')) {
    final config = File('$configHome/opencode/opencode.json');
    bool current;
    try {
      current =
          config.existsSync() &&
          withOpenCodeRhr(config.readAsStringSync()) == null;
    } on FormatException {
      current = false;
    }
    lines.add(line('OpenCode', current));
  }
  return lines;
}
