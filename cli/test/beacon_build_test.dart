import 'package:rhr_cli/beacon_build.dart';
import 'package:rhr_cli/run_preparation.dart';
import 'package:test/test.dart';

void main() {
  const certificate =
      '4f03a173e84e172eeaa4bbbf8318bf6104813522955a1c29544ad8d6516c73c5';

  test('a beacon build trusts the player that announced itself', () {
    expect(
      beaconPlayerFrom({
        'playerPackage': 'dev.rhr.rhr_player',
        'playerCertificate': certificate,
      }),
      (package: 'dev.rhr.rhr_player', certificate: certificate),
    );
  });

  test('a malformed identity keeps the adb route', () {
    expect(
      beaconPlayerFrom({
        'playerPackage': 'dev.rhr.rhr_player',
        'playerCertificate': 'not-a-hash',
      }),
      isNull,
    );
  });

  test('the init script quotes paths it did not choose', () {
    final script = beaconInitScript(
      "/Users/o'brien/app/.dart_tool/rhr/rhr_beacon",
      (package: 'dev.rhr.rhr_player', certificate: certificate),
    );
    expect(
      script,
      contains(r"new File('/Users/o\'brien/app/.dart_tool/rhr/rhr_beacon')"),
    );
    expect(script, contains("rhrPlayerCertificate: '$certificate'"));
    expect(script, contains("s.findProject(':app') == null"));
  });
}
