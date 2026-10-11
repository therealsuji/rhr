import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:rhr_cli/devfs_delta.dart';
import 'package:test/test.dart';

void main() {
  test('round-trips an insertion that shifts everything after it', () {
    final random = Random(1);
    final base = Uint8List.fromList(
      List.generate(300000, (_) => random.nextInt(256)),
    );
    final next = Uint8List.fromList([
      ...base.sublist(0, 120000),
      ...'a changed line of source'.codeUnits,
      ...base.sublist(120000),
    ]);

    final delta = encodeDevFsDelta(base, next);

    expect(applyDevFsDelta(base, delta), next);
    expect(delta.length, lessThan(20000));
  });

  test('round-trips unrelated content as literals', () {
    final base = Uint8List.fromList(List.filled(5000, 1));
    final next = Uint8List.fromList(List.generate(7000, (i) => i % 251));

    expect(applyDevFsDelta(base, encodeDevFsDelta(base, next)), next);
  });

  test('rejects bytes that are not a delta', () {
    expect(
      () => applyDevFsDelta(Uint8List(0), Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
  });

  // Two real debug kernels that differ by one string, when a local build
  // left them in place (see RHR_DELTA_KERNELS). Skipped otherwise.
  final kernels = Platform.environment['RHR_DELTA_KERNELS']?.split(':');
  test(
    'shrinks a real hot-restart kernel to kilobytes',
    () {
      final base = File(kernels![0]).readAsBytesSync();
      final next = File(kernels[1]).readAsBytesSync();
      final delta = encodeDevFsDelta(base, next);
      expect(applyDevFsDelta(base, delta), next);
      expect(delta.length, lessThan(64 * 1024));
    },
    skip: kernels == null ? 'set RHR_DELTA_KERNELS=old.dill:new.dill' : false,
  );
}
