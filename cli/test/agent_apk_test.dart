import 'package:rhr_cli/agent_apk.dart';
import 'package:test/test.dart';

void main() {
  test('checksumIn reads the release SHA256SUMS the workflow writes', () {
    const sums =
        '73cb3858a687a8494ca3323053016282f3dad39d42cf62ca4e79dda2aac7d9ac  '
        'rhr-player-0.1.0-beta.17-android-arm64.apk\n'
        'c2257186d6a918ce4cc36d44bdecac9697ad5db6b17e09b2c5b616888aecc83e  '
        'rhr-agent-0.1.0-beta.17.apk\n';
    expect(
      checksumIn(sums, 'rhr-agent-0.1.0-beta.17.apk'),
      'c2257186d6a918ce4cc36d44bdecac9697ad5db6b17e09b2c5b616888aecc83e',
    );
    // A path-prefixed or different name is not the file asked for.
    expect(checksumIn(sums, 'agent-0.1.0-beta.17.apk'), isNull);
    expect(checksumIn(sums, 'rhr-agent-0.1.0-beta.1.apk'), isNull);
  });
}
