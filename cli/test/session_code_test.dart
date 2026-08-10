import 'dart:math';

import 'package:rhr_bridge/session_code.dart';
import 'package:test/test.dart';

void main() {
  test('minted codes match the format accepted by RHR Player', () {
    final code = mintRhrSessionCode(random: Random(42));

    expect(code, matches(rhrSessionCodePattern));
  });
}
