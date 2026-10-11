import 'package:rhr_cli/terminal_qr.dart';
import 'package:qr/qr.dart';
import 'package:test/test.dart';

void main() {
  test('renders a compact protected four-module quiet zone', () {
    final qr = renderTerminalQr('rhr-7df431f5f');
    final rows = qr.text.trimRight().split('\n');

    expect(qr.quietZoneModules, 4);
    expect(rows, hasLength(((qr.moduleCount + 8) / 2).ceil()));

    const white = '\x1b[47m ';
    const reset = '\x1b[0m';
    final fourWhiteModules = List.filled(4, white).join();

    for (final row in rows.take(2)) {
      expect(row, startsWith('  '));
      expect(
        RegExp(RegExp.escape(white)).allMatches(row),
        hasLength(qr.moduleCount + 8),
      );
      expect(row, endsWith(reset));
    }

    for (final row in rows) {
      final modules = RegExp(
        r'\x1b\[(?:30;47|37;40|40|47)m[ ▀]',
      ).allMatches(row).length;
      expect(modules, qr.moduleCount + 8);
      expect(row.substring(2), startsWith(fourWhiteModules));
      expect(row.substring(2), endsWith('$fourWhiteModules$reset'));
    }
  });

  test('structured LAN QR fits an 80-column terminal', () {
    final qr = renderTerminalQr(
      '{"code":"rhr-mpkp-kms4-du35",'
      '"relay":"ws://192.168.1.8:56117",'
      '"relays":["ws://192.168.1.8:56117",'
      '"wss://getrhr.dev"]}',
    );
    final rows = qr.text.trimRight().split('\n');
    final ansi = RegExp(r'\x1b\[[0-9;]*m');
    final visibleWidths = rows
        .map((row) => row.replaceAll(ansi, '').runes.length)
        .toList();

    expect(
      visibleWidths.reduce((a, b) => a > b ? a : b),
      lessThanOrEqualTo(80),
    );
    expect(rows.length, lessThanOrEqualTo(40));
  });

  test('compact cells preserve every QR module', () {
    const data = 'rhr-7df4-31f5-abcd';
    final expected = QrImage(
      QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M),
    );
    final rows = renderTerminalQr(data).text.trimRight().split('\n');
    final tokenPattern = RegExp(r'\x1b\[(30;47|37;40|40|47)m([ ▀])');

    for (var y = 0; y < expected.moduleCount; y++) {
      final tokens = tokenPattern.allMatches(rows[(y + 4) ~/ 2]).toList();
      for (var x = 0; x < expected.moduleCount; x++) {
        final style = tokens[x + 4].group(1);
        final renderedDark = switch ((style, (y + 4).isEven)) {
          ('40', _) => true,
          ('47', _) => false,
          ('30;47', true) => true,
          ('30;47', false) => false,
          ('37;40', true) => false,
          ('37;40', false) => true,
          _ => throw StateError('unknown compact QR cell $style'),
        };
        expect(renderedDark, expected.isDark(y, x), reason: 'module ($x, $y)');
      }
    }
  });
}
