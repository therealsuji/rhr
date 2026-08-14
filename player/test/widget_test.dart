import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:rhr_player/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('shows the empty player lobby', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const PlayerApp());
    await tester.pumpAndSettle();

    expect(find.text('rhr player · debug build'), findsOneWidget);
    expect(find.text('Scan QR to connect'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets('rejects malformed session codes without starting a service', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const PlayerApp());
    await tester.pumpAndSettle();

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
}
