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
    'old player reports a required update instead of streaming blindly',
    () async {
      final phone = Phone();
      final preparation = RunPreparation(
        transport: phone,
        project: '/not-a-project',
        profile: project(),
        policy: PlayerUpdatePolicy.always,
      );
      preparation.handleMessage({'t': 'info', 'compatibility': player});
      await expectLater(
        preparation.run(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('connection-first RHR update'),
          ),
        ),
      );
      expect(phone.messages, isEmpty);
      preparation.close();
    },
  );
  test(
    'connector setup precedes build approval and ignores player SDK skew',
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
      });
      preparation.handleMessage({
        't': 'info',
        'runProtocol': 1,
        'compatibility': player,
      });
      await expectLater(
        preparation.run(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('rhr run --yes'),
          ),
        ),
      );
      expect(
        phone.messages
            .where((message) => message['t'] == 'run_request')
            .map((message) => message['action']),
        ['connector', 'install_permission'],
      );
      expect(
        phone.messages.where((message) => message['phase'] == 'building'),
        isEmpty,
      );
      preparation.close();
    },
  );
}
