import 'package:rhr_cli/rhr_mcp.dart';
import 'package:test/test.dart';

void main() {
  test('errorLines keeps error lines, whole Flutter reports, and exits', () {
    const lines = [
      'rhr-exit time=1 pid=9 reason=4 status=0 description=crash',
      '10-01 01:07:24.970 28391 28391 D Window: noise',
      '10-01 01:07:25.000 28391 28391 I flutter: ══╡ EXCEPTION CAUGHT BY WIDGETS LIBRARY ╞══════════',
      '10-01 01:07:25.000 28391 28391 I flutter: A RenderFlex overflowed.',
      '10-01 01:07:25.000 28391 28391 I flutter: ════════════════════════════════════════════════',
      '10-01 01:07:26.000 28391 28391 I flutter: after the report',
      '10-01 01:07:27.000 28391 28391 E AndroidRuntime: FATAL EXCEPTION: main',
    ];
    expect(errorLines(lines), [
      lines[0],
      lines[2],
      lines[3],
      lines[4],
      lines[6],
    ]);
  });

  test('formatTree gives one line per element with its tap point', () {
    final tree = {
      'windows': [
        {
          'type': 'application',
          'package': 'dev.example',
          'active': true,
          'nodes': [
            {
              'class': 'Button',
              'description': 'Increment',
              'flags': ['clickable'],
              'frame': [0.25, 0.5, 0.5, 0.1],
              'children': [
                {
                  'class': 'TextView',
                  'text': 'Increment',
                  'frame': [0.3, 0.52, 0.4, 0.06],
                },
              ],
            },
          ],
        },
      ],
    };
    expect(
      formatTree(tree),
      'window application dev.example (active)\n'
      '  Button desc="Increment" [clickable] tap=(0.5, 0.55)\n'
      '    TextView "Increment" tap=(0.5, 0.55)',
    );
    expect(treeTexts(tree), ['Increment', 'Increment']);
  });
}
