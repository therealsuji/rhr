import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'device_control.dart';
import 'session_control.dart';

/// `rhr mcp`: lets a coding agent see, drive and debug the app on a tester's
/// phone, through the rhr session already holding that phone.
///
/// The relay admits one developer per phone, so this is a client of the
/// running `rhr run`/`rhr attach` and never opens a session of its own. It
/// finds the session in the project's `.dart_tool/rhr/control.json` and reads
/// the file again whenever the session may have reconnected.
///
/// Three layers, each doing what only it can:
/// - device control (RHR Agent on the phone): screen, window tree across all
///   apps, taps and text anywhere, system dialogs included;
/// - native logs (the app's beacon, or the player for a hosted project);
/// - the VM service: evaluate, and hot reload through the session.
base class RhrMcpServer extends MCPServer with ToolsSupport {
  RhrMcpServer(super.channel, {required this.project})
    : super.fromStreamChannel(
        implementation: Implementation(name: 'rhr', version: '0.1.0'),
        instructions: _instructions,
      ) {
    registerTool(_statusTool, _status);
    registerTool(_screenshotTool, _screenshot);
    registerTool(_describeTool, _describe);
    registerTool(_tapTool, _tap);
    registerTool(_longPressTool, _longPress);
    registerTool(_swipeTool, _swipe);
    registerTool(_typeTool, _type);
    registerTool(_pressTool, _press);
    registerTool(_launchAppTool, _launchApp);
    registerTool(_openUrlTool, _openUrl);
    registerTool(_waitForTool, _waitFor);
    registerTool(_logsTool, _logs);
    registerTool(_errorsTool, _errors);
    registerTool(_evaluateTool, _evaluate);
    registerTool(_hotReloadTool, _hotReload);
    registerTool(_hotRestartTool, _hotRestart);
    registerTool(_installAgentTool, _installAgent);
  }

  final String project;
  _Session? _session;

  @override
  Future<void> shutdown() async {
    await _session?.close();
    await super.shutdown();
  }

  /// The running session, reconnecting when it has published new endpoints.
  Future<_Session> _current() async {
    final endpoints = readSessionEndpoints(project);
    if (endpoints == null) {
      throw _ToolFailure(
        'No rhr session is running for $project. Start one with `rhr run` '
        '(or `rhr attach`) in that directory, then try again.',
      );
    }
    final session = _session;
    if (session != null && session.endpoints == endpoints) return session;
    await session?.close();
    return _session = _Session(endpoints);
  }

  // ---- Status ----

  static final _statusTool = Tool(
    name: 'status',
    description:
        'What rhr can reach on the phone right now: the session, device '
        'control (RHR Agent), native logs, and the Dart VM.',
    inputSchema: Schema.object(),
  );

  Future<CallToolResult> _status(CallToolRequest request) => _run(() async {
    final session = await _current();
    final lines = <String>[
      'session: running (${session.endpoints.vm})',
      if (session.endpoints.app case final app?) 'app package: $app',
    ];
    try {
      final info = await (await session.device()).request('info');
      lines.add(
        'device control: on; screen ${info['width']}x${info['height']}, '
        'rotation ${info['rotation']}, foreground ${info['foreground']}',
      );
    } on DeviceControlException catch (e) {
      lines.add(
        'device control: unavailable (${e.code}): ${e.message}\n'
        '  Without it there are no screenshots, taps or typing; logs, '
        'evaluate and hot reload still work.',
      );
      if (e.code == 'agent_missing' || e.code == 'agent_untrusted') {
        lines.add('  install_agent puts RHR Agent on the phone.');
      }
    }
    try {
      final isolate = await session.mainIsolate();
      lines.add('dart vm: connected, isolate ${isolate.name}');
    } on Object catch (e) {
      lines.add('dart vm: unavailable: $e');
    }
    return _text(lines.join('\n'));
  });

  // ---- Looking ----

  static final _screenshotTool = Tool(
    name: 'screenshot',
    description:
        "The phone's whole screen, system UI and dialogs included. Take tap "
        'coordinates from describe, not from the image.',
    inputSchema: Schema.object(
      properties: {
        'scale': Schema.num(
          description: 'Fraction of full resolution, 0.1 to 1 (default 0.5).',
          minimum: 0.1,
          maximum: 1,
        ),
      },
    ),
  );

  Future<CallToolResult> _screenshot(CallToolRequest request) => _run(() async {
    final device = await (await _current()).device();
    final scale = (request.arguments?['scale'] as num?)?.toDouble() ?? 0.5;
    return CallToolResult(content: [await _shot(device, scale)]);
  });

  static final _describeTool = Tool(
    name: 'describe',
    description:
        'Every window on screen, top-most first, with its meaningful elements: '
        'class, text, description, view id, flags and tap point. Tap points '
        'are fractions of the screen (0 to 1), ready for tap. Covers Flutter '
        'widgets, native views and system dialogs alike.',
    inputSchema: Schema.object(),
  );

  Future<CallToolResult> _describe(CallToolRequest request) => _run(() async {
    final device = await (await _current()).device();
    return _text(formatTree(await device.request('tree')));
  });

  // ---- Acting ----

  static final _point = {
    'x': Schema.num(description: 'Fraction of screen width, 0 to 1.'),
    'y': Schema.num(description: 'Fraction of screen height, 0 to 1.'),
  };

  static final _tapTool = Tool(
    name: 'tap',
    description:
        'Taps a point, anywhere on screen, including system permission '
        'dialogs. Returns the screen after the tap.',
    inputSchema: Schema.object(properties: _point, required: ['x', 'y']),
  );

  Future<CallToolResult> _tap(CallToolRequest request) =>
      _act('tap', request.arguments!);

  static final _longPressTool = Tool(
    name: 'long_press',
    description: 'Presses and holds a point. Returns the screen after it.',
    inputSchema: Schema.object(
      properties: {
        ..._point,
        'duration_ms': Schema.int(description: 'Hold time (default 800).'),
      },
      required: ['x', 'y'],
    ),
  );

  Future<CallToolResult> _longPress(CallToolRequest request) =>
      _act('long_press', request.arguments!);

  static final _swipeTool = Tool(
    name: 'swipe',
    description:
        'Drags from (x, y) to (to_x, to_y). Swipe up (to_y < y) to scroll '
        'content down. Returns the screen after it.',
    inputSchema: Schema.object(
      properties: {
        ..._point,
        'to_x': Schema.num(description: 'End, fraction of screen width.'),
        'to_y': Schema.num(description: 'End, fraction of screen height.'),
        'duration_ms': Schema.int(description: 'Drag time (default 300).'),
      },
      required: ['x', 'y', 'to_x', 'to_y'],
    ),
  );

  Future<CallToolResult> _swipe(CallToolRequest request) =>
      _act('swipe', request.arguments!);

  static final _typeTool = Tool(
    name: 'type',
    description:
        'Replaces the text of the focused text field. Tap the field first. '
        'Returns the screen after it.',
    inputSchema: Schema.object(
      properties: {'text': Schema.string()},
      required: ['text'],
    ),
  );

  Future<CallToolResult> _type(CallToolRequest request) =>
      _act('set_text', request.arguments!);

  static final _pressTool = Tool(
    name: 'press',
    description: 'Presses a system button. Returns the screen after it.',
    inputSchema: Schema.object(
      properties: {
        'button': UntitledSingleSelectEnumSchema(
          values: [
            'back',
            'home',
            'recents',
            'notifications',
            'quick_settings',
          ],
        ),
      },
      required: ['button'],
    ),
  );

  Future<CallToolResult> _press(CallToolRequest request) =>
      _act('global', {'action': request.arguments!['button']});

  static final _launchAppTool = Tool(
    name: 'launch_app',
    description:
        'Opens an installed app by package name, e.g. to bring the app under '
        'test back to the front. Returns the screen after it.',
    inputSchema: Schema.object(
      properties: {'package': Schema.string()},
      required: ['package'],
    ),
  );

  Future<CallToolResult> _launchApp(CallToolRequest request) =>
      _act('launch', request.arguments!, settle: const Duration(seconds: 2));

  static final _openUrlTool = Tool(
    name: 'open_url',
    description:
        'Opens a URL on the phone (a deep link or a web page). Returns the '
        'screen after it.',
    inputSchema: Schema.object(
      properties: {'url': Schema.string()},
      required: ['url'],
    ),
  );

  Future<CallToolResult> _openUrl(CallToolRequest request) =>
      _act('launch', request.arguments!, settle: const Duration(seconds: 2));

  /// Performs [op], waits for the UI to settle, and returns the screen: a
  /// small screenshot plus the tree, so the agent rarely needs a separate
  /// look before its next action.
  Future<CallToolResult> _act(
    String op,
    Map<String, Object?> args, {
    Duration settle = const Duration(milliseconds: 600),
  }) => _run(() async {
    final device = await (await _current()).device();
    await device.request(op, args);
    await Future<void>.delayed(settle);
    return CallToolResult(
      content: [
        await _shot(device, 0.4),
        TextContent(text: formatTree(await device.request('tree'))),
      ],
    );
  });

  static final _waitForTool = Tool(
    name: 'wait_for',
    description:
        'Waits until text appears on screen (or, with gone, disappears), in '
        'any window. Matches element text and descriptions, case-insensitive.',
    inputSchema: Schema.object(
      properties: {
        'text': Schema.string(),
        'gone': Schema.bool(description: 'Wait for it to disappear instead.'),
        'timeout_ms': Schema.int(description: 'Default 10000.'),
      },
      required: ['text'],
    ),
  );

  Future<CallToolResult> _waitFor(CallToolRequest request) => _run(() async {
    final device = await (await _current()).device();
    final args = request.arguments!;
    final wanted = (args['text'] as String).toLowerCase();
    final gone = args['gone'] == true;
    final deadline = DateTime.now().add(
      Duration(milliseconds: (args['timeout_ms'] as int?) ?? 10000),
    );
    while (true) {
      final tree = await device.request('tree');
      final shown = treeTexts(
        tree,
      ).any((t) => t.toLowerCase().contains(wanted));
      if (shown != gone) return _text(formatTree(tree));
      if (DateTime.now().isAfter(deadline)) {
        throw _ToolFailure(
          '"${args['text']}" is ${gone ? 'still' : 'not'} on screen.\n'
          '${formatTree(tree)}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  });

  // ---- Logs ----

  static final _logsTool = Tool(
    name: 'logs',
    description:
        "The app's native log (logcat threadtime lines), including Dart "
        'print output (tag flutter) and Kotlin/Java stack traces. Starts with '
        'the recent past; after the first call it keeps collecting.',
    inputSchema: Schema.object(
      properties: {
        'lines': Schema.int(description: 'Most recent lines (default 100).'),
        'grep': Schema.string(description: 'Only lines matching this regex.'),
      },
    ),
  );

  Future<CallToolResult> _logs(CallToolRequest request) => _run(() async {
    final tail = await (await _current()).logs();
    final args = request.arguments ?? const {};
    final grep = args['grep'] as String?;
    final pattern = grep == null ? null : RegExp(grep);
    final lines = tail.lines
        .where((line) => pattern == null || pattern.hasMatch(line))
        .toList();
    final count = (args['lines'] as int?) ?? 100;
    return _text(
      lines.skip(lines.length > count ? lines.length - count : 0).join('\n'),
    );
  });

  static final _errorsTool = Tool(
    name: 'errors',
    description:
        'Errors from the log: Flutter exception reports, error and fatal '
        'lines (native crashes included), and why the previous process '
        'ended (rhr-exit).',
    inputSchema: Schema.object(
      properties: {
        'lines': Schema.int(description: 'Most recent lines (default 200).'),
      },
    ),
  );

  Future<CallToolResult> _errors(CallToolRequest request) => _run(() async {
    final tail = await (await _current()).logs();
    final errors = errorLines(tail.lines);
    final count = (request.arguments?['lines'] as int?) ?? 200;
    // Why the previous process ended is the first line of the stream, and
    // the one most worth keeping.
    final exits = errors.where((l) => l.startsWith('rhr-exit '));
    final rest = errors.where((l) => !l.startsWith('rhr-exit ')).toList();
    final recent = rest.skip(rest.length > count ? rest.length - count : 0);
    return _text(
      errors.isEmpty
          ? 'No errors in the log.'
          : [...exits, ...recent].join('\n'),
    );
  });

  // ---- Dart ----

  static final _evaluateTool = Tool(
    name: 'evaluate',
    description:
        "Evaluates a Dart expression in the app's root library and returns "
        'its toString(). Needs the session\'s flutter attach running.',
    inputSchema: Schema.object(
      properties: {'expression': Schema.string()},
      required: ['expression'],
    ),
  );

  Future<CallToolResult> _evaluate(CallToolRequest request) => _run(() async {
    final session = await _current();
    final vm = await session.vmService();
    final isolate = await session.mainIsolate();
    final library = isolate.rootLib?.id;
    if (library == null) throw _ToolFailure('The app has no root library.');
    final result = await answered(
      vm.evaluate(
        isolate.id!,
        library,
        request.arguments!['expression'] as String,
      ),
      const Duration(seconds: 30),
    );
    return _text(await _describeValue(vm, isolate.id!, result));
  });

  Future<String> _describeValue(
    VmService vm,
    String isolate,
    Response value,
  ) async {
    switch (value) {
      case ErrorRef(:final message):
        throw _ToolFailure(message ?? 'The expression threw.');
      case InstanceRef(:final valueAsString?, :final valueAsStringIsTruncated):
        return valueAsStringIsTruncated == true
            ? '$valueAsString…'
            : valueAsString;
      case InstanceRef(:final id?, :final classRef):
        final text = await answered(
          vm.evaluate(isolate, id, 'toString()'),
          const Duration(seconds: 10),
        );
        if (text case InstanceRef(:final valueAsString?)) return valueAsString;
        return 'an instance of ${classRef?.name}';
      case Sentinel(:final valueAsString):
        return '<$valueAsString>';
      default:
        return '$value';
    }
  }

  static final _hotReloadTool = Tool(
    name: 'hot_reload',
    description:
        'Hot reloads the edited Dart code into the app, keeping its state. '
        'Returns what Flutter printed, compile errors included.',
    inputSchema: Schema.object(),
  );

  Future<CallToolResult> _hotReload(CallToolRequest request) =>
      _sessionCommand('reload');

  static final _hotRestartTool = Tool(
    name: 'hot_restart',
    description:
        "Hot restarts the app with the edited Dart code; the app's state "
        'resets. Returns what Flutter printed.',
    inputSchema: Schema.object(),
  );

  Future<CallToolResult> _hotRestart(CallToolRequest request) =>
      _sessionCommand('restart');

  static final _installAgentTool = Tool(
    name: 'install_agent',
    description:
        'Installs RHR Agent, which provides device control, on the phone. The '
        'tester confirms the install, then turns the agent on in the '
        "phone's Accessibility settings; ask them to. Waits up to 10 minutes "
        'for the install.',
    inputSchema: Schema.object(),
  );

  Future<CallToolResult> _installAgent(CallToolRequest request) =>
      _sessionCommand('install_agent');

  Future<CallToolResult> _sessionCommand(String command) => _run(() async {
    final answer = await sendSessionCommand(project, command);
    if (answer == null) {
      throw _ToolFailure('No rhr session is running for $project.');
    }
    if (!answer.ok) throw _ToolFailure(answer.message);
    return _text(answer.message);
  });

  // ---- Plumbing ----

  Future<ImageContent> _shot(DeviceControl device, double scale) async {
    final shot = await device.request('screenshot', {'scale': scale});
    return ImageContent(
      data: shot['data'] as String,
      mimeType: shot['mime'] as String,
    );
  }

  /// Turns expected failures into a tool error the agent can read.
  Future<CallToolResult> _run(Future<CallToolResult> Function() tool) async {
    try {
      return await tool();
    } on _ToolFailure catch (e) {
      return _error(e.message);
    } on DeviceControlException catch (e) {
      return _error('${e.message} (${e.code})');
    } on RPCError catch (e) {
      return _error('Dart VM: ${e.details ?? e.message}');
    } on SocketException catch (e) {
      return _error(
        'Could not reach the rhr session (${e.message}). It may have ended; '
        'check the terminal running rhr.',
      );
    }
  }
}

/// [call], or a failure that says why an app stops answering: Android
/// freezes an app that is not in front (Samsung within a minute or two), and
/// its VM service answers nothing until it is back.
Future<T> answered<T>(Future<T> call, Duration timeout) => call.timeout(
  timeout,
  onTimeout: () => throw _ToolFailure(
    'The app did not answer within ${timeout.inSeconds} s. If it is not in '
    'front, Android may have frozen it: bring it back with launch_app, then '
    'try again.',
  ),
);

CallToolResult _text(String text) =>
    CallToolResult(content: [TextContent(text: text)]);

CallToolResult _error(String text) =>
    CallToolResult(content: [TextContent(text: text)], isError: true);

final class _ToolFailure implements Exception {
  _ToolFailure(this.message);
  final String message;
}

const _instructions = '''
rhr drives a tester's Android phone running a Flutter app, over the internet,
through the developer's running rhr session (start `rhr run` first).

Loop: describe (or screenshot) to see the screen, then tap/swipe/type using the
tap points from describe; each action returns the screen after it. Coordinates
are fractions of the screen, 0 to 1. System permission dialogs are ordinary
windows: describe lists their buttons and tap presses them.

After editing Dart code, hot_reload (state kept) or hot_restart (state reset);
compile errors come back in the result. Use logs and errors for native and
Dart output, and evaluate to read app state. Call status when something fails.

Android freezes the app within a minute or two of leaving the front (for
example while you work in Settings). evaluate and hot reload need it back in
front: launch_app with its package (status shows it) first.
''';

/// One published session: its endpoints and the connections opened to them.
final class _Session {
  _Session(this.endpoints);

  final SessionEndpoints endpoints;
  DeviceControl? _device;
  LogTail? _logs;
  VmService? _vm;

  Future<DeviceControl> device() async {
    final open = _device;
    if (open != null && !open.isClosed) return open;
    return _device = await DeviceControl.connect(
      endpoints.device,
      endpoints.token,
    );
  }

  Future<LogTail> logs() async {
    final open = _logs;
    if (open != null && !open.isClosed) return open;
    final tail = _logs = await LogTail.connect(endpoints.logs, endpoints.token);
    // The recent past arrives in a burst as soon as the stream opens.
    await tail.settled();
    return tail;
  }

  Future<VmService> vmService() async {
    final open = _vm;
    if (open != null) return open;
    final ws = endpoints.vm.replace(
      scheme: 'ws',
      path: '${endpoints.vm.path.replaceFirst(RegExp(r'/$'), '')}/ws',
    );
    final vm = await answered(
      vmServiceConnectUri(ws.toString()),
      const Duration(seconds: 10),
    );
    _vm = vm;
    unawaited(vm.onDone.then((_) => _vm = null));
    return vm;
  }

  /// The app's isolate. Looked up on every call: a hot restart replaces it.
  Future<Isolate> mainIsolate() async {
    final vm = await vmService();
    final isolates =
        (await answered(vm.getVM(), const Duration(seconds: 10))).isolates ??
        const [];
    final main = isolates.firstWhere(
      (i) => i.isSystemIsolate != true && i.name == 'main',
      orElse: () => isolates.firstWhere(
        (i) => i.isSystemIsolate != true,
        orElse: () => throw StateError('The app has no Dart isolate running.'),
      ),
    );
    return answered(vm.getIsolate(main.id!), const Duration(seconds: 10));
  }

  Future<void> close() async {
    _device?.close();
    _logs?.close();
    await _vm?.dispose();
  }
}

/// The phone's log stream for this app, kept as a bounded tail.
final class LogTail {
  LogTail._(this._socket) {
    _socket.done.catchError((_) {});
    _socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _add,
          onDone: () => isClosed = true,
          onError: (_) => isClosed = true,
        );
  }

  static const capacity = 5000;

  final Socket _socket;
  final _lines = ListQueue<String>();
  var _lastLine = DateTime.now();
  var isClosed = false;

  static Future<LogTail> connect(int port, String token) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    socket.write('$token\n');
    return LogTail._(socket);
  }

  Iterable<String> get lines => _lines;

  void _add(String line) {
    _lastLine = DateTime.now();
    _lines.add(line);
    if (_lines.length > capacity) _lines.removeFirst();
  }

  /// Waits for the opening burst to finish: 300 ms without a line, or 3 s.
  Future<void> settled() async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (!isClosed && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (_lines.isNotEmpty &&
          DateTime.now().difference(_lastLine) >
              const Duration(milliseconds: 300)) {
        return;
      }
    }
  }

  void close() {
    isClosed = true;
    _socket.destroy();
  }
}

/// The device tree as text an agent reads cheaply: one line per element,
/// indented by nesting, with its tap point.
String formatTree(Map<String, dynamic> tree) {
  final out = StringBuffer();
  for (final window in (tree['windows'] as List).cast<Map<String, dynamic>>()) {
    out.write('window ${window['type']} ${window['package']}');
    if (window['title'] case final String title) out.write(' "$title"');
    if (window['active'] == true) out.write(' (active)');
    out.writeln();
    void node(Map<String, dynamic> n, int depth) {
      out.write('  ' * depth);
      out.write(n['class'] ?? '?');
      if (n['text'] case final String text) out.write(' "$text"');
      if (n['description'] case final String d) out.write(' desc="$d"');
      if (n['id'] case final String id) out.write(' id=$id');
      if (n['flags'] case final List flags) out.write(' [${flags.join(', ')}]');
      if (n['frame'] case [
        final num x,
        final num y,
        final num w,
        final num h,
      ]) {
        out.write(' tap=(${_round(x + w / 2)}, ${_round(y + h / 2)})');
      }
      out.writeln();
      for (final child in (n['children'] as List? ?? const [])) {
        node(child as Map<String, dynamic>, depth + 1);
      }
    }

    for (final n in (window['nodes'] as List).cast<Map<String, dynamic>>()) {
      node(n, 1);
    }
  }
  return out.toString().trimRight();
}

/// Every text and description in the device tree.
Iterable<String> treeTexts(Map<String, dynamic> tree) sync* {
  Iterable<String> node(Map<String, dynamic> n) sync* {
    if (n['text'] case final String text) yield text;
    if (n['description'] case final String d) yield d;
    for (final child in (n['children'] as List? ?? const [])) {
      yield* node(child as Map<String, dynamic>);
    }
  }

  for (final window in (tree['windows'] as List).cast<Map<String, dynamic>>()) {
    for (final n in (window['nodes'] as List).cast<Map<String, dynamic>>()) {
      yield* node(n);
    }
  }
}

String _round(num value) => ((value * 1000).round() / 1000).toString();

/// The error-worthy lines of a logcat threadtime tail: error and fatal
/// priority, the whole of each Flutter exception report (which Flutter prints
/// at info priority, between rules of ═), and the beacon's rhr-exit line.
List<String> errorLines(Iterable<String> lines) {
  final threadtime = RegExp(r'^\S+ \S+\s+\d+\s+\d+ ([VDIWEF]) ');
  final errors = <String>[];
  var inReport = false;
  for (final line in lines) {
    if (line.contains('EXCEPTION CAUGHT BY')) inReport = true;
    final priority = threadtime.firstMatch(line)?.group(1);
    if (inReport ||
        priority == 'E' ||
        priority == 'F' ||
        line.startsWith('rhr-exit ')) {
      errors.add(line);
    }
    if (inReport &&
        !line.contains('EXCEPTION CAUGHT BY') &&
        RegExp(r'═{10,}$').hasMatch(line)) {
      inReport = false;
    }
  }
  return errors;
}
