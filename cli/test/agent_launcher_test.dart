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
}
