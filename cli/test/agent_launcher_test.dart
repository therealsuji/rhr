import 'dart:convert';
import 'dart:io';

import 'package:rhr_cli/agent_launcher.dart';
import 'package:test/test.dart';

void main() {
  test(
    'the launcher runs rhr from a bare shell with the recorded tools',
    () async {
      final dir = Directory.systemTemp.createTempSync("rhr launcher '");
      addTearDown(() => dir.deleteSync(recursive: true));
      final tools = Directory('${dir.path}/fvm bin')..createSync();
      // A stand-in for the installed rhr: reports what it was given.
      final rhr = File('${dir.path}/rhr')
        ..writeAsStringSync(
          '#!/bin/sh\n'
          'echo "args=\$*"\n'
          'echo "java=\$JAVA_HOME"\n'
          'case ":\$PATH:" in *":${tools.path}:"*) echo tools-on-path;; esac\n',
        );
      Process.runSync('chmod', ['+x', rhr.path]);
      final launcher = File('${dir.path}/launcher')
        ..writeAsStringSync(
          launcherScript(
            rhr: rhr.path,
            folders: [tools.path],
            javaHome: "/opt/jdk's",
          ),
        );
      Process.runSync('chmod', ['+x', launcher.path]);

      final bare = await Process.run('/usr/bin/env', [
        '-i',
        'PATH=/usr/bin:/bin',
        launcher.path,
        'run',
        '--yes',
      ], includeParentEnvironment: false);
      expect(bare.stdout, contains('args=run --yes'));
      expect(bare.stdout, contains("java=/opt/jdk's"));
      expect(bare.stdout, contains('tools-on-path'));

      // A JAVA_HOME the caller set wins over the recorded one.
      final own = await Process.run('/usr/bin/env', [
        '-i',
        'PATH=/usr/bin:/bin',
        'JAVA_HOME=/mine',
        launcher.path,
      ], includeParentEnvironment: false);
      expect(own.stdout, contains('java=/mine'));
    },
    testOn: '!windows',
  );

  test('the rhr mcp registration is current only through the launcher', () {
    const current =
        'rhr:\n'
        '  Scope: User config (available in all your projects)\n'
        '  Status: ✔ Connected\n'
        '  Type: stdio\n'
        '  Command: $launcherPath\n'
        '  Args: mcp\n';
    expect(mcpRegistrationCurrent(current), isTrue);
    expect(
      mcpRegistrationCurrent(current.replaceFirst(launcherPath, 'rhr')),
      isFalse,
    );
    expect(
      mcpRegistrationCurrent(
        current.replaceFirst('User config', 'Local config'),
      ),
      isFalse,
    );
    expect(
      mcpRegistrationCurrent(current.replaceFirst('Args: mcp', 'Args: run')),
      isFalse,
    );
  });

  test('the Codex registration is current only through the launcher', () {
    String get(String command, List<String> args) => jsonEncode({
      'name': 'rhr',
      'transport': {'type': 'stdio', 'command': command, 'args': args},
    });
    expect(codexRegistrationCurrent(get(launcherPath, ['mcp'])), isTrue);
    expect(codexRegistrationCurrent(get('rhr', ['mcp'])), isFalse);
    expect(codexRegistrationCurrent(get(launcherPath, ['run'])), isFalse);
    expect(codexRegistrationCurrent('Error: no server'), isFalse);
  });

  test('OpenCode keeps its config and gains rhr mcp once', () {
    const config =
        '{\n'
        '\t"\$schema": "https://opencode.ai/config.json",\n'
        '\t"mcp": {\n'
        '\t\t"pencil": {"type": "local", "command": ["pen"], "enabled": true}\n'
        '\t},\n'
        '\t"plugin": ["a"]\n'
        '}\n';
    final updated = withOpenCodeRhr(config)!;
    final decoded = jsonDecode(updated) as Map<String, dynamic>;
    expect(decoded.keys, [r'$schema', 'mcp', 'plugin']);
    expect((decoded['mcp'] as Map).keys, ['pencil', 'rhr']);
    expect(decoded['mcp']['rhr'], {
      'type': 'local',
      'command': [launcherPath, 'mcp'],
      'enabled': true,
    });
    expect(updated, startsWith('{\n\t"'));
    // A second setup leaves the file alone.
    expect(withOpenCodeRhr(updated), isNull);
    // No config yet.
    expect(jsonDecode(withOpenCodeRhr('')!)['mcp']['rhr'], isNotNull);
    expect(() => withOpenCodeRhr('[]'), throwsFormatException);
  });

  test('the launcher puts java on PATH, from PATH or JAVA_HOME', () {
    final dir = Directory.systemTemp.createTempSync('rhr tools');
    addTearDown(() => dir.deleteSync(recursive: true));
    File tool(String folder, String name) =>
        File('${dir.path}/$folder/$name')..createSync(recursive: true);
    tool('fvm', 'dart');
    tool('fvm', 'flutter');
    tool('sdk', 'adb');
    tool('jdk/bin', 'java');
    final fvm = '${dir.path}/fvm';
    final sdk = '${dir.path}/sdk';
    final jdk = '${dir.path}/jdk/bin';

    expect(toolFolders({'PATH': '$fvm:$sdk:$jdk'}), [fvm, sdk, jdk]);
    // apksigner runs java from PATH, so a JAVA_HOME-only JDK still lands there.
    expect(toolFolders({'PATH': '$fvm:$sdk', 'JAVA_HOME': '${dir.path}/jdk'}), [
      fvm,
      sdk,
      jdk,
    ]);
    expect(toolFolders({'PATH': '$fvm:$sdk'}), [fvm, sdk]);
  });
}
