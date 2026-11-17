import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';

import '../ui/terminal/terminal_palette.dart';

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

  /// T22：顶部渐隐的高度（dp）。终端从胶囊下方起排，这一层把最顶上一条化成背景色，
  /// 文字滚到那儿就淡出去。遮罩只能画在平台视图内部——Flutter 那层画上去会把它盖掉。
  ///
  /// 32dp ≈ 一行半：原来 20dp 只够把第一行的上半截抹掉，看上去像被切了一刀。
  /// 前提是顶上那条带子和终端同色（`terminal_page` 里铺的那层），否则羽化到透明
  /// 之后露出的还是另一种底色，接缝反而更明显。
  static const double veilFeather = 32;

  /// T17：字号（dp）。终端设置菜单里改，改完立刻下发到所有已挂载的终端视图。
  /// 不做双指缩放——平台视图把 Dart 手势吃掉，原生那套又会在捏合时反复回缩。
  static final ValueNotifier<double> fontDp = ValueNotifier<double>(14);

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

  /// 只有当前登记的就是这个 sink 时才摘掉。
  ///
  /// 之前是无条件 remove：平台视图一旦被重建（布局变化、页面重建都会触发），
  /// 新视图先 attach、旧视图后 dispose，顺序一颠倒就把**新**的 sink 删了——
  /// 于是输出全部落进 [_pending] 再也不出来，屏幕全黑、打字有去无回。
  /// 这正是 T21 的成因。
  static void detach(String id, [void Function(String)? sink]) {
    if (sink == null) {
      _sinks.remove(id);
      return;
    }
    if (identical(_sinks[id], sink)) _sinks.remove(id);
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

  /// 这个视图实例的写入端。存成字段而不是每次新建闭包，
  /// 这样 [NativeTerminal.detach] 能认出"摘的是不是自己"（见 detach 的注释）。
  late final void Function(String) _sink = (String data) {
    _channel.invokeMethod<void>('write', <String, Object?>{
      'data': base64Encode(utf8.encode(data)),
    });
  };

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler(_onCall);
    NativeTerminal.fontDp.addListener(_pushStyle);
  }

  @override
  void dispose() {
    NativeTerminal.fontDp.removeListener(_pushStyle);
    _channel.setMethodCallHandler(null);
    NativeTerminal.detach(widget.id, _sink);
    super.dispose();
  }

  /// T17：外观三件套 + 顶部渐隐，一次下发。
  ///
  /// 终端是 Android 平台视图，Dart 侧的 `TerminalPalette` / 字体 / 字号在原生分支
  /// 一律不生效（T17 就是这么记的）。所以颜色取 palette、字体取 AppType.monoFamily
  /// 的那份 ttf，全都交给原生去应用。
  ///
  /// 只在创建回调里调，那时原生的 channel handler 已经挂好。
  void _pushStyle() {
    final palette = TerminalPalette.of(context);
    _channel.invokeMethod<void>('style', <String, Object?>{
      'fontSize': NativeTerminal.fontDp.value,
      // 终端仍铺满整宽，只是文字行两侧各留 10dp（不是把视图挤窄）。
      'sideInset': 10.0,
      'background': palette.background.toARGB32(),
      'foreground': palette.foreground.toARGB32(),
      'cursor': palette.accent.toARGB32(),
      'veilSolid': 0.0,
      'veilFeather': NativeTerminal.veilFeather,
    });
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
      // T16：选择模式里的复制 / 粘贴。
      case 'copy':
        final text = args is Map ? args['text'] as String? : null;
        if (text == null || text.isEmpty) return;
        await Clipboard.setData(ClipboardData(text: text));
      case 'paste':
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        final text = data?.text;
        if (text == null || text.isEmpty) return;
        // 多行先问一句。bracketed paste 能挡住 bash 5.1+，但 sh / 老 bash /
        // 任何没开 DECSET 2004 的程序照样逐行执行——那是协议边界，不是我们能改的。
        if (text.contains('\n') && mounted) {
          final lines = '\n'.allMatches(text).length + 1;
          final ok = await showDialog<bool>(
            context: context,
            builder: (BuildContext c) => AlertDialog(
              title: const Text('粘贴多行'),
              content: Text('这段内容有 $lines 行。终端没开 bracketed paste 时会逐行执行。'),
              actions: <Widget>[
                TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('取消')),
                FilledButton(onPressed: () => Navigator.of(c).pop(true), child: const Text('粘贴')),
              ],
            ),
          );
          if (ok != true) return;
        }
        // 交给原生走 emulator.paste()：剥 ESC/C1、规整换行、必要时套 bracketed 标记。
        await _channel.invokeMethod<void>('pasteText', <String, Object?>{'text': text});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return const SizedBox.shrink();
    }
    // 键栏已经搬到平台视图内部（原生 `buildKeyRow`），所以这里只剩终端本身。
    // 少一层 Flutter 子树 = 键盘升起时不用再让整条键栏跟着重建。
    return Column(
      children: <Widget>[
        Expanded(
          child: PlatformViewLink(
            viewType: NativeTerminal.viewType,
            surfaceFactory: (BuildContext context, PlatformViewController controller) {
              return AndroidViewSurface(
                controller: controller as AndroidViewController,
                hitTestBehavior: PlatformViewHitTestBehavior.opaque,
                gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
                  Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
                },
              );
            },
            onCreatePlatformView: (PlatformViewCreationParams params) {
              // 必须用 hybrid（surface/expensive）而不是普通 AndroidView。
              // `AndroidView` 走的是 `PlatformViewsService.initAndroidView` —— 虚拟显示模式，
              // 视图不在真实视图树里，**输入法挂不上去**：`showSoftInput` 会被静默忽略。
              // 这是 S2 第一版"点终端永远不出键盘"的根因。
              final AndroidViewController controller = PlatformViewsService.initSurfaceAndroidView(
                id: params.id,
                viewType: NativeTerminal.viewType,
                layoutDirection: TextDirection.ltr,
                creationParams: <String, Object?>{'id': widget.id},
                creationParamsCodec: const StandardMessageCodec(),
                onFocus: () => params.onFocusChanged(true),
              );
              controller.addOnPlatformViewCreatedListener(params.onPlatformViewCreated);
              controller.addOnPlatformViewCreatedListener((int viewId) {
                NativeTerminal.attach(widget.id, _sink);
                _pushStyle();
              });
              controller.create();
              return controller;
            },
          ),
        ),
      ],
    );
  }
}
