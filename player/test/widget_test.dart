import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:rhr_player/main.dart';
import 'package:rhr_player/session_code_field.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('leads with scanning, not with a code field', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const PlayerApp());
    await tester.pumpAndSettle();

    expect(find.text('rhr player · debug build'), findsOneWidget);
    expect(find.text('Scan to connect'), findsOneWidget);
    // Joining is how this is used now; the code is a way in round the back.
    expect(find.byType(SessionCodeField), findsNothing);
    expect(find.text('Enter a session code instead'), findsOneWidget);
  });

  testWidgets('a code is still one tap away', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const PlayerApp());
    await tester.pumpAndSettle();

    // Demoted, not removed: this is the only way in when the account service
    // cannot be reached.
    await tester.tap(find.text('Enter a session code instead'));
    await tester.pumpAndSettle();

    expect(find.byType(SessionCodeField), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets('rejects an incomplete session code without starting a service', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const PlayerApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enter a session code instead'));
    await tester.pumpAndSettle();

    // The formatter drops everything outside the alphabet, so what lands in
    // the field is a short-but-well-formed code — still not a valid one.
    await tester.enterText(find.byType(TextField), 'not-a-session');
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pump();

    expect(
      find.text(
        "That doesn't look like an rhr code — codes look like "
        'rhr-xxxx-xxxx-xxxx.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('typing the full printed code keeps its prefix once', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionCodeField(
            controller: controller,
            actionLabel: 'Connect',
            onSubmit: () {},
            onScanned: (_) {},
          ),
        ),
      ),
    );
    await tester.showKeyboard(find.byType(TextField));
    for (final character in 'rhr-abcd-efgh-jkmn'.split('')) {
      tester.testTextInput.enterText('${controller.text}$character');
      await tester.pump();
    }
    expect(controller.text, 'rhr-abcd-efgh-jkmn');
  });

  group('formatSessionCodeInput', () {
    test('groups a bare token and adds the prefix', () {
      expect(formatSessionCodeInput('abcdefghjkmn'), 'rhr-abcd-efgh-jkmn');
    });

    test('does not double the prefix on paste', () {
      expect(
        formatSessionCodeInput('rhr-abcd-efgh-jkmn'),
        'rhr-abcd-efgh-jkmn',
      );
    });

    test('keeps typing incremental once the prefix is on screen', () {
      // The formatter re-runs on the whole field, so the prefix it added last
      // keystroke must not be re-consumed as code characters.
      expect(formatSessionCodeInput('rhr-a'), 'rhr-a');
      expect(formatSessionCodeInput('rhr-abcd'), 'rhr-abcd');
      expect(formatSessionCodeInput('rhr-abcde'), 'rhr-abcd-e');
    });

    test('lowercases and drops characters outside the alphabet', () {
      // 'i', 'l', 'o' and '0' are excluded from the alphabet precisely
      // because they are misread; dropping them beats accepting a code that
      // can never match.
      expect(formatSessionCodeInput('ABCD EFGH'), 'rhr-abcd-efgh');
      expect(formatSessionCodeInput('ilo01'), '');
    });

    test('stops at a full code', () {
      expect(formatSessionCodeInput('abcdefghjkmnpqrs'), 'rhr-abcd-efgh-jkmn');
    });

    test('is empty until the first character', () {
      expect(formatSessionCodeInput(''), '');
    });
  });

  group('parseSessionPayload', () {
    test('reads a session deep link', () {
      final entry = parseSessionPayload(
        'rhr://connect?code=rhr-abcd-efgh-jkmn&relay=wss%3A%2F%2Fone.example&relay=ws%3A%2F%2F192.168.1.5%3A8123',
      );
      expect(entry.code, 'rhr-abcd-efgh-jkmn');
      expect(entry.relay, 'wss://one.example');
      expect(entry.fallbackRelays, ['ws://192.168.1.5:8123']);
    });
    test('reads a code and its relay list', () {
      final entry = parseSessionPayload(
        '{"code":"rhr-abcd-efgh-jkmn",'
        '"relays":["wss://one.example","wss://two.example"]}',
      );
      expect(entry.code, 'rhr-abcd-efgh-jkmn');
      expect(entry.relay, 'wss://one.example');
      expect(entry.fallbackRelays, ['wss://two.example']);
    });

    test('accepts the single-relay form', () {
      final entry = parseSessionPayload(
        '{"code":"rhr-abcd-efgh-jkmn","relay":"wss://one.example"}',
      );
      expect(entry.relay, 'wss://one.example');
      expect(entry.fallbackRelays, isEmpty);
    });

    test('falls back to a bare code, leaving the relay alone', () {
      final entry = parseSessionPayload('rhr-abcd-efgh-jkmn');
      expect(entry.code, 'rhr-abcd-efgh-jkmn');
      expect(entry.relay, isNull);
    });
  });
}
