import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:rhr_cli/flutter_compatibility.dart';
import 'package:rhr_cli/player_update.dart';
import 'package:rhr_cli/relay_race.dart';
import 'package:rhr_cli/run_preparation.dart';
import 'package:test/test.dart';

const sdk = FlutterCompatibility(
  frameworkVersion: '3.44.2',
  frameworkRevision: 'local-framework',
  engineRevision: 'local-engine',
  dartSdkVersion: '3.12.2',
  channel: 'stable',
);

ProjectCompatibilityProfile project({
  Map<String, String> plugins = const {},
  List<String> native = const [],
}) => ProjectCompatibilityProfile(
  flutter: sdk,
  androidPlugins: plugins,
  androidPermissions: const {'android.permission.INTERNET'},
  unsupportedAndroidInputs: native,
);

final player = <String, dynamic>{
  'frameworkVersion': '3.35.7',
  'frameworkRevision': 'different-framework',
  'engineRevision': 'different-engine',
  'dartSdkVersion': '3.9.2',
  'channel': 'stable',
  'androidPlugins': <String, dynamic>{'camera': '1.0.0'},
  'androidPermissions': ['android.permission.INTERNET'],
};

final class Phone implements SessionTransport {
  final messages = <Map<String, dynamic>>[];
  void Function(Map<String, dynamic>)? onRequest;
  @override
  void sendControl(String message) {
    final decoded = jsonDecode(message) as Map<String, dynamic>;
    messages.add(decoded);
    if (decoded['t'] == 'run_request') onRequest?.call(decoded);
  }

  @override
  Stream<Object> get stream => const Stream.empty();
  @override
  Future<void> get payloadReady async {}
  @override
  Future<String> get selectedRelay async => 'test';
  @override
  String? get closeReason => null;
  @override
  Future<void> sendPayload(Uint8List message) async =>
      fail('No payload may be sent before preparation.');
  @override
  Future<void> close() async {}
}

void main() {
  test('SDK skew alone retains the hosted route for a runtime update', () {
    expect(selectRunRoute(project(), player), RunRoute.player);
  });
  test(
    'custom native sources choose the app route even with player SDK skew',
    () {
      expect(
        selectRunRoute(project(native: ['custom channel']), player),
        RunRoute.app,
      );
    },
  );
  test('missing or different native plugins choose the app route', () {
    expect(
      selectRunRoute(project(plugins: {'camera': '1.0.1'}), player),
      RunRoute.app,
    );
    expect(
      selectRunRoute(project(plugins: {'other': '1.0.0'}), player),
      RunRoute.app,
    );
    expect(
      selectRunRoute(project(plugins: {'camera': '1.0.0'}), player),
      RunRoute.player,
    );
  });
  test('no build or transfer starts before the phone announcement', () async {
    final phone = Phone();
    final preparation = RunPreparation(
      transport: phone,
      project: '/not-a-project',
      profile: project(),
      policy: PlayerUpdatePolicy.always,
    );
    final result = preparation.run();
    final stopped = expectLater(result, throwsA(isA<RunDisconnected>()));
    await Future<void>.delayed(Duration.zero);
    expect(phone.messages, isEmpty);
    preparation.close();
    await stopped;
  });
  test(
    'approval comes before any phone setup and ignores player SDK skew',
    () async {
      final directory = Directory.systemTemp.createTempSync('rhr-preparation-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final phone = Phone();
      final preparation = RunPreparation(
        transport: phone,
        project: directory.path,
        profile: project(native: ['custom channel']),
        policy: PlayerUpdatePolicy.never,
      );
      phone.onRequest = (request) => preparation.handleMessage({
        't': 'run_response',
        'id': request['id'],
        'ok': true,
        'ready': true,
        'installed': false,
      });
      preparation.handleMessage({
        't': 'info',
        'compatibility': player,
        'playerPackage': 'dev.rhr.rhr_player',
        'playerCertificate': 'a' * 64,
      });
      await expectLater(
        preparation.run(),
        throwsA(
          isA<ApprovalRequired>().having(
            (error) => error.declined,
            'declined',
            isFalse,
          ),
        ),
      );
      // With nothing built yet there is nothing to compare, and the phone
      // asks for nothing before the user approves the build.
      expect(
        phone.messages.where((message) => message['t'] == 'run_request'),
        isEmpty,
      );
      expect(
        phone.messages.where((message) => message['phase'] == 'building'),
        isEmpty,
      );
      preparation.close();
    },
  );

  for (final (agentOn, expectation) in [
    (true, 'goes ahead without asking'),
    (false, 'still needs approval'),
  ]) {
    test(
      'with RHR Agent ${agentOn ? 'on' : 'off'} a build $expectation',
      () async {
        final directory = Directory.systemTemp.createTempSync(
          'rhr-preparation-',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        final phone = Phone();
        final preparation = RunPreparation(
          transport: phone,
          project: directory.path,
          profile: project(native: ['custom channel']),
          policy: PlayerUpdatePolicy.prompt,
        );
        phone.onRequest = (request) => preparation.handleMessage({
          't': 'run_response',
          'id': request['id'],
          'ok': true,
          'ready': true,
          'on': agentOn,
        });
        preparation.handleMessage({
          't': 'info',
          'compatibility': player,
          'playerPackage': 'dev.rhr.rhr_player',
          'playerCertificate': 'a' * 64,
        });
        final outcome = await preparation.run().then<Object?>(
          (_) => null,
          onError: (Object error) => error,
        );
        // The temp project cannot build; only reaching the build matters.
        expect(outcome is ApprovalRequired, !agentOn);
        expect(
          phone.messages.any((message) => message['phase'] == 'building'),
          agentOn,
        );
        preparation.close();
      },
    );
  }

  test('a persist outlives a dropped connection', () async {
    final progress = RunProgress();
    var settled = false;
    progress.requestPersist().then(
      (_) => settled = true,
      onError: (Object _) => settled = true,
    );
    final preparation = RunPreparation(
      transport: Phone(),
      project: Directory.systemTemp.path,
      profile: project(),
      policy: PlayerUpdatePolicy.always,
      progress: progress,
    );
    final running = preparation.run();
    preparation.close();
    await expectLater(running, throwsA(isA<RunDisconnected>()));
    await pumpEventQueue();
    expect(settled, isFalse);
    expect(progress.persistRequested, isTrue);
  });

  test(
    'persist refuses a project the player hosts, before touching the phone',
    () async {
      final phone = Phone();
      final preparation = RunPreparation(
        transport: phone,
        project: Directory.systemTemp.path,
        profile: project(),
        policy: PlayerUpdatePolicy.always,
        task: RunTask.persist,
      );
      // Nothing native the player lacks: the player route.
      preparation.handleMessage({'t': 'info', 'compatibility': player});
      await expectLater(
        preparation.run(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('runs inside the player'),
          ),
        ),
      );
      expect(phone.messages.where((m) => m['t'] == 'run_request'), isEmpty);
    },
  );
}
