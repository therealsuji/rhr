// The comparison behind "am I running the current player?".
//
// Worth testing because it is the part that can be wrong quietly: a check
// that always says "up to date" looks exactly like a working one, and the
// tester it lies to is the person least able to notice.

import 'package:flutter_test/flutter_test.dart';
import 'package:rhr_player/update_check.dart';

void main() {
  group('compareVersions', () {
    test('a tag and an installed version match despite the leading v', () {
      final status = compareVersions(
        installed: '0.1.0-beta.8',
        latestTag: 'v0.1.0-beta.8',
      );
      expect(status, isA<UpToDate>());
      expect((status as UpToDate).version, '0.1.0-beta.8');
    });

    test('an older build is offered the newer release', () {
      final status = compareVersions(
        installed: '0.1.0-beta.7',
        latestTag: 'v0.1.0-beta.8',
      );
      expect(status, isA<UpdateAvailable>());
      final update = status as UpdateAvailable;
      expect(update.installed, '0.1.0-beta.7');
      expect(update.latest, '0.1.0-beta.8');
    });

    /// The state every release was in until the workflow started stamping
    /// --build-name: the APK reported a bare "0.1.0" for beta.6, .7 and .8
    /// alike. It must read as "go and look", never as "up to date".
    test('an unstamped build does not claim to be current', () {
      final status = compareVersions(
        installed: '0.1.0',
        latestTag: 'v0.1.0-beta.8',
      );
      expect(status, isA<UpdateAvailable>());
    });

    test('a build with no version says so rather than guessing', () {
      final status = compareVersions(installed: '  ', latestTag: 'v0.1.0');
      expect(status, isA<UpdateCheckFailed>());
    });

    test('no releases is a failed check, not an up-to-date one', () {
      for (final tag in [null, '']) {
        expect(
          compareVersions(installed: '0.1.0-beta.8', latestTag: tag),
          isA<UpdateCheckFailed>(),
          reason: 'tag $tag should not read as current',
        );
      }
    });

    test('whitespace around either side does not matter', () {
      expect(
        compareVersions(installed: ' 0.1.0-beta.8 ', latestTag: ' v0.1.0-beta.8 '),
        isA<UpToDate>(),
      );
    });
  });

  group('checkForUpdate', () {
    test('a network failure is reported, not swallowed', () async {
      final status = await checkForUpdate(
        installedVersion: () async => '0.1.0-beta.8',
        fetchTag: () async => throw const SocketExceptionStub(),
      );
      expect(status, isA<UpdateCheckFailed>());
    });

    test('a successful check compares what it fetched', () async {
      final status = await checkForUpdate(
        installedVersion: () async => '0.1.0-beta.7',
        fetchTag: () async => 'v0.1.0-beta.8',
      );
      expect(status, isA<UpdateAvailable>());
    });
  });
}

/// Stands in for a connection failure without opening a socket.
final class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
