import 'dart:io';

import 'package:rhr_cli/version.dart';
import 'package:test/test.dart';

void main() {
  // The README's install command is what a new developer copies. Pinned to
  // an older release, it installed a CLI without the features the README
  // goes on to describe.
  test('the README installs this version', () {
    final readme = File('../README.md').readAsStringSync();
    final pins = RegExp(
      r'--git-ref (v\S+)',
    ).allMatches(readme).map((m) => m.group(1));
    expect(pins, isNotEmpty);
    expect(pins, everyElement('v$rhrVersion'));
  });
}
