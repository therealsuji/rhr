import 'package:flutter_test/flutter_test.dart';
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
}
