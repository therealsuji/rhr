import 'package:rhr_cli/terminal_qr.dart';
import 'package:test/test.dart';

void main() {
  test('renders a protected four-module quiet zone', () {
    final qr = renderTerminalQr('rhr-7df431f5f');
    final rows = qr.text.trimRight().split('\n');

    expect(qr.quietZoneModules, 4);
    expect(rows, hasLength(qr.moduleCount + 8));

    const white = '\x1b[47m  ';
    const reset = '\x1b[0m';
    final fourWhiteModules = List.filled(4, white).join();

    for (final row in rows.take(4)) {
      expect(row, startsWith('  '));
      expect(
        RegExp(RegExp.escape(white)).allMatches(row),
        hasLength(qr.moduleCount + 8),
      );
      expect(row, endsWith(reset));
    }

    for (final row in rows) {
      final modules = RegExp(r'\x1b\[(?:40|47)m  ').allMatches(row).length;
      expect(modules, qr.moduleCount + 8);
      expect(row.substring(2), startsWith(fourWhiteModules));
      expect(row.substring(2), endsWith('$fourWhiteModules$reset'));
    }
  });
}
