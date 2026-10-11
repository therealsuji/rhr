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
          activate: (tag) async {
            tags.add(tag);
            return 0;
          },
          output: messages.add,
        ),
        0,
      );
      expect(tags, [newer.tag]);
      expect(messages, contains(contains('Installed 0.1.0-beta.10')));
      messages.clear();
      expect(
        await runCliUpdate(
          [],
          currentVersion: '0.1.0-beta.8',
          fetchRelease: () async => newer,
          activate: (_) async => 65,
          output: messages.add,
        ),
        65,
      );
      expect(messages.last, contains('Update failed'));
      expect(messages.any((line) => line.contains('Installed')), isFalse);
    },
  );

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
