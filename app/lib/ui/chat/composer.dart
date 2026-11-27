// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.
// Local changes: chrome-tier glass with a 28 radius; a solid primary send
// key; model picking lives in the header chip; one send action, since DSH
// queues prompts sent mid-turn.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../state/swipe_guard.dart';
import '../common/expand_reveal.dart';
import '../common/pressable.dart';
import '../common/smooth_size.dart';
import '../fx/voice_glow/voice_beam.dart';
import '../pets/pet_perch.dart';
import '../settings/voice_settings_page.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'voice/voice_controller.dart';
import 'voice/voice_widgets.dart';
import 'widgets/quote_chip.dart' show ClosingTrayChild;

/// The editor's line height, as a multiple of its font size.
const _lineHeight = 1.45;

/// 输入条:chrome 玻璃 + 28 圆角,1–6 行自动增高,右下角发送 / 停止。
///
/// 两颗 36 圆键是胶囊的"端盖":四周都留 [_keyGap],单行时胶囊高 48、
/// 圆角 28 = 键半径 20 + 8,圆键与胶囊两端同心;文字在 40 高里居中。
/// 多行时键贴底,底边和侧边仍是 8。
///
/// 语音([voice]):草稿为空时发送键是麦克风(和 ＋ 键同样的淡底圆);
/// 听写时 ＋ 换成 ✕(取消)、发送键换成主色的停止键,中间文字处显示
/// 识别结果,停止键左边是音量条。四颗键始终同一位置、同一尺寸。
class Composer extends StatefulWidget {
  const Composer({
    super.key,
    this.footer,
    this.openValue,
    this.keyboardInset = 0,
    this.blurBackdrop = true,
    required this.controller,
    required this.connected,
    required this.running,
    required this.onSend,
    required this.onStop,
    this.focusNode,
    this.groupId = EditableText,
    this.busy = false,
    this.stopping = false,
    this.sessionReady = true,
    this.accessory,
    this.leading,
    this.tray,
    this.hasAttachments = false,
    this.onSendOptions,
    this.voice,
    this.onKeyEvent,
    this.placeholder,
    this.waiting = false,
    this.waitHint,
    this.modeLabel,
    this.onContentInserted,
    this.maxLines = 6,
    this.hardwareEnterSends = false,
    this.sendWhenEmpty = false,
    this.emptySendLabel,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;

  /// The text field and its attached controls share this tap region.
  final Object groupId;

  /// 已连上 DSH。没连上时可以先打字,但发不出去。
  final bool connected;

  /// 本轮正在生成:输入为空时发送键变成停止键。
  final bool running;

  /// 正在建会话 / 提交中:挡住连点。
  final bool busy;

  /// Stop was asked for: the stop key turns busy until the turn ends.
  final bool stopping;

  /// Ordinary send/stop controls require an applied session snapshot.
  final bool sessionReady;
  final VoidCallback onSend;
  final VoidCallback onStop;

  /// 发送键左边的小件(上下文环),40dp 高,底对齐。
  final Widget? accessory;

  /// 输入框左边的 40dp 件(＋ 附件)。
  final Widget? leading;

  /// 输入框上方的一条(引文、待发送的附件):出现时展开,拿掉时收起。
  final Widget? tray;

  /// 有附件时,没有文字也能发送。
  final bool hasAttachments;

  /// 长按发送键:生成中可选插话 / 停下先处理 / 排队。
  final VoidCallback? onSendOptions;

  /// 语音输入;null 或不可用时没有麦克风。
  final VoiceInputController? voice;

  /// Hardware keys in the text field first go here (the `@` picker's
  /// arrows / Enter / Esc).
  final FocusOnKeyEventCallback? onKeyEvent;

  /// The idle hint (「给 Chief 发消息…」 in a Bot chat); 「给 DSH 发消息…」
  /// by default.
  final String? placeholder;

  /// An approval or a question is waiting: the stop key steps back (the
  /// card's button is the one primary key) and the hint stops saying the
  /// turn is generating.
  final bool waiting;

  /// What the placeholder says while [waiting] (「等你回答」); null keeps the
  /// plain one.
  final String? waitHint;

  /// Persistent send intent, separate from the placeholder that typing hides.
  final String? modeLabel;

  /// Images from the keyboard (screenshots, stickers); null takes none.
  final ValueChanged<KeyboardInsertedContent>? onContentInserted;

  /// Visible editor lines. Multiline text remains scrollable when limited.
  final int maxLines;

  /// Opt-in physical Enter-to-send; never changes the software IME action.
  final bool hardwareEnterSends;

  /// An empty box sends too (the tavern: the character speaks next). The key
  /// is drawn quietly then, and labelled [emptySendLabel]; the mic, when
  /// there is one, still comes first.
  final bool sendWhenEmpty;
  final String? emptySendLabel;

  /// Shown beside the keys while the field is being typed in: the capsule opens into a
  /// rounded rectangle, the text on a line of its own and the keys and this in a row
  /// below. It closes again when the keyboard goes. Null: the capsule stays as it is.
  final Widget? footer;

  /// 把 `_open`（0 收起 / 1 键盘全开）递给外面：胶囊行最后一颗环靠它往左缩，
  /// 和输入条同一个节拍（He 2026-11-25 定的衔接）。
  final ValueNotifier<double>? openValue;

  /// The keyboard's height, from a page that still knows it: how [footer] tells the
  /// keyboard going down from the field losing focus.
  final double keyboardInset;

  /// 玻璃要不要采样背景。
  ///
  /// 输入条底下没有壁纸时，那儿是一块被渐变压平的背景色——采样出来的东西和直接
  /// 填色一模一样，却仍要每帧开一次离屏、跑一遍滤镜（He 2026-11-27 看出来的：
  /// "碰到消息时已经是背景色了"）。有壁纸时才真的需要它。
  final bool blurBackdrop;

  /// Editor lines for a page whose [pageContext] still carries the keyboard
  /// inset: six, or as many as fit in two fifths of the height above the
  /// keyboard at the current text size, never under two (two keep newlines
  /// and the field's own scrolling). A phone on its side with the keyboard
  /// up, or very large text, would otherwise push the chat to nothing; an
  /// upright phone under a tall keyboard keeps six up to about 1.2× text.
  static int linesFor(BuildContext pageContext) {
    final available = MediaQuery.sizeOf(pageContext).height - MediaQuery.viewInsetsOf(pageContext).bottom;
    final line = MediaQuery.textScalerOf(pageContext).scale(_fontSize) * _lineHeight;
    if (line <= 0 || available <= 0) return 2;
    return (available * 0.4 / line).floor().clamp(2, 6);
  }

  @override
  State<Composer> createState() => _ComposerState();
}

const double _keySize = 36;
const double _keyGap = 6;

/// 收起、且没有 ⛶ 的那一态：照原版（1.4）四边 6，单行时整条 36 + 6×2 = 48，
/// 28 的圆角落在 48 上正好是完整胶囊（He 2026-11-27）。
const double _glassInsetClosed = 6.0;

/// 「小边距」这一档：**有 ⛶ 的收起态**和**键盘打开时**都用它，单行整条
/// 36 + 9×2 = 54。He 2026-11-27：比原来那档（11 / 58）小一圈，比原版（6 / 48）大一档。
///
/// 右栏从右下那颗圆长出来，它到上、右、下三条边的距离必须一样——所以这是一个数，
/// 不是三个（He 2026-11-22 定的规矩，换值不换规矩）。
const double _glassInsetSnug = 9.0;

/// 左边没有圆键时，原版文字从 18 起（比 6 再多躲一截）。
const double _textStartClosed = 18.0;

/// 放大键独占的那一条带子：一颗键 + 2 的缝（原版常驻，现在只有开键盘时才占）。
const double _magnifyBand = _keySize + 2;

/// 「1」和「2」之间那道缝。He 2026-11-24：9 —— 长条短一截，伸缩的路程也跟着少 9，
/// 时间还是 160ms / 同一条曲线，所以峰值速度低了、看着更柔。
const double _keySlot = 9;

/// The composer's own text, a step under body text.
const double _fontSize = 15.0;

class _ComposerState extends State<Composer> with TickerProviderStateMixin {
  Duration? _lastEscape;
  // Keep the editor and its input connection when the footer changes the layout.
  final _fieldKey = GlobalKey();
  late final _draftEmpty = ValueNotifier(widget.controller.text.trim().isEmpty);

  /// 草稿高过输入框的行数上限（[Composer.maxLines]）就会内部滚动，
  /// 那时才长出一颗「放大」键。判据见 [_measureField]：**按全开态的宽度**量这篇
  /// 草稿排出来有没有超过 [Composer.maxLines]——一个标准，与开合到哪一帧无关。
  late final _overflow = ValueNotifier(false);

  /// 输入框自己的滚动控制器（长草稿时它内部要滚）。
  final _fieldScroll = ScrollController();

  /// 文字占了几行（见 [_measureField]）：环到第 5 行就搬去 ＋ 上方。
  late final _lines = ValueNotifier(1);

  /// 草稿**超过一行**了（按这一帧排出来的高度量）。内距那一档跟它走，不跟 ⛶ 走
  /// （He 2026-11-27）。
  late final _wraps = ValueNotifier(false);

  /// 环还在行里的时候，文本能占多宽。他量到「一行最多 11 个中文字」，那是这颗字体在这个
  /// 宽度下的折行点 —— 所以判据用宽度，不数字数；环藏起来之后还要用这个数。
  double _narrowW = 0;

  /// 上一帧环是不是在行里（[_measureField] 只在那一帧记宽度）。
  bool _ringInRow = false;

  /// 一行还放得下环吗。每敲一个字都要重判，所以判在 [_measureField] 里；
  /// 变的那一下才通知，不是每个字都重建。
  late final _ringFits = ValueNotifier(true);

  /// 文字那一套样式：量的那边要用同一份，build 时记下来。
  TextStyle? _textStyle;

  /// 打字期间持有的横滑闸；失焦 / 销毁时还回去。
  SwipeHold? _typingHold;

  /// 撤回 / 重做。自己存快照，不依赖 Flutter 的 UndoHistory——
  /// 那个的历史栈住在 widget 的 State 里，全屏页一关就没了。
  late final _history = _DraftHistory(widget.controller);

  void _draftChanged() {
    _history.record();
    // trimLeft：只留左边空白时也算空（1.4 的改动），回车键不该亮。
    _draftEmpty.value = widget.controller.text.trimLeft().isEmpty;
    // 能不能滚得等这一帧排完版才知道。
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureField());
  }

  // One value for everything that moves when the composer opens: the corners, the text's
  // width, the height, the keys and the footer's fade. One motion, not several in step.
  late final AnimationController _openController = AnimationController(vsync: this, duration: AppMotion.collapse);
  late final Animation<double> _open = CurvedAnimation(parent: _openController, curve: AppMotion.collapseCurve);

  /// 「不是一行」的那一路（0 = 还是单行，1 = 已经折行）。内距跟着它走：
  /// 单行 48 / 内距 6，非一行 54 起 / 内距 9（He 2026-11-27）。
  ///
  /// 只看行数，不看 ⛶ —— ⛶ 是"超过 maxLines"之后的另一件事，它自己那一路淡入
  /// 还在 body 里那个 `TweenAnimationBuilder`，两者互不牵连。
  late final AnimationController _snugController = AnimationController(vsync: this, duration: AppMotion.quick);
  late final Animation<double> _snug = CurvedAnimation(parent: _snugController, curve: AppMotion.std);

  void _syncSnug() {
    if (!mounted) return;
    _snugController.duration = AppMotion.of(context, AppMotion.quick);
    if (_wraps.value) {
      if (!_snugController.isCompleted) unawaited(_snugController.forward());
    } else if (!_snugController.isDismissed) {
      unawaited(_snugController.reverse());
    }
  }

  /// 玻璃"停稳"进度：1 = 不动了，0 = 正在动。
  ///
  /// 会动的玻璃不该采样背景（`GlassSurface.settled` 就是为这个留的）：键盘升起、
  /// 输入条开合那 250ms 里，输入条在变高、底下的列表在滑，每帧重新采一次背景模糊
  /// 就是这段时间唯一的开销。停下来再渐显模糊，眼睛看不出来。
  late final _still = AnimationController(vsync: this, duration: AppMotion.glassIn, value: 1);
  Timer? _stillTimer;

  void _markMoving() {
    _stillTimer?.cancel();
    if (_still.value != 0) _still.value = 0;
    _stillTimer = Timer(const Duration(milliseconds: 90), () {
      if (mounted) unawaited(_still.forward());
    });
  }

  /// The keyboard went down with the field still focused.
  bool _keyboardDown = false;
  double _keyboardPeak = 0;

  void _syncOpen() {
    if (!mounted || widget.footer == null) return;
    // A page or sheet over it (the model sheet) takes the focus and the keyboard for a
    // moment: they come back with it, and the composer waits as it is.
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
    final open = (widget.focusNode?.hasFocus ?? false) && !_keyboardDown;
    _openController.duration = AppMotion.of(context, AppMotion.collapse);
    if (open && _openController.status != AnimationStatus.forward && !_openController.isCompleted) {
      _markMoving();
      unawaited(_openController.forward());
    } else if (!open && _openController.status != AnimationStatus.reverse && !_openController.isDismissed) {
      _markMoving();
      unawaited(_openController.reverse());
    }
  }

  void _focusChanged() {
    final focused = widget.focusNode?.hasFocus ?? false;
    // 焦点没了，弹窗肯定也没了：别让这个标记吃掉下一次点击。
    if (!focused) _menuUp = false;
    if (focused) _keyboardDown = false;
    // 打字的时候左右滑让路：否则想把光标往左挪半格会把抽屉拽出来。
    if (focused) {
      _typingHold ??= SwipeHold();
    } else {
      _typingHold?.release();
      _typingHold = null;
    }
    _syncOpen();
  }

  void _keyboardMoved(double before) {
    final inset = widget.keyboardInset;
    if (inset == before || !(ModalRoute.of(context)?.isCurrent ?? true)) return;
    _markMoving();
    if (inset > before) {
      _keyboardDown = false;
      if (inset > _keyboardPeak) _keyboardPeak = inset;
    } else if (inset < _keyboardPeak * 0.5) {
      // Most of the way down, so not the keyboard just changing height.
      _keyboardDown = true;
      _keyboardPeak = 0;
    }
    _syncOpen();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncOpen();
      // 键盘开合会改文本的宽度，折行数跟着变：重新量一次。
      _measureField();
    });
  }

  /// 选择弹窗（复制 / 全选 / 粘贴那条）现在是不是开着。
  /// 由 `contextMenuBuilder` 点着——它就是这个弹窗的唯一入口，不用去猜。
  bool _menuUp = false;

  /// 弹窗开着时框架会把 [EditableTextState] 交给我们；收它要用这个。
  EditableTextState? _fieldState;

  // 「收起时托盘还留着」不再自己存一份（原来是 _tray 字段）：1.4 把它做成
  // ClosingTrayChild 这个 widget，托盘跟着收起的动画一起退，比在 didUpdateWidget
  // 里留旧值干净。这里只用，不再持有。
  void _send() {
    if (!widget.connected || !widget.sessionReady || widget.busy) return;
    HapticFeedback.lightImpact();
    widget.onSend();
  }

  /// 全屏输入：把这条草稿铺满一屏，发送键搬到右上角并染强调色。
  ///
  /// 用一条独立路由而不是把输入条撑大——输入条那套 LayoutBuilder/自定义 RenderBox
  /// 是按"贴在底部的一小块玻璃"算的，撑成整屏要重排一堆东西；一个路由只借同一个
  /// controller，改动面小得多。期间压着横滑闸，免得手指往左划把抽屉拽出来。
  Future<void> _openFullscreen() async {
    final hold = SwipeHold();
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyLarge?.copyWith(fontSize: _fontSize, height: _lineHeight);
    final hint = widget.placeholder ?? context.l10n.chatComposerHint;
    final send = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        fullscreenDialog: true,
        builder: (_) => _ComposerFullscreen(controller: widget.controller, history: _history, style: style, hint: hint),
      ),
    );
    hold.release();
    if (send == true && mounted) _send();
  }

  void _stop() {
    if (!widget.connected || !widget.sessionReady || widget.busy || widget.stopping) return;
    HapticFeedback.mediumImpact();
    widget.onStop();
  }

  /// Hardware keyboards: Ctrl/⌘+Enter sends; optionally plain Enter does too.
  /// Shift+Enter remains a new line. IME composition never sends.
  /// Two consecutive Esc presses within 500 ms stop the turn. The pair is
  /// local to the focused, eligible editor; a single Esc never leaves it.
  KeyEventResult _hardwareKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final composing = widget.controller.value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      _lastEscape = null;
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.escape) _lastEscape = null;
    final sendEnter =
        keys.isControlPressed ||
        keys.isMetaPressed ||
        (widget.hardwareEnterSends && !keys.isShiftPressed && !keys.isAltPressed);
    if (sendEnter && (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter)) {
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      final draft = widget.controller.text.trim().isNotEmpty || widget.hasAttachments || widget.sendWhenEmpty;
      final dictating = widget.voice?.active ?? false;
      if (draft && widget.connected && !widget.busy && !dictating) _send();
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent) return KeyEventResult.ignored;
    if (key != LogicalKeyboardKey.escape || !widget.running) {
      _lastEscape = null;
      return KeyEventResult.ignored;
    }
    if (!widget.sessionReady || !widget.connected || widget.busy || widget.stopping) {
      _lastEscape = null;
      return KeyEventResult.handled;
    }
    final last = _lastEscape;
    _lastEscape = event.timeStamp;
    if (last != null && event.timeStamp - last <= const Duration(milliseconds: 500)) {
      _lastEscape = null;
      _stop();
    }
    return KeyEventResult.handled;
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_draftChanged);
    widget.voice?.onMessage = _voiceMessage;
    widget.focusNode?.addListener(_focusChanged);
    _open.addListener(_pushOpen);
    _wraps.addListener(_syncSnug);
    WidgetsBinding.instance.addPostFrameCallback((_) => _pushOpen());
  }

  /// 输入框排完版的事实：占了几行、能不能滚、以及在环还占着右边时它有多宽。
  /// 三个都从同一个 box 读，不另起一套量法。
  /// 把 `_open` 的当前值递给外面（胶囊行那颗环用它收）。
  void _pushOpen() {
    final out = widget.openValue;
    if (out != null && out.value != _open.value) out.value = _open.value;
  }

  void _measureField() {
    if (!mounted) return;
    final line = MediaQuery.textScalerOf(context).scale(_fontSize) * _lineHeight;
    final box = _fieldKey.currentContext?.findRenderObject();
    // 先把这一帧的能量全读完，最后才动 notifier：动任何一个都会把输入条标脏，
    // 之后再读 `context.size`（下面 ⛶ 的判据要用）就会撞上"尺寸不可用"的断言。
    final fieldSize = box is RenderBox && box.hasSize ? box.size : null;
    final width = context.size?.width;
    // 折没折行：内距那一档要它。
    //
    // 用这一帧排出来的高度判，不另算宽度：变窄只会让行数变多，
    // 所以"单行 → 收紧"和"收紧后仍是单行"不会来回摇。
    bool? wraps;
    if (fieldSize != null) {
      final textPad = math.max(4.0, (_keySize - line) / 2);
      final rows = ((fieldSize.height - 2 * textPad) / line).round().clamp(1, widget.maxLines);
      wraps = rows > 1;
    }
    if (fieldSize != null && box is RenderBox && box.hasSize) {
      // 这两个数只有「行里有环」的时候才有人看；没有环就别为它们重建输入条
      // （打字不该把 chrome 弄脏，见 composer_rebuild_test）。
      if (widget.accessory != null) {
        final lines = (box.size.height / line).round().clamp(1, widget.maxLines);
        if (lines != _lines.value) {
          _lines.value = lines;
        }
        if (_ringInRow) _narrowW = box.size.width;
        final fits = _fitsBesideRing(_textStyle);
        if (fits != _ringFits.value) _ringFits.value = fits;
      }
    }
    // ⛶ 的判据：**按全开态的宽度算**，与当前开合到哪一帧无关（He 2026-11-26）。
    // 以前是两态各看各的 `maxScrollExtent`：收起时文本窄、行数多，一开键盘文本变宽、
    // 行数变少，判据就在动画中间翻脸——⛶ 凭空出现/消失，连带那条带子的高度、
    // 箭头键的落点、文字重排一起跳一下。现在只有一个标准，两种状态算出同一个答案。
    if (width != null) {
      // 全开态文字拿到的宽度：内容宽（去掉玻璃两边的小边距 9）再减左右各 8。
      final openWidth = math.max(0.0, width - 2 * _glassInsetSnug - 2 * _RenderComposerRows._inset);
      final painter = TextPainter(
        text: TextSpan(text: widget.controller.text, style: _textStyle),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: openWidth);
      final over = painter.height > widget.maxLines * line + 0.5;
      painter.dispose();
      if (over != _overflow.value) _overflow.value = over;
    }
    // 最后才动它：这一句会把输入条标脏。
    if (wraps != null && wraps != _wraps.value) _wraps.value = wraps;
  }

  /// 上一次算"环还挤不挤得下"时用的输入：文本 / 样式 / 环占的那格宽 / 字号缩放。
  /// 键盘动画那 280ms 里 `_measureField` 每帧都跑，而这个答案一次都不会变——
  /// 不缓存的话，整段草稿每帧被排一次**不限宽**的版，只为一个不变的结果。
  (String, TextStyle?, double, TextScaler)? _fitsKey;

  /// 上一次的结果（与 [_fitsKey] 配成一对）。
  bool _fitsValue = true;

  /// 这一行还放得下环吗：有环时文本只有 [_narrowW] 宽，一折行环就得让位给整行文本。
  bool _fitsBesideRing(TextStyle? style) {
    final text = widget.controller.text;
    if (text.isEmpty) return true;
    if (text.contains('\n')) return false;
    if (_narrowW <= 0) return true;
    final scaler = MediaQuery.textScalerOf(context);
    final key = (text, style, _narrowW, scaler);
    if (_fitsKey == key) return _fitsValue;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style ?? const TextStyle()),
      textDirection: Directionality.of(context),
      textScaler: scaler,
    )..layout();
    _fitsKey = key;
    _fitsValue = painter.width <= _narrowW;
    return _fitsValue;
  }

  @override
  void didUpdateWidget(Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_draftChanged);
      widget.controller.addListener(_draftChanged);
      _draftChanged();
    }
    if (oldWidget.sessionReady != widget.sessionReady ||
        oldWidget.connected != widget.connected ||
        oldWidget.running != widget.running ||
        oldWidget.controller != widget.controller ||
        oldWidget.focusNode != widget.focusNode ||
        oldWidget.busy != widget.busy ||
        oldWidget.stopping != widget.stopping) {
      _lastEscape = null;
    }
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode?.removeListener(_focusChanged);
      widget.focusNode?.addListener(_focusChanged);
    }
    if (oldWidget.keyboardInset != widget.keyboardInset) _keyboardMoved(oldWidget.keyboardInset);
    if ((oldWidget.footer == null) != (widget.footer == null)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncOpen());
    }
    if (oldWidget.voice != widget.voice) {
      if (oldWidget.voice?.onMessage == _voiceMessage) {
        oldWidget.voice?.onMessage = null;
      }
      widget.voice?.onMessage = _voiceMessage;
    }
  }

  @override
  void dispose() {
    _typingHold?.release();
    _typingHold = null;
    _history.dispose();
    _fieldScroll.dispose();
    _lines.dispose();
    widget.controller.removeListener(_draftChanged);
    _draftEmpty.dispose();
    widget.focusNode?.removeListener(_focusChanged);
    _open.removeListener(_pushOpen);
    _wraps.removeListener(_syncSnug);
    _wraps.dispose();
    _stillTimer?.cancel();
    _still.dispose();
    _snugController.dispose();
    _openController.dispose();
    if (widget.voice?.onMessage == _voiceMessage) {
      widget.voice?.onMessage = null;
    }
    super.dispose();
  }

  void _voiceMessage(VoiceMessage message) {
    if (!mounted) return;
    final voice = widget.voice;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message.text),
          persist: false,
          action: message.openSettings && voice != null
              ? SnackBarAction(label: appL10n.chatGoToSettings, onPressed: () => voice.bridge.openSettings())
              : message.change
              ? SnackBarAction(
                  label: appL10n.nearbyChange,
                  onPressed: () =>
                      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const VoiceSettingsPage())),
                )
              : null,
        ),
      );
  }

  void _startVoice() {
    final voice = widget.voice;
    if (voice == null) return;
    // Dictation shows the text in the field; the keyboard only covers it.
    (widget.focusNode ?? FocusManager.instance.primaryFocus)?.unfocus();
    voice.start();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final textStyle = theme.textTheme.bodyLarge?.copyWith(fontSize: _fontSize, height: _lineHeight);
    // One line centred in the keys' 40: the padding that makes it so, at
    // the current text size (very large text just grows the row).
    final line = MediaQuery.textScalerOf(context).scale(_fontSize) * _lineHeight;
    final textPad = math.max(4.0, (_keySize - line) / 2);
    _textStyle = textStyle;
    final voice = widget.voice;
    voice?.ensureFresh();
    final themeStyle = DshThemeStyle.of(context);
    final themeHint = themeStyle.localized(themeStyle.components.composerHint);

    // 行数 / 能不能滚 / 有环时文本多宽，都得等这一帧排完版才知道（见 `_measureField`）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureField());
    // The chat page's pet stands on the composer's top edge (outside a pet
    // stage this is a plain pass-through).
    return PetPerch(
      kind: PerchKind.composer,
      child: _ComposerGlass(
        open: widget.footer == null ? null : _open,
        still: _still,
        blur: widget.blurBackdrop,
        child: ListenableBuilder(
          // The editor listens to text, selection and composing changes itself.
          // Its surrounding controls only need the draft's empty/nonempty edge.
          listenable: Listenable.merge([_draftEmpty, _overflow, _lines, _ringFits, ?voice]),
          builder: (context, _) {
            final phase = voice?.phase ?? VoicePhase.idle;
            final dictating = phase == VoicePhase.listening || phase == VoicePhase.transcribing;
            final empty = _draftEmpty.value && !widget.hasAttachments;
            final showStop = widget.running && empty && !dictating;
            final showMic = !dictating && !showStop && empty && !widget.busy && (voice?.available ?? false);
            final enabled =
                !widget.busy && widget.connected && widget.sessionReady && (showStop || !empty || widget.sendWhenEmpty);
            final emptySend = empty && widget.sendWhenEmpty && !showStop && !showMic && !dictating;
            final waiting = widget.waiting || widget.waitHint != null;
            final hint = switch (phase) {
              VoicePhase.listening => l10n.chatListeningEllipsis,
              VoicePhase.transcribing => l10n.chatTranscribingEllipsis,
              _ =>
                !widget.connected
                    ? l10n.chatConnectToSend
                    : !widget.sessionReady
                    ? l10n.stateChatSynchronizing
                    : widget.waitHint ??
                          (widget.running && !waiting
                              ? l10n.chatGeneratingSteerHint
                              : widget.placeholder ?? themeHint ?? l10n.chatComposerHint),
            };
            final leading = dictating
                ? VoiceCancelKey(key: const ValueKey('voice-cancel'), onPressed: voice!.cancel)
                : widget.leading;
            final accessory = dictating
                ? VoiceWaveform(level: voice!.level, active: phase == VoicePhase.listening)
                : widget.accessory;

            final _KeyMode mode;
            if (dictating) {
              mode = _KeyMode.stopVoice;
            } else if (showStop) {
              mode = _KeyMode.stopRun;
            } else if (showMic) {
              mode = _KeyMode.mic;
            } else {
              mode = _KeyMode.send;
            }
            final keyBusy =
                widget.busy ||
                (showStop && widget.stopping) ||
                phase == VoicePhase.transcribing ||
                phase == VoicePhase.starting;

            final leadingKey = leading == null
                ? null
                : AnimatedSwitcher(
                    duration: AppMotion.of(context, AppMotion.quick),
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: anim,
                      child: ScaleTransition(scale: anim, child: child),
                    ),
                    child: KeyedSubtree(key: ValueKey(dictating), child: leading),
                  );
            final field = Focus(
              key: _fieldKey,
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: _hardwareKey,
              onFocusChange: (hasFocus) {
                if (!hasFocus) _lastEscape = null;
              },
              child: Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onKeyEvent: widget.onKeyEvent,
                child: TextField(
                  groupId: widget.groupId,
                  // 点输入条外面任意处收起光标（He 2026-11-25：官方版就是这样）。
                  // Android 上框架默认**不**这么做（editable_text.dart:6956），
                  // 而光标不走，`SwipeHold` 就一直握着，左右滑永远出不来。
                  // 用框架的 TapRegion 判定，不加手势、不加守卫。
                  // 建出来的东西和框架默认的一模一样（同一个 builder），
                  // 只是顺手记下"弹窗开着"和它的 state——收弹窗要用。
                  contextMenuBuilder: (context, editableTextState) {
                    _fieldState = editableTextState;
                    _menuUp = true;
                    return AdaptiveTextSelectionToolbar.editableText(editableTextState: editableTextState);
                  },
                  // 点外面分两段（He 2026-11-25 定的）：**先收弹窗，再收键盘**。
                  // 点外侧常常是为了关掉那条菜单，不是想收键盘——一次到位会打断思绪。
                  // "里/外"仍由 TapRegion 的分组决定（默认组，弹窗和手柄都在里面），
                  // 这里只管"外面这一下先干什么"。
                  onTapOutside: (_) {
                    if (_menuUp) {
                      _menuUp = false;
                      _fieldState?.hideToolbar();
                      // 弹窗和选区一起收（He 2026-11-25）：`hideToolbar()` 只收菜单和
                      // 手柄，高亮还留着——没有手柄也没有菜单的一块高亮，什么也做不了。
                      // 折叠到上次手势结束的那一端，光标落回去。
                      final selection = widget.controller.selection;
                      if (selection.isValid && !selection.isCollapsed) {
                        widget.controller.selection = TextSelection.collapsed(offset: selection.extentOffset);
                      }
                      return;
                    }
                    (widget.focusNode ?? FocusManager.instance.primaryFocus)?.unfocus();
                  },
                  controller: widget.controller,
                  focusNode: widget.focusNode,
                  scrollController: _fieldScroll,
                  contentInsertionConfiguration: switch (widget.onContentInserted) {
                    final onInserted? => ContentInsertionConfiguration(
                      onContentInserted: onInserted,
                      allowedMimeTypes: const ['image/png', 'image/jpeg', 'image/gif', 'image/webp'],
                    ),
                    null => null,
                  },
                  readOnly: dictating || phase == VoicePhase.starting,
                  minLines: 1,
                  maxLines: widget.maxLines,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  textCapitalization: TextCapitalization.sentences,
                  style: textStyle,
                  cursorColor: theme.colorScheme.primary,
                  decoration: InputDecoration(
                    hintText: hint,
                    hintMaxLines: 1,
                    hintStyle: theme.textTheme.bodyLarge?.copyWith(
                      fontSize: _fontSize,
                      color: dsh.textTertiary,
                      height: 1.45,
                    ),
                    filled: false,
                    isDense: true,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: textPad),
                  ),
                ),
              ),
            );
            // 这一颗键的"是不是麦克风样子""能不能按"。
            final keyQuiet = (showStop && waiting && !widget.stopping) || emptySend;
            final keyOn = switch (mode) {
              _KeyMode.mic => true,
              _KeyMode.stopVoice => phase == VoicePhase.listening,
              _ => enabled,
            };
            // 键**就是**那个形状：高度每帧由它自己的 `_open` 算（见下面的右栏），
            // 外面那层不再每帧重建这颗键。
            Widget sendKey() => _SendButton(
              mode: mode,
              busy: keyBusy,
              quiet: keyQuiet,
              sendLabel: emptySend ? widget.emptySendLabel : null,
              enabled: keyOn,
              onLongPress: mode != _KeyMode.send || !enabled ? null : widget.onSendOptions,
              onTap: () {
                switch (mode) {
                  case _KeyMode.stopRun:
                    _stop();
                  case _KeyMode.send:
                    _send();
                  case _KeyMode.mic:
                    _startVoice();
                  case _KeyMode.stopVoice:
                    voice?.stop();
                }
              },
            );
            final footer = widget.footer;
            final magnify = _overflow.value
                ? _MagnifyKey(key: const ValueKey('composer-magnify'), onPressed: _openFullscreen)
                : null;

            /// 环的三种落点（He 2026-11-23 在真机上量的）：
            ///   一行装得下 → 行里、↑ 左边（原样）；
            ///   放不下一行了 → 收起来，那一列整条让给文本；
            ///   超过 4 行 → 搬到 ＋ 上方那一列，竖排（环在上、`<1%` 在它下面居中）。
            // 行里那一格放的是上下文环，还是听写时的 ✕（听写时 accessory 换成了 ✕，那格不动）。
            final isRing = accessory != null && !dictating;
            // 落点只剩一个：行里、↑ 左边。收起时整格塌到 0（那半息交给胶囊行最后一颗），
            // 打开时回到原位——所以没有"三段"可跳了（He 2026-11-25 定的衔接）。
            final ringInRow = accessory != null && (!isRing || footer != null || _ringFits.value);
            // 那一格按 `_open` 收放：收键盘时它不占文本的宽度。
            //
            // 听写是例外：`_startVoice` 会主动收键盘（"键盘只挡着字"），如果这一格
            // 跟着收，听写时的波形就永远画不出来——上游没有这层收放，所以他们听写时
            // 波形一直在。这里让 dictating 直接铺开，其余状态仍按 `_open`。
            Widget ringSlot(Widget child) => dictating
                ? child
                : AnimatedBuilder(
                    animation: _open,
                    builder: (context, inner) {
                      final t = _open.value;
                      if (t <= 0.001) return const SizedBox.shrink();
                      return ClipRect(
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          widthFactor: t,
                          child: Opacity(opacity: t, child: inner),
                        ),
                      );
                    },
                    child: child,
                  );
            _ringInRow = isRing && footer == null && ringInRow;
            final row = footer == null
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (leadingKey != null) ...[leadingKey, const SizedBox(width: 8)],
                      Expanded(child: field),
                      const SizedBox(width: 8),
                      if (ringInRow) ...[ringSlot(accessory), const SizedBox(width: 2)],
                      // 键活在右栏那一层（它比这一行高），这里只留出它的位子。
                      const SizedBox.square(dimension: _keySize),
                    ],
                  )
                : _ComposerRows(
                    open: _open,
                    // A new line grows the glass here: opening is its own motion, with no
                    // second one chasing it.
                    text: SmoothSize(
                      duration: AppMotion.of(context, AppMotion.quick),
                      curve: AppMotion.std,
                      alignment: Alignment.bottomCenter,
                      child: field,
                    ),
                    leading: leadingKey ?? const SizedBox.shrink(),
                    footer: FadeTransition(opacity: _open, child: footer),
                    // Exactly a key tall, whatever sits beside the key: the row's height is
                    // what keeps the gaps around it even.
                    trailing: SizedBox(
                      height: _keySize,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (ringInRow) ...[ringSlot(accessory), const SizedBox(width: _keyGap)],
                          // 同上：键在右栏那一层，这里只占位。
                          const SizedBox.square(dimension: _keySize),
                        ],
                      ),
                    ),
                  );
            // 右栏 = **这颗键撑开的样子**，不是第二层装饰。宽 = 原圆直径（36），
            // 高度在 36 与整行之间插值、靠内容那侧的角 18 ↔ 6，靠边那侧的 18 不动；
            // 底边和右边钉死，所以它只会往上铺满，不会整条跳上来。
            // 这一层里只有一个东西：这颗键。没有第二层填充、没有第二个按压、也没有第二个命中区——
            // 看得见的那一条就是能点的那一条，上半截照样能点、能长按（He 2026-11-23）。
            // `split`：顶格那颗 ⛶ 占了多少（0 = 整条都是发送键）。
            // 栏的高度让出那一条 —— 那颗在的时候 2 从下面接着长，它自己不动（He 2026-11-23）。
            Widget rail(double split) => PositionedDirectional(
              top: 0,
              end: 0,
              bottom: 0,
              width: _keySize,
              // 高度在**布局**里给：这一列有多高，键就从 36 长到它（⛶ 占了上面
              // 那格时让出 45）。每帧只走一次 layout，widget 树一次都不重建
              // （2026-11-27 的 A/B：这颗键原来每帧重建 13 次）。
              child: _KeyRail(open: _open, split: split, child: sendKey()),
            );

            // The tray unfolds above the text and folds away again: the
            // glass grows and shrinks, the text row never jumps.
            final content = Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 放大键原来独占的那一条：只有开键盘时才长出来（收起时是 0 高，
                // 键落在下面文字区那一列的顶上）。原版这条是常驻的 38。
                if (magnify != null)
                  AnimatedBuilder(
                    animation: _open,
                    builder: (context, _) => SizedBox(height: _magnifyBand * _open.value),
                  ),
                if (widget.modeLabel case final label?)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(_keyGap, 2, _keyGap, _keyGap),
                    child: Text(
                      label,
                      style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ExpandReveal(
                  open: widget.tray != null,
                  // 收起键盘时右边让出右栏那一格（36 + 缝），附件条 / 引用条不许钻到 ↑ 底下；
                  // 键盘一开右栏缩成一颗圆，这里跟着收回到 6。
                  child: AnimatedBuilder(
                    animation: _open,
                    builder: (context, child) => Padding(
                      // 托盘的四条缝用原版的值（6 / 2），跟着外面那层内距一起走：
                      // 收起时引用条离玻璃边 6（内距）+ 2 + 4（quoteTop）= 12，和原版一样；
                      // 展开时 11 + 2 + 4 = 17，是我们自己量的那条。
                      padding: EdgeInsets.fromLTRB(
                        _keyGap,
                        2,
                        _keyGap + (_keySize + _keyGap) * (1 - _open.value),
                        _keyGap,
                      ),
                      child: child,
                    ),
                    // 1.4：托盘收起时由 ClosingTrayChild 自己留着退场，不再需要 _tray。
                    child: ClosingTrayChild(widget.tray),
                  ),
                ),
                // A new line grows the glass instead of popping it: anchored
                // at the bottom, where the caret and the keys stay put.
                if (footer != null)
                  row
                else
                  SmoothSize(
                    duration: AppMotion.of(context, AppMotion.quick),
                    curve: AppMotion.std,
                    alignment: Alignment.bottomCenter,
                    child: row,
                  ),
              ],
            );
            // 右栏盖的是**整块内容**（附件条、引用条那一段也算），所以它一路顶到输入框上沿；
            // 键盘一开，它照样缩回右下那颗圆。四边内距按「小边距」9 走，三条边仍等距。
            // ⛶ 只有一处落点：内容区右上角。收键盘时那个角正好是发送栏的顶格（1），
            // 开键盘时是那条 38 的带子（原版就在那儿）—— 两个态同一个点，所以它不用飞。
            final body = TweenAnimationBuilder<double>(
              tween: Tween<double>(end: magnify == null ? 0 : 1),
              duration: AppMotion.of(context, AppMotion.quick),
              curve: AppMotion.std,
              child: SizedBox(width: double.infinity, child: content),
              builder: (context, split, child) => Stack(
                children: [
                  rail(split),
                  child!,
                  if (magnify != null)
                    Positioned.fill(
                      child: Align(
                        alignment: AlignmentDirectional.topEnd,
                        child: Opacity(
                          opacity: split,
                          // 收键盘时它和那条键同一身衣服（就是「发送键分成 1、2 两颗」里的 1）；
                          // 键盘一开栏缩成一颗圆，它退回原来那颗裸符号。
                          child: _MagnifyKey(
                            key: const ValueKey('composer-magnify'),
                            onPressed: _openFullscreen,
                            fill: split * (1 - _open.value),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );
            // 三档内距，一次插值：
            //   收起、没 ⛶ → 6（整条 48，原版那颗胶囊）
            //   收起、有 ⛶ → 9（整条 54）   ← 两个"小边距"档
            //   键盘打开   → 9（整条 54）
            // 驱动它的是两个动画里**走得更远的那个**：`_open` 管开合，`_snug` 管 ⛶。
            // 所以从 48 长到 54 有两种触发，形状走的是同一条路。
            final closedPad = EdgeInsets.fromLTRB(
              leading == null ? _textStartClosed : _glassInsetClosed,
              _glassInsetClosed,
              _glassInsetClosed,
              _glassInsetClosed,
            );
            final snugPad = EdgeInsets.fromLTRB(
              leading == null ? _textStartClosed + (_glassInsetSnug - _glassInsetClosed) : _glassInsetSnug,
              _glassInsetSnug,
              _glassInsetSnug,
              _glassInsetSnug,
            );
            // 四边内距也在**布局**里插值：每帧只跑一次 layout，body 整棵不重建。
            final padded = _OpenPadding(open: _open, snug: _snug, closed: closedPad, wide: snugPad, child: body);
            // 输入条本身也算"里侧"：按 + / ↑ / 附件条 不该顺带把键盘关掉
            // （TapRegion 的判定看位置，不看谁吃掉了这一下）。
            final surface = TextFieldTapRegion(groupId: widget.groupId, child: padded);
            // Dictating: the pet steps away from the voice controls, and a soft light
            // (Libraries.dev Voice) rises from the glass's bottom edge with the voice,
            // under the text and keys.
            return PetCover(
              active: dictating,
              child: voice == null
                  ? surface
                  : Stack(
                      children: [
                        Positioned.fill(
                          child: IgnorePointer(
                            child: VoiceBeam(
                              active: dictating,
                              level: voice.level,
                              levelScale: voice.engine == VoiceEngine.system
                                  ? VoiceLevelScale.linear
                                  : VoiceLevelScale.playback,
                              borderRadius: widget.footer != null && _open.value > 0.5 ? AppShape.lg : AppShape.xl,
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ),
                        surface,
                      ],
                    ),
            );
          },
        ),
      ),
    );
  }
}

/// The composer's glass. With [open], its corners tighten as the composer opens, from
/// the capsule into a rounded rectangle.
class _ComposerGlass extends StatelessWidget {
  const _ComposerGlass({required this.open, this.still, this.blur = true, required this.child});

  final Animation<double>? open;

  /// 1 = 停稳（采样背景、真模糊），0 = 正在动（不透明填充，不采样）。
  final Animation<double>? still;

  /// false = 这一块底下没有壁纸，采样等于白采，直接不采。
  final bool blur;
  final Widget child;

  static const _opened = BorderRadius.all(Radius.circular(AppShape.lg));

  @override
  Widget build(BuildContext context) {
    final open = this.open;
    final themeStyle = DshThemeStyle.of(context);
    final closedRadius = themeStyle.pack == null
        ? AppShape.radiusXl
        : BorderRadius.all(Radius.circular(themeStyle.composerRadius));
    final openedRadius = themeStyle.pack == null ? _opened : themeStyle.scaledBorderRadius(AppShape.lg);
    final scheme = Theme.of(context).colorScheme;
    final GlassStyle? variantStyle = switch (themeStyle.components.composerStyle) {
      ThemeComposerStyle.floatingGlass => null,
      ThemeComposerStyle.solidPaper => GlassStyle(
        fill: scheme.surfaceContainerLowest,
        fallbackFill: scheme.surfaceContainerLowest,
        hairline: scheme.outlineVariant,
        hairlineWidth: themeStyle.borderWidth.clamp(0.5, 2.5),
        rim: Colors.transparent,
      ),
      ThemeComposerStyle.outlined => GlassStyle(
        fill: scheme.surface.withValues(alpha: 0.92),
        fallbackFill: scheme.surface,
        hairline: scheme.outline,
        hairlineWidth: themeStyle.borderWidth.clamp(1.0, 2.5),
        rim: Colors.transparent,
      ),
    };
    final fill = themeStyle.composerFill;
    final border = themeStyle.composerBorder;
    final overrideStyle = fill == null && border == null
        ? variantStyle
        : (variantStyle ?? DshSurfaces.of(context).chrome).copyWith(
            fill: fill,
            // Without blur the fill has to be opaque: flattened onto the page.
            fallbackFill: fill == null ? null : Color.alphaBlend(fill, scheme.surface),
            hairline: border,
          );
    if (open == null) {
      return GlassSurface(
        tier: GlassTier.chrome,
        style: overrideStyle,
        borderRadius: closedRadius,
        settled: still?.value,
        blur: blur ? null : false,
        child: child,
      );
    }
    return AnimatedBuilder(
      animation: open,
      builder: (context, child) => GlassSurface(
        tier: GlassTier.chrome,
        style: overrideStyle,
        borderRadius: BorderRadius.lerp(closedRadius, openedRadius, open.value),
        settled: still?.value,
        blur: blur ? null : false,
        child: child,
      ),
      child: child,
    );
  }
}

/// A phone's composer, between one row and two, as [open] goes from 0 to 1:
///
/// ```
/// (+) text…          (key)      →      text…
///                                      (+) (footer)      (key)
/// ```
///
/// It lays out rather than rebuilds on every step, and the keys travel with the bottom
/// edge, so they slide down as the text takes the width.
class _ComposerRows extends MultiChildRenderObjectWidget {
  _ComposerRows({
    required this.open,
    required Widget text,
    required Widget leading,
    required Widget footer,
    required Widget trailing,
  }) : super(children: [text, leading, footer, trailing]);

  final Animation<double> open;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderComposerRows(open);

  @override
  void updateRenderObject(BuildContext context, _RenderComposerRows renderObject) => renderObject.open = open;
}

class _ComposerRowsParentData extends ContainerBoxParentData<RenderBox> {}

/// 四边内距随开合与折行逐帧插值：收起 6 → 小边距 9。
/// 只走布局，子树（文本、键、Semantics）一次都不重建。
class _OpenPadding extends SingleChildRenderObjectWidget {
  const _OpenPadding({required this.open, required this.snug, required this.closed, required this.wide, super.child});

  final Animation<double> open;
  final Animation<double> snug;
  final EdgeInsets closed;
  final EdgeInsets wide;

  @override
  _RenderOpenPadding createRenderObject(BuildContext context) =>
      _RenderOpenPadding(open: open, snug: snug, closed: closed, wide: wide);

  @override
  void updateRenderObject(BuildContext context, _RenderOpenPadding renderObject) {
    renderObject
      ..open = open
      ..snug = snug
      ..closed = closed
      ..wide = wide;
  }
}

class _RenderOpenPadding extends RenderShiftedBox {
  _RenderOpenPadding({
    required Animation<double> open,
    required Animation<double> snug,
    required EdgeInsets closed,
    required EdgeInsets wide,
  }) : _open = open,
       _snug = snug,
       _closed = closed,
       _wide = wide,
       super(null);

  Animation<double> _open;
  set open(Animation<double> value) {
    if (identical(value, _open)) return;
    if (attached) _open.removeListener(markNeedsLayout);
    _open = value;
    if (attached) _open.addListener(markNeedsLayout);
    markNeedsLayout();
  }

  Animation<double> _snug;
  set snug(Animation<double> value) {
    if (identical(value, _snug)) return;
    if (attached) _snug.removeListener(markNeedsLayout);
    _snug = value;
    if (attached) _snug.addListener(markNeedsLayout);
    markNeedsLayout();
  }

  EdgeInsets _closed;
  EdgeInsets _wide;
  set closed(EdgeInsets value) {
    if (value == _closed) return;
    _closed = value;
    markNeedsLayout();
  }

  set wide(EdgeInsets value) {
    if (value == _wide) return;
    _wide = value;
    markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _open.addListener(markNeedsLayout);
    _snug.addListener(markNeedsLayout);
  }

  @override
  void detach() {
    _open.removeListener(markNeedsLayout);
    _snug.removeListener(markNeedsLayout);
    super.detach();
  }

  @override
  void performLayout() {
    final pad = EdgeInsets.lerp(_closed, _wide, math.max(_open.value, _snug.value))!;
    final child = this.child;
    if (child == null) {
      size = constraints.constrain(Size(pad.horizontal, pad.vertical));
      return;
    }
    child.layout(constraints.deflate(pad), parentUsesSize: true);
    size = constraints.constrain(Size(child.size.width + pad.horizontal, child.size.height + pad.vertical));
    (child.parentData! as BoxParentData).offset = pad.topLeft;
  }
}

/// 右栏那一格：高度由 `_open` 逐帧从 36 长到整列，靠**布局**给到子树，
/// 子树（键、Semantics、InkWell）一次都不重建。
class _KeyRail extends SingleChildRenderObjectWidget {
  const _KeyRail({required this.open, required this.split, super.child});

  final Animation<double> open;

  /// ⛶ 占掉上面那一格（1 = 占着）。
  final double split;

  @override
  _RenderKeyRail createRenderObject(BuildContext context) => _RenderKeyRail(open: open, split: split);

  @override
  void updateRenderObject(BuildContext context, _RenderKeyRail renderObject) {
    renderObject
      ..open = open
      ..split = split;
  }
}

class _RenderKeyRail extends RenderShiftedBox {
  _RenderKeyRail({required Animation<double> open, required double split}) : _open = open, _split = split, super(null);

  Animation<double> _open;
  set open(Animation<double> value) {
    if (identical(value, _open)) return;
    if (attached) _open.removeListener(markNeedsLayout);
    _open = value;
    if (attached) _open.addListener(markNeedsLayout);
    markNeedsLayout();
  }

  double _split;
  set split(double value) {
    if (value == _split) return;
    _split = value;
    markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _open.addListener(markNeedsLayout);
  }

  @override
  void detach() {
    _open.removeListener(markNeedsLayout);
    super.detach();
  }

  /// 这一列「停稳之后」有多高：只在开合走到两端时才重算。
  ///
  /// 不这么做会**双重插值**：输入条展开时这一列的高度本身也在动，拿它当目标再
  /// 按 `_open` 插一次，那颗键就会 36 → 45 → 36 地鼓一下——白画一层、还白重排一帧
  /// （2026-11-27 模拟出来的：这是我们的输入条和原版唯一真正的差别，原版那颗键
  /// 是一颗固定的圆）。
  double _room = _keySize;

  @override
  void performLayout() {
    final child = this.child;
    final height = constraints.maxHeight;
    if (child == null) {
      size = constraints.constrain(Size(_keySize, height));
      return;
    }
    // 这一列有多高：键从 36 长到它；⛶ 在上头时让出那一格和那道缝。
    // 只在停稳的那两端取，动画中间不跟着高度跑。
    if (_open.isDismissed || _open.isCompleted || !_open.isAnimating) {
      _room = math.max(_keySize, height - (_keySize + _keySlot) * _split);
    }
    final grown = ui.lerpDouble(_keySize, _room, 1 - _open.value)!;
    child.layout(BoxConstraints.tightFor(width: _keySize, height: grown), parentUsesSize: true);
    size = constraints.constrain(Size(_keySize, height));
    (child.parentData! as BoxParentData).offset = Offset(0, math.max(0.0, height - grown));
  }
}

class _RenderComposerRows extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _ComposerRowsParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _ComposerRowsParentData> {
  _RenderComposerRows(this._open);

  /// Beside the text, on one row.
  static const _gap = 8.0;

  /// Between the pieces of the second row: what the glass leaves around them.
  static const _rowGap = _keyGap;

  /// The text's own inset once it has the line to itself.
  static const _inset = 8.0;

  /// Between the text and the row under it.
  static const _rows = 2.0;

  Animation<double> _open;
  set open(Animation<double> value) {
    if (identical(value, _open)) return;
    if (attached) _open.removeListener(markNeedsLayout);
    _open = value;
    if (attached) _open.addListener(markNeedsLayout);
    markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _open.addListener(markNeedsLayout);
  }

  @override
  void detach() {
    _open.removeListener(markNeedsLayout);
    super.detach();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _ComposerRowsParentData) child.parentData = _ComposerRowsParentData();
  }

  /// The footer answers and is read out once it is mostly there.
  bool get _footerLive => _open.value > 0.5;

  double _textWidth(double width, double leading, double trailing) {
    final rest = width - (leading > 0 ? leading + _gap : 0) - _gap - trailing;
    return math.max(0.0, ui.lerpDouble(rest, width - 2 * _inset, _open.value)!);
  }

  Size _measure(BoxConstraints constraints, ChildLayouter layoutChild) {
    final [text, leading, footer, trailing] = getChildrenAsList();
    final width = constraints.maxWidth;
    final loose = BoxConstraints(maxWidth: width);
    final lead = layoutChild(leading, loose);
    final trail = layoutChild(trailing, loose);
    final foot = layoutChild(
      footer,
      BoxConstraints(maxWidth: math.max(0.0, width - lead.width - trail.width - 2 * _rowGap)),
    );
    final field = layoutChild(text, BoxConstraints.tightFor(width: _textWidth(width, lead.width, trail.width)));
    final keys = math.max(math.max(lead.height, trail.height), foot.height);
    final height = ui.lerpDouble(math.max(field.height, keys), field.height + _rows + keys, _open.value)!;
    return constraints.constrain(Size(width, height));
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    return _measure(constraints, ChildLayoutHelper.dryLayoutChild);
  }

  @override
  void performLayout() {
    size = _measure(constraints, ChildLayoutHelper.layoutChild);
    final [text, leading, footer, trailing] = getChildrenAsList();
    final t = _open.value;
    void place(RenderBox child, double x, double y) =>
        (child.parentData! as _ComposerRowsParentData).offset = Offset(x, y);
    final restX = leading.size.width > 0 ? leading.size.width + _gap : 0.0;
    final keys = math.max(math.max(leading.size.height, trailing.size.height), footer.size.height);
    final restTop = math.max(0.0, math.max(text.size.height, keys) - text.size.height);
    place(text, ui.lerpDouble(restX, _inset, t)!, ui.lerpDouble(restTop, 0, t)!);
    // On one centre line, whatever their heights.
    double centred(RenderBox child) => size.height - keys + (keys - child.size.height) / 2;
    place(leading, 0, centred(leading));
    place(footer, leading.size.width + _rowGap, centred(footer));
    place(trailing, size.width - trailing.size.width, centred(trailing));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    for (final child in getChildrenAsList()) {
      if (child == childAfter(childAfter(firstChild!)!) && _open.value == 0) continue;
      context.paintChild(child, (child.parentData! as _ComposerRowsParentData).offset + offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final footer = childAfter(childAfter(firstChild!)!);
    for (final child in getChildrenAsList().reversed) {
      if (child == footer && !_footerLive) continue;
      final hit = result.addWithPaintOffset(
        offset: (child.parentData! as _ComposerRowsParentData).offset,
        position: position,
        hitTest: (result, transformed) => child.hitTest(result, position: transformed),
      );
      if (hit) return true;
    }
    return false;
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    final footer = childAfter(childAfter(firstChild!)!);
    for (final child in getChildrenAsList()) {
      if (child != footer || _footerLive) visitor(child);
    }
  }
}

/// What the right-hand key does.
enum _KeyMode {
  /// ↑ send.
  send,

  /// ■ stop the running turn.
  stopRun,

  /// 🎙 start dictating (draft empty).
  mic,

  /// ■ stop dictating and keep the text.
  stopVoice,
}

/// 发送键那颗圆/那条的底。只有这一处上色（形状本人），图标和它同一个来源。
/// 主题包（1.4）的 `components.sendButton` 可以指定发送键底色；没给就走我们的主色。
DshThemeStyle _themeStyleOf(BuildContext context) => DshThemeStyle.of(context);

Color _keyFill(ColorScheme colors, {required bool mic, required bool active, Color? styleFill}) => mic
    ? colors.onSurface.withValues(alpha: 0.06)
    : active
    ? (styleFill ?? colors.primary)
    : colors.onSurface.withValues(alpha: 0.12);

/// 这颗键**就是那个形状本人**：圆的时候 36×36、四角 18；撑开时高度跟着整行长，
/// 四角仍然是 18 —— 上下两个半圆 + 中间一段矩形（胶囊）。底色、符号、命中区、
/// 按压反馈都在它身上，只有一层。
/// `↑` 发送 / `■` 停止(实心主色) / 🎙 麦克风是 ＋ 键那样的淡底圆；禁用时 onSurface 12%。
class _SendButton extends StatefulWidget {
  const _SendButton({
    required this.mode,
    required this.busy,
    required this.enabled,
    required this.onTap,
    this.onLongPress,
    this.quiet = false,
    this.sendLabel,
  });

  final _KeyMode mode;

  /// In place of 发送, for what sending does just now.
  final String? sendLabel;

  /// Drawn like the mic key (something else on screen is primary).
  final bool quiet;

  final bool busy;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton> {
  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final fluid = AppMotion.fluid(context);
    final enabled = widget.enabled && !widget.busy;
    final mode = widget.mode;
    final themeStyle = DshThemeStyle.of(context);
    final sendStyle = themeStyle.components.sendButtonStyle;
    final inkMic = mode == _KeyMode.mic && sendStyle == ThemeSendButtonStyle.ink;
    // tonal / outlined 这两种圆键样式我们不再区分：这颗键是胶囊，形状由设计定，
    // 主题包只保留两个钩子——底色 `sendButton` 与符号色 `onSendButton`。
    final mic = mode == _KeyMode.mic || widget.quiet;
    final active = enabled || widget.busy;
    // 主题包（1.4）可以指定发送键的底色；没指定就按我们自己的胶囊配色走。
    final bg = inkMic
        ? colors.onSurface
        : _keyFill(colors, mic: mic, active: active, styleFill: _themeStyleOf(context).sendButton);
    final fg = inkMic
        ? colors.surface
        : mic
        ? colors.onSurface
        : active
        ? (themeStyle.onSendButton ?? colors.onPrimary)
        : colors.onSurface.withValues(alpha: 0.38);
    final (icon, size, label) = switch (mode) {
      _KeyMode.send => (AppIcons.send, 20.0, widget.sendLabel ?? l10n.commonSend),
      _KeyMode.stopRun => (AppIcons.stopGenerating, 18.0, l10n.chatStopGenerating),
      _KeyMode.mic => (AppIcons.voice, 20.0, l10n.chatVoiceInput),
      _KeyMode.stopVoice => (AppIcons.stopGenerating, 18.0, l10n.chatStopVoiceInput),
    };
    // 符号只在这里建一次：形状每帧在更长，符号一格不动。
    final iconBox = SizedBox.square(
      dimension: _keySize,
      child: AnimatedSwitcher(
        duration: fluid ? AppMotion.standard : AppMotion.of(context, AppMotion.quick),
        switchInCurve: fluid ? Curves.linear : AppMotion.enter,
        switchOutCurve: Curves.linear,
        transitionBuilder: (child, anim) =>
            fluid ? _FluidKeySwap(animation: anim, child: child) : ScaleTransition(scale: anim, child: child),
        child: widget.busy
            ? Padding(
                key: const ValueKey('busy'),
                // 这颗转圈在 36 的方里，内距是它自己的，不跟玻璃外距走。
                padding: const EdgeInsets.all(11),
                child: CircularProgressIndicator(strokeWidth: 2, color: fg),
              )
            : Icon(icon, key: ValueKey(mode), size: size, color: fg),
      ),
    );
    // 形状：宽永远是 [_keySize]，四角恒为胶囊的一半；只有高度在变。
    // 高度不给：交给外面的布局（`_KeyRail` 每帧给一个新的紧约束），
    // 所以形状每帧变而这颗键的 widget 一次都不重建。
    Widget shape() => Container(
      key: const ValueKey('composer-send-shape'),
      width: _keySize,
      // 符号落在形状正中：圆的时候就是那颗圆的中心，撑开之后自然上下居中。
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadiusDirectional.only(
          topStart: const Radius.circular(_keySize / 2),
          bottomStart: const Radius.circular(_keySize / 2),
          topEnd: const Radius.circular(_keySize / 2),
          bottomEnd: const Radius.circular(_keySize / 2),
        ),
      ),
      child: iconBox,
    );
    final core = shape();
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.busy && mode == _KeyMode.stopRun ? l10n.commonStopping : label,
      // 按压：和侧栏「新对话」、⛶ 同一套 —— 本体伸到 AppMotion.pressLift。
      // 不再自己拿 AnimatedScale，省得三处三个手感（He 2026-11-24 定的标准）。
      child: Pressable(
        onTap: enabled ? widget.onTap : null,
        onLongPress: widget.onLongPress == null
            ? null
            : () {
                HapticFeedback.mediumImpact();
                widget.onLongPress!();
              },
        enabled: enabled,
        haptic: false,
        scale: AppMotion.pressLift,
        child: core,
      ),
    );
  }
}

/// The fluid send key's icon swap: the plane that was sent flies off up and to the
/// right, and what comes next pops in on a spring.
class _FluidKeySwap extends StatelessWidget {
  const _FluidKeySwap({required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  static const _flight = 16.0;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: animation,
    child: child,
    builder: (context, child) {
      final v = animation.value.clamp(0.0, 1.0);
      final leaving = animation.status == AnimationStatus.reverse;
      final flies = leaving && this.child.key == const ValueKey(_KeyMode.send);
      final away = flies ? _flight * Curves.easeIn.transform(1 - v) : 0.0;
      final scale = flies
          ? 1.0
          : leaving
          ? 0.4 + 0.6 * v
          : 0.4 + 0.6 * AppMotion.thumbCurve.transform(v);
      return Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset(away, -away),
          child: Transform.scale(scale: scale, child: child),
        ),
      );
    },
  );
}

