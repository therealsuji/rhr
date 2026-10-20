import 'package:rhr_cli/account_auth.dart';
import 'package:test/test.dart';

void main() {
  const stored = AccountSession(
    accessToken: 'old',
    refreshToken: 'refresh',
    userId: 'user_1',
    email: 'a@b.c',
  );

  test('a refused refresh ends the sign-in with the service\'s reason', () {
    // What WorkOS answered on Oct 19, after two idle days.
    final state = refreshOutcome(
      400,
      '{"error":"invalid_grant","error_description":"Session ended due to inactivity."}',
      stored,
    );
    expect(state, isA<SignInEnded>());
    expect((state as SignInEnded).reason, 'Session ended due to inactivity.');
  });

  test('a server error says nothing about the session', () {
    expect(refreshOutcome(503, 'upstream', stored), isA<AccountUnreachable>());
  });

  test('a refreshed token keeps the stored refresh token when none is sent', () {
    final state = refreshOutcome(200, '{"access_token":"new"}', stored);
    final session = (state as SignedIn).session;
    expect(session.accessToken, 'new');
    expect(session.refreshToken, 'refresh');
    expect(session.email, 'a@b.c');
  });
}
