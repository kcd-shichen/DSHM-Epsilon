import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// S2：原生 Termux 终端的字节通道。
///
/// 分工很清楚——**字节的唯一来源仍然是 Dart 侧的状态机**（`terminal_state.dart` 拿到的
/// `TerminalSnapshot` / `TerminalOutput`），这里只做两件事：
///
/// * [write]：把状态机收到的每一段输出转发给已经挂上的原生视图；
/// * 反向：原生视图把按键产生的字节通过 `input` 事件送回来，由调用方交给 `send()`。
///
/// 两边用 `dsh/terminal/<tabId>` 这条 channel 对上，id 沿用终端 tab 的 id，
/// 所以一个页面开多个 tab 也不会串。
///
/// 缓冲：视图是在快照之后才创建的，先到的字节攒在 [_pending] 里，挂载时整段回放，
/// 否则第一次进终端会看到半屏。
class NativeTerminal {
  const NativeTerminal._();

  /// 编译期开关，和 `terminal_screen.dart` 里的分支是同一个常量。
  static const bool enabled = bool.fromEnvironment('DSH_NATIVE_TERM');

  static const String viewType = 'dsh/terminal';

  static String channelName(String id) => '$viewType/$id';

  static final Map<String, void Function(String)> _sinks = {};
  static final Map<String, StringBuffer> _pending = {};

  /// 状态机吐出来的每一段输出都会过这里。
  static void write(String id, String data) {
    if (!enabled || data.isEmpty) return;
    final sink = _sinks[id];
    if (sink != null) {
      sink(data);
      return;
    }
    (_pending[id] ??= StringBuffer()).write(data);
  }

  /// 原生视图挂上之后调用；缓冲里攒着的整段会先回放。
  static void attach(String id, void Function(String data) sink) {
    if (!enabled) return;
    _sinks[id] = sink;
    final buffered = _pending.remove(id);
    if (buffered != null && buffered.isNotEmpty) sink(buffered.toString());
  }

  static void detach(String id) {
    _sinks.remove(id);
  }
}

/// 把原生 `TerminalView` 挂进 Flutter 的那块。
///
/// 它自己算行列（原生侧按自己的字号与像素宽高算），算出来通过 `resized` 事件告诉宿主，
/// 由宿主去 resize 远端的 pty；输入则走 `input` 事件。Flutter 这边不持有
/// `TextInputClient`，输入法由原生 `TerminalView` 自己的 `InputConnection` 承担——
/// 这正是 ④ 那条 bug 的根治点。
class NativeTerminalView extends StatefulWidget {
  const NativeTerminalView({
    super.key,
    required this.id,
    required this.onInput,
    required this.onResize,
  });

  final String id;
  final void Function(String data) onInput;
  final void Function(int cols, int rows) onResize;

  @override
  State<NativeTerminalView> createState() => _NativeTerminalViewState();
}

class _NativeTerminalViewState extends State<NativeTerminalView> {
  late final MethodChannel _channel = MethodChannel(NativeTerminal.channelName(widget.id));

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler(_onCall);
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    NativeTerminal.detach(widget.id);
    super.dispose();
  }

  Future<void> _onCall(MethodCall call) async {
    final args = call.arguments;
    switch (call.method) {
      case 'input':
        final encoded = args is Map ? args['data'] as String? : null;
        if (encoded == null) return;
        widget.onInput(utf8.decode(base64Decode(encoded)));
      case 'resized':
        if (args is! Map) return;
        final cols = args['cols'] as int?;
        final rows = args['rows'] as int?;
        if (cols == null || rows == null) return;
        widget.onResize(cols, rows);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return const SizedBox.shrink();
    }
    return AndroidView(
      viewType: NativeTerminal.viewType,
      creationParams: <String, Object?>{'id': widget.id},
      creationParamsCodec: const StandardMessageCodec(),
      // 终端自己处理滚动/长按/选择，让原生视图直接吃掉所有手势。
      gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
        Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
      },
      onPlatformViewCreated: (int viewId) {
        NativeTerminal.attach(widget.id, (String data) {
          _channel.invokeMethod<void>('write', <String, Object?>{
            'data': base64Encode(utf8.encode(data)),
          });
        });
      },
    );
  }
}