/// 草稿高过输入框时冒出来的「放大」键。36 方，和发送键同高。
///
/// 收键盘时它就是发送栏顶上那半颗（「1」）：和那条键同一身衣服；
/// 键盘开着时栏缩成一颗圆、它退回原来那颗裸符号 —— 只看这把 [fill]。
///
/// 草稿高过输入框时冒出来的「放大」键。36 方，和发送键同高。
///
/// 收键盘时它就是发送栏顶上那半颗（「1」）：和那条键同一身衣服；
/// 键盘开着时栏缩成一颗圆、它退回原来那颗裸符号 —— 只看这把 [fill]。
///
/// 底色只有一层（`CircleBorder` + 主色，透明度 = [fill]）。
/// 试过再叠一层"从底边中点涨满"的圆，He 2026-11-24 判：能感觉到掉帧 → 撤了（§82）。
class _MagnifyKey extends StatelessWidget {
  const _MagnifyKey({super.key, required this.onPressed, this.fill = 0});

  final VoidCallback onPressed;

  /// 0 = 裸符号（原来那一态）；1 = 主色底（发送栏分出来的那半颗）。
  final double fill;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // 和 ↑、侧栏「新对话」一样：按下去是**本体伸**（AppMotion.pressLift），
    // 不再是 IconButton 那个盖在方角上的圆水波（He 2026-11-24 定的标准）。
    return Pressable(
      onTap: onPressed,
      scale: AppMotion.pressLift,
      semanticLabel: context.l10n.activityStepFullScreen,
      child: SizedBox.square(
        dimension: _keySize,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            shape: const CircleBorder(),
            color: colors.primary.withValues(alpha: fill),
          ),
          child: Center(
            child: Icon(
              AppIcons.expandInput,
              size: 20,
              color: Color.lerp(DshColors.of(context).textTertiary, colors.onPrimary, fill),
            ),
          ),
        ),
      ),
    );
  }
}

