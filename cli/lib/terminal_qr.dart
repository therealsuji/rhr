import 'package:qr/qr.dart';

const _blackCell = '\x1b[40m ';
const _whiteCell = '\x1b[47m ';
const _blackOverWhite = '\x1b[30;47m▀';
const _whiteOverBlack = '\x1b[37;40m▀';
const _resetColor = '\x1b[0m';

class TerminalQrRender {
  const TerminalQrRender({
    required this.text,
    required this.moduleCount,
    required this.quietZoneModules,
  });

  final String text;
  final int moduleCount;
  final int quietZoneModules;
}

/// Renders a standards-shaped, theme-independent QR for terminal output.
///
/// Two vertical QR modules share one terminal cell via an upper-half block.
/// Terminal cells are normally about twice as tall as they are wide, so this
/// keeps modules roughly square while halving both the rendered width and
/// height. Every cell sets explicit colors so IDE line highlighting cannot
/// bleed through light modules.
TerminalQrRender renderTerminalQr(String data) {
  final qr = QrCode.fromData(
    data: data,
    errorCorrectLevel: QrErrorCorrectLevel.M,
  );
  final image = QrImage(qr);
  final size = image.moduleCount;
  const quietZone = 4;
  final output = StringBuffer();

  bool isDark(int x, int y) =>
      x >= 0 && y >= 0 && x < size && y < size && image.isDark(y, x);

  for (var y = -quietZone; y < size + quietZone; y += 2) {
    output.write('  ');
    for (var x = -quietZone; x < size + quietZone; x++) {
      final upper = isDark(x, y);
      final lower = isDark(x, y + 1);
      output.write(switch ((upper, lower)) {
        (true, true) => _blackCell,
        (false, false) => _whiteCell,
        (true, false) => _blackOverWhite,
        (false, true) => _whiteOverBlack,
      });
    }
    output.writeln(_resetColor);
  }

  return TerminalQrRender(
    text: output.toString(),
    moduleCount: size,
    quietZoneModules: quietZone,
  );
}
