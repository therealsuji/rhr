import 'package:qr/qr.dart';

const _blackBackground = '\x1b[40m  ';
const _whiteBackground = '\x1b[47m  ';
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
/// Every QR cell gets an explicit background color. This prevents IDE debug
/// consoles from painting a selected/current-line color through light modules.
TerminalQrRender renderTerminalQr(String data) {
  final qr = QrCode.fromData(
    data: data,
    errorCorrectLevel: QrErrorCorrectLevel.M,
  );
  final image = QrImage(qr);
  final size = image.moduleCount;
  const quietZone = 4;
  final output = StringBuffer();

  for (var y = -quietZone; y < size + quietZone; y++) {
    output.write('  ');
    for (var x = -quietZone; x < size + quietZone; x++) {
      final dark =
          x >= 0 && y >= 0 && x < size && y < size && image.isDark(y, x);
      output.write(dark ? _blackBackground : _whiteBackground);
    }
    output.writeln(_resetColor);
  }

  return TerminalQrRender(
    text: output.toString(),
    moduleCount: size,
    quietZoneModules: quietZone,
  );
}