/// 全屏输入页：同一个 controller，键盘在上面，发送键在右上角。
class _ComposerFullscreen extends StatefulWidget {
  const _ComposerFullscreen({required this.controller, required this.history, required this.style, required this.hint});

  final TextEditingController controller;
  final _DraftHistory history;
  final TextStyle? style;
  final String hint;

  @override
  State<_ComposerFullscreen> createState() => _ComposerFullscreenState();
}

class _ComposerFullscreenState extends State<_ComposerFullscreen> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 6, 12, 0),
              child: Row(
                children: [
                  // 左上角原来是空的：撤回 / 重做。没有可撤回的动作时是灰的、点不动。
                  ListenableBuilder(
                    listenable: widget.history,
                    builder: (context, _) => Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: widget.history.canUndo ? widget.history.undo : null,
                          icon: _BentArrow(
                            size: 20,
                            forward: false,
                            color: widget.history.canUndo
                                ? Theme.of(context).colorScheme.onSurface
                                : DshColors.of(context).textTertiary,
                          ),
                        ),
                        IconButton(
                          onPressed: widget.history.canRedo ? widget.history.redo : null,
                          icon: _BentArrow(
                            size: 20,
                            forward: true,
                            color: widget.history.canRedo
                                ? Theme.of(context).colorScheme.onSurface
                                : DshColors.of(context).textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  // 右上角：**还是那颗符号**（四角括号），展开只换颜色——染强调色；
                  // 再点一下收起，颜色跟着退。位置和收起前一致。
                  SizedBox.square(
                    dimension: _keySize,
                    child: IconButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      padding: EdgeInsets.zero,
                      iconSize: 20,
                      style: IconButton.styleFrom(foregroundColor: accent),
                      icon: const Icon(AppIcons.collapseInput, size: 20),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                child: TextField(
                  controller: widget.controller,
                  focusNode: _focus,
                  autofocus: true,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  style: widget.style,
                  cursorColor: accent,
                  decoration: InputDecoration(hintText: widget.hint, border: InputBorder.none),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `↶` / `↷`：字体子集里只有圆周箭头，没有这种"带回勾的直线箭头"，
/// 所以照图1 前两颗的样子自绘（箭头尖在左/右，尾巴向下弯一段）。
class _BentArrow extends StatelessWidget {
  const _BentArrow({required this.size, required this.color, required this.forward});

  final double size;
  final Color color;

  /// true = 重做（↷，箭头尖在右）。
  final bool forward;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _BentArrowPainter(color, forward));
}

class _BentArrowPainter extends CustomPainter {
  const _BentArrowPainter(this.color, this.forward);

  final Color color;
  final bool forward;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    if (s <= 0) return;
    final stroke = s * 0.09;
    final paint = Paint()
      ..color = color
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    canvas.save();
    if (forward) {
      canvas.translate(s, 0);
      canvas.scale(-1, 1);
    }
    // 尖在左（0.16s, 0.38s），横线向右到 0.58s，再向下弯到 0.80s。
    final tip = Offset(s * 0.16, s * 0.38);
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(s * 0.56, s * 0.38)
      ..quadraticBezierTo(s * 0.82, s * 0.38, s * 0.82, s * 0.62)
      ..lineTo(s * 0.82, s * 0.78);
    canvas.drawPath(path, paint);
    // 箭头
    final head = Path()
      ..moveTo(s * 0.30, s * 0.24)
      ..lineTo(tip.dx, tip.dy)
      ..lineTo(s * 0.30, s * 0.52);
    canvas.drawPath(head, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BentArrowPainter oldDelegate) => oldDelegate.color != color || oldDelegate.forward != forward;
}

/// 草稿的撤回 / 重做。
///
/// 为什么不用 Flutter 的 `UndoHistoryController`：它只镜像"能不能撤"，
/// 真正的历史栈住在 `UndoHistory` 那个 widget 的 State 里——全屏页是一条路由，
/// 关掉就把栈一起销毁了，控制器留着也撤不回去（He 报的"收起再展开没了"就是它）。
/// 这里自己存快照：`_past` 的末尾永远是"当前"，跨展开/收起天然保留。
class _DraftHistory extends ChangeNotifier {
  _DraftHistory(this.controller) {
    _past.add(controller.value);
  }

  final TextEditingController controller;
  final List<TextEditingValue> _past = [];
  final List<TextEditingValue> _future = [];

  /// 应用快照时会触发 controller 的监听，别把它当成用户输入再记一次。
  bool _applying = false;

  static const _maxDepth = 200;

  void record() {
    if (_applying) return;
    final now = controller.value;
    if (_past.isNotEmpty && _past.last.text == now.text) return;
    _past.add(now);
    if (_past.length > _maxDepth) _past.removeAt(0);
    _future.clear();
    notifyListeners();
  }

  bool get canUndo => _past.length > 1;

  bool get canRedo => _future.isNotEmpty;

  void undo() {
    if (!canUndo) return;
    _applying = true;
    _future.add(_past.removeLast());
    controller.value = _past.last;
    _applying = false;
    notifyListeners();
  }

  void redo() {
    if (!canRedo) return;
    _applying = true;
    final next = _future.removeLast();
    _past.add(next);
    controller.value = next;
    _applying = false;
    notifyListeners();
  }
}
