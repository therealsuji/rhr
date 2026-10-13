import 'dart:convert';
import 'dart:io';

import 'package:pub_semver/pub_semver.dart';
import 'package:rhr_cli/cli_update.dart';
import 'package:test/test.dart';

void main() {
  final newer = CliRelease('v0.1.0-beta.10', Version.parse('0.1.0-beta.10'));

  test(
    'selects by semantic version, includes betas, excludes drafts and bad tags',
    () {
      final release = newestCliRelease([
        {'tag_name': 'v0.1.0-beta.9', 'draft': false},
        {'tag_name': 'v0.1.0-beta.10', 'draft': false},
        {'tag_name': 'v9.0.0', 'draft': true},
        {'tag_name': '--git-ref=main', 'draft': false},
        {'tag_name': 'v0.1.0-beta.8', 'draft': false},
      ]);
      expect(release.tag, newer.tag);
      expect(
        newestCliRelease([
          {'tag_name': newer.tag, 'draft': false},
          {'tag_name': 'v0.1.0', 'draft': false},
        ]).version,
        Version.parse('0.1.0'),
      );
      expect(() => newestCliRelease([]), throwsStateError);
      expect(() => newestCliRelease({}), throwsFormatException);
    },
  );

  test('check reports an available update without installing it', () async {
    final messages = <String>[];
    expect(
      await runCliUpdate(
        ['--check'],
        currentVersion: '0.1.0-beta.8',
        fetchRelease: () async => newer,
        activate: (_) async => fail('Check must not install'),
        output: messages.add,
      ),
      0,
    );
    expect(messages.last, contains('Run `rhr update`'));
  });

  test('does not reinstall or downgrade', () async {
    for (final current in ['0.1.0-beta.10', '0.1.0', '1.0.0']) {
      expect(
        await runCliUpdate(
          [],
          currentVersion: current,
          fetchRelease: () async => newer,
          activate: (_) async => fail('Must keep the current CLI'),
          output: (_) {},
        ),
        0,
      );
    }
  });

  test(
    'activates the exact release and reports completion only on success',
    () async {
      final tags = <String>[];
      final messages = <String>[];
      expect(
        await runCliUpdate(
          [],
          currentVersion: '0.1.0-beta.8',
          fetchRelease: () async => newer,
          verify: (tag) async => tag == newer.tag ? _commit : fail(tag),
          activate: (commit) async {
            tags.add(commit);
            return 0;
          },
          output: messages.add,
        ),
        0,
      );
      // The commit the signed tag names, never the movable tag itself.
      expect(tags, [_commit]);
      expect(messages, contains(contains('Installed 0.1.0-beta.10')));
      messages.clear();
      expect(
        await runCliUpdate(
          [],
          currentVersion: '0.1.0-beta.8',
          fetchRelease: () async => newer,
          verify: (_) async => _commit,
          activate: (_) async => 65,
          output: messages.add,
        ),
        65,
      );
      expect(messages.last, contains('Update failed'));
      expect(messages.any((line) => line.contains('Installed')), isFalse);
    },
  );

  test('an unsigned release is refused without installing', () async {
    final messages = <String>[];
    expect(
      await runCliUpdate(
        [],
        currentVersion: '0.1.0-beta.8',
        fetchRelease: () async => newer,
        verify: (tag) async =>
            throw UntrustedRelease('$tag carries no signature.'),
        activate: (_) async => fail('Must not install'),
        output: messages.add,
      ),
      1,
    );
    expect(messages.last, contains('carries no signature'));
  });

  group('release tag signatures', () {
    late Directory dir;
    late String key;
    late String payload;
    late String signature;
    late String commit;

    // A real SSH-signed tag, made the way a release is, with a throwaway key.
    setUpAll(() async {
      dir = Directory.systemTemp.createTempSync('rhr-signed-tag-');
      Future<String> run(String exe, List<String> args) async {
        final result = await Process.run(exe, args, workingDirectory: dir.path);
        if (result.exitCode != 0) fail('$exe $args: ${result.stderr}');
        return '${result.stdout}';
      }

      await run('ssh-keygen', ['-q', '-t', 'ed25519', '-N', '', '-f', 'key']);
      key = File('${dir.path}/key.pub').readAsStringSync().trim();
      await run('git', ['init', '-q']);
      await run('git', [
        '-c', 'user.name=t', '-c', 'user.email=t@t', //
        'commit', '-q', '--allow-empty', '-m', 'x',
      ]);
      commit = (await run('git', ['rev-parse', 'HEAD'])).trim();
      await run('git', [
        '-c', 'user.name=t', '-c', 'user.email=t@t', //
        '-c', 'gpg.format=ssh', '-c', 'user.signingkey=${dir.path}/key',
        'tag', '-s', 'v1.0.0', '-m', 'v1.0.0',
      ]);
      final raw = await run('git', ['cat-file', 'tag', 'v1.0.0']);
      final start = raw.indexOf('-----BEGIN SSH SIGNATURE-----');
      payload = raw.substring(0, start);
      signature = raw.substring(start);
    });
    tearDownAll(() => dir.deleteSync(recursive: true));

    test('names the commit only for the tag it signs', () {
      expect(signedTagCommit(payload, 'v1.0.0'), commit);
      expect(
        () => signedTagCommit(payload, 'v2.0.0'),
        throwsA(isA<UntrustedRelease>()),
      );
    });

    test('accepts the release key and nothing else', () async {
      await verifyReleaseSignature(payload, signature, signingKey: key);
      await expectLater(
        verifyReleaseSignature(payload, signature),
        throwsA(isA<UntrustedRelease>()),
      );
      await expectLater(
        verifyReleaseSignature(
          payload.replaceFirst('v1.0.0', 'v9.9.9'),
          signature,
          signingKey: key,
        ),
        throwsA(isA<UntrustedRelease>()),
      );
    });

    test('reads the tag from GitHub and returns its commit', () async {
      final answers = {
        '/git/ref/tags/v1.0.0': {
          'object': {'type': 'tag', 'sha': 'abc'},
        },
        '/git/tags/abc': {
          'verification': {'payload': payload, 'signature': signature},
        },
      };
      Future<Object?> getJson(Uri url) async =>
          answers.entries.firstWhere((e) => url.path.endsWith(e.key)).value;
      expect(
        await verifiedReleaseCommit(
          'v1.0.0',
          getJson: getJson,
          signingKey: key,
        ),
        commit,
      );
      // A lightweight tag points straight at a commit and carries nothing.
      answers['/git/ref/tags/v1.0.0'] = {
        'object': {'type': 'commit', 'sha': commit},
      };
      await expectLater(
        verifiedReleaseCommit('v1.0.0', getJson: getJson, signingKey: key),
        throwsA(isA<UntrustedRelease>()),
      );
    });
  });

  test('invalid options fail before network access', () async {
    expect(
      await runCliUpdate(
        ['--force'],
        fetchRelease: () async => fail('Must not fetch'),
        output: (_) {},
      ),
      64,
    );
  });

  test('network errors return a useful failure without installing', () async {
    final messages = <String>[];
    expect(
      await runCliUpdate(
        [],
        fetchRelease: () async => throw const SocketException('offline'),
        activate: (_) async => fail('Must not install'),
        output: messages.add,
      ),
      1,
    );
    expect(messages.single, contains('Check your connection'));
  });

  test(
    'reads release metadata over HTTP and rejects an HTTP failure',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var status = 200;
      server.listen((request) async {
        expect(
          request.headers.value(HttpHeaders.userAgentHeader),
          startsWith('rhr-cli/'),
        );
        request.response.statusCode = status;
        request.response.write(
          jsonEncode([
            {'tag_name': newer.tag, 'draft': false},
          ]),
        );
        await request.response.close();
      });
      final endpoint = Uri.parse('http://127.0.0.1:${server.port}/releases');
      expect((await fetchCliRelease(endpoint: endpoint)).tag, newer.tag);
      status = 403;
      await expectLater(
        fetchCliRelease(endpoint: endpoint),
        throwsA(isA<HttpException>()),
      );
    },
  );
}

const _commit = '0123456789abcdef0123456789abcdef01234567';
