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
import '../common/smooth_size.dart';
import '../fx/voice_glow/voice_beam.dart';
import '../pets/pet_perch.dart';
import '../settings/voice_settings_page.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'voice/voice_controller.dart';
import 'voice/voice_widgets.dart';

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
    this.keyboardInset = 0,
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

  /// The keyboard's height, from a page that still knows it: how [footer] tells the
  /// keyboard going down from the field losing focus.
  final double keyboardInset;

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

/// The composer's own text, a step under body text.
const double _fontSize = 15.0;

class _ComposerState extends State<Composer> with SingleTickerProviderStateMixin {
  Duration? _lastEscape;
  // Keep the editor and its input connection when the footer changes the layout.
  final _fieldKey = GlobalKey();
  late final _draftEmpty = ValueNotifier(widget.controller.text.trim().isEmpty);

  /// 草稿高过输入框的行数上限（[Composer.maxLines]）就会内部滚动，
  /// 那时才长出一颗「放大」键。
  late final _overflow = ValueNotifier(false);

  /// 打字期间持有的横滑闸；失焦 / 销毁时还回去。
  SwipeHold? _typingHold;

  /// 撤回 / 重做。自己存快照，不依赖 Flutter 的 UndoHistory——
  /// 那个的历史栈住在 widget 的 State 里，全屏页一关就没了。
  late final _history = _DraftHistory(widget.controller);


  void _draftChanged() {
    _history.record();
    final text = widget.controller.text;
    _draftEmpty.value = text.trim().isEmpty;
    var lines = 1;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x0A) lines++;
    }
    _overflow.value = lines > widget.maxLines;
  }

  // One value for everything that moves when the composer opens: the corners, the text's
  // width, the height, the keys and the footer's fade. One motion, not several in step.
  late final AnimationController _openController = AnimationController(vsync: this, duration: AppMotion.collapse);
  late final Animation<double> _open = CurvedAnimation(parent: _openController, curve: AppMotion.collapseCurve);

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
      unawaited(_openController.forward());
    } else if (!open && _openController.status != AnimationStatus.reverse && !_openController.isDismissed) {
      unawaited(_openController.reverse());
    }
  }

  void _focusChanged() {
    final focused = widget.focusNode?.hasFocus ?? false;
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncOpen());
  }

  /// The last tray shown: it stays while the tray folds away.
  late Widget? _tray = widget.tray;

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
    _tray = widget.tray ?? _tray;
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
    widget.controller.removeListener(_draftChanged);
    _draftEmpty.dispose();
    widget.focusNode?.removeListener(_focusChanged);
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
    final voice = widget.voice;
    voice?.ensureFresh();

    // The chat page's pet stands on the composer's top edge (outside a pet
    // stage this is a plain pass-through).
    return PetPerch(
      kind: PerchKind.composer,
      child: _ComposerGlass(
        open: widget.footer == null ? null : _open,
        child: ListenableBuilder(
          // The editor listens to text, selection and composing changes itself.
          // Its surrounding controls only need the draft's empty/nonempty edge.
          listenable: Listenable.merge([_draftEmpty, _overflow, ?voice]),
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
                              : widget.placeholder ?? l10n.chatComposerHint),
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
                  controller: widget.controller,
                  focusNode: widget.focusNode,
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
            // 这一颗键的"是不是麦克风样子""能不能按"：右栏的底色也要用，所以先算出来。
            final keyQuiet = (showStop && waiting && !widget.stopping) || emptySend;
            final keyOn = switch (mode) {
              _KeyMode.mic => true,
              _KeyMode.stopVoice => phase == VoicePhase.listening,
              _ => enabled,
            };
            final sendKey = _SendButton(
              mode: mode,
              busy: keyBusy,
              quiet: keyQuiet,
              rail: _open,
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
            final magnify = _overflow.value
                ? _MagnifyKey(key: const ValueKey('composer-magnify'), onPressed: _openFullscreen)
                : null;
            final footer = widget.footer;
            final row = footer == null
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (leadingKey != null) ...[leadingKey, const SizedBox(width: 8)],
                      Expanded(child: field),
                      const SizedBox(width: 8),
                      if (accessory != null) ...[accessory, const SizedBox(width: 2)],
                      sendKey,
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
                          if (accessory != null) ...[accessory, const SizedBox(width: _keyGap)],
                          sendKey,
                        ],
                      ),
                    ),
                  );
            // 右栏：**一根**圆角矩形，不是"棒子挂球"。宽 = 原圆直径（36），高度跟着内容长，
            // 它就是那颗发送键长高了的样子——箭头落在它底部。圆角 6 是照 He 那张图里
            // 「1 和 2 拼起来」的比例（角约等于宽的六分之一）。空闲态是整条，
            // 键盘一开缩回那颗圆——用的还是同一条 `_open`，没有第二个控制器。
            final rail = PositionedDirectional(
              top: 0,
              end: 0,
              bottom: 0,
              width: _keySize,
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _open,
                  builder: (context, _) => Opacity(
                    opacity: 1 - _open.value,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: _keyFill(
                          theme.colorScheme,
                          mic: mode == _KeyMode.mic || keyQuiet,
                          active: (keyOn && !keyBusy) || keyBusy,
                        ),
                        // 左 6 / 右 18：He 2026-11-22 定的——「3 的左半边 + 1 的右半边」。
                        // 面对内容那侧几乎是一条竖线，靠边那侧收成半圆。
                        borderRadius: const BorderRadiusDirectional.horizontal(
                          start: Radius.circular(6),
                          end: Radius.circular(_keySize / 2),
                        ),
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
            );
            // 栏垫在下面，文字和键压在上面：箭头正好落在栏的底端。
            final rowWithRail = Stack(children: [rail, row]);

            // The tray unfolds above the text and folds away again: the
            // glass grows and shrinks, the text row never jumps.
            final content = Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 放大键在**右上角**（不是发送键旁边）：草稿一超过输入框高度就长出来，
                // 展开之后同一个位置是收起键。
                if (magnify != null)
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Padding(padding: const EdgeInsets.only(bottom: 2), child: magnify),
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
                  child: Padding(padding: const EdgeInsets.fromLTRB(_keyGap, 2, _keyGap, _keyGap), child: _tray),
                ),
                // A new line grows the glass instead of popping it: anchored
                // at the bottom, where the caret and the keys stay put.
                if (footer != null)
                  rowWithRail
                else
                  SmoothSize(
                    duration: AppMotion.of(context, AppMotion.quick),
                    curve: AppMotion.std,
                    alignment: Alignment.bottomCenter,
                    child: rowWithRail,
                  ),
              ],
            );
            // 四边都 11：左右拉平、两边的键各往里收 5；上下也跟到 11，
            // 因为右栏是从那颗圆长出来的，它到上、右、下三条边的距离必须一样
            // （He 2026-11-22：右边比上下远，是瑕疵）。
            final padded = Padding(
              padding: const EdgeInsets.all(11),
              child: content,
            );
            final surface = padded;
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
  const _ComposerGlass({required this.open, required this.child});

  final Animation<double>? open;
  final Widget child;

  static const _opened = BorderRadius.all(Radius.circular(AppShape.lg));

  @override
  Widget build(BuildContext context) {
    final open = this.open;
    if (open == null) return GlassSurface(tier: GlassTier.chrome, borderRadius: AppShape.radiusXl, child: child);
    return AnimatedBuilder(
      animation: open,
      builder: (context, child) => GlassSurface(
        tier: GlassTier.chrome,
        borderRadius: BorderRadius.lerp(AppShape.radiusXl, _opened, open.value),
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
  Size computeDryLayout(covariant BoxConstraints constraints) =>
      _measure(constraints, ChildLayoutHelper.dryLayoutChild);

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

/// 发送键那颗圆的底。空闲态时右栏画在它上面接成一整条，两处必须是同一个颜色。
Color _keyFill(ColorScheme colors, {required bool mic, required bool active}) => mic
    ? colors.onSurface.withValues(alpha: 0.06)
    : active
    ? colors.primary
    : colors.onSurface.withValues(alpha: 0.12);

/// 40 圆键:↑ 发送 / ■ 停止(实心主色);🎙 麦克风是 ＋ 键那样的淡底圆。
/// 禁用时是 onSurface 12% 的底。
class _SendButton extends StatefulWidget {
  const _SendButton({
    required this.mode,
    required this.busy,
    required this.enabled,
    required this.onTap,
    this.onLongPress,
    this.quiet = false,
    this.rail,
    this.sendLabel,
  });

  final _KeyMode mode;

  /// In place of 发送, for what sending does just now.
  final String? sendLabel;

  /// Drawn like the mic key (something else on screen is primary).
  final bool quiet;

  /// 空闲态那条右栏的进度（0 = 整条，1 = 只有这颗圆）。栏上来时这颗圆的底色要退掉，
  /// 不然就成了"一根棒子底下挂一颗球"——箭头留在最后，它要压在栏上。
  final Animation<double>? rail;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final fluid = AppMotion.fluid(context);
    final enabled = widget.enabled && !widget.busy;
    final mode = widget.mode;
    final mic = mode == _KeyMode.mic || widget.quiet;
    final active = enabled || widget.busy;
    final bg = _keyFill(colors, mic: mic, active: active);
    final fg = mic
        ? colors.onSurface
        : active
        ? colors.onPrimary
        : colors.onSurface.withValues(alpha: 0.38);
    final (icon, size, label) = switch (mode) {
      _KeyMode.send => (AppIcons.send, 20.0, widget.sendLabel ?? l10n.commonSend),
      _KeyMode.stopRun => (AppIcons.stopGenerating, 18.0, l10n.chatStopGenerating),
      _KeyMode.mic => (AppIcons.voice, 20.0, l10n.chatVoiceInput),
      _KeyMode.stopVoice => (AppIcons.stopGenerating, 18.0, l10n.chatStopVoiceInput),
    };
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.busy && mode == _KeyMode.stopRun ? l10n.commonStopping : label,
      child: GestureDetector(
        onTap: enabled ? widget.onTap : null,
        onLongPress: widget.onLongPress == null
            ? null
            : () {
                setState(() => _pressed = false);
                HapticFeedback.mediumImpact();
                widget.onLongPress!();
              },
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: () => setState(() => _pressed = false),
        child: _disc(context, bg, fluid, AnimatedSwitcher(
              duration: fluid ? AppMotion.standard : AppMotion.of(context, AppMotion.quick),
              switchInCurve: fluid ? Curves.linear : AppMotion.enter,
              switchOutCurve: Curves.linear,
              transitionBuilder: (child, anim) =>
                  fluid ? _FluidKeySwap(animation: anim, child: child) : ScaleTransition(scale: anim, child: child),
              child: widget.busy
                  ? Padding(
                      key: const ValueKey('busy'),
                      padding: const EdgeInsets.all(11),
                      child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                    )
                  : Icon(icon, key: ValueKey(mode), size: size, color: fg),
            ),
          ),
        ),
    );
  }

  /// 这颗圆本身：`rail` 走到 0（整条右栏起来了）时把圆底退成透明，
  /// 剩下的圆只是一块触摸区，箭头压在栏上。
  Widget _disc(BuildContext context, Color bg, bool fluid, Widget icon) {
    final pressed = _pressed;
    final rail = widget.rail;
    Widget disc(double fade) => AnimatedScale(
      scale: pressed ? 0.9 : 1,
      duration: fluid && !pressed ? AppMotion.thumbCurve.duration : AppMotion.of(context, AppMotion.press),
      curve: fluid && !pressed ? AppMotion.thumbCurve : AppMotion.std,
      child: AnimatedContainer(
        duration: AppMotion.of(context, AppMotion.quick),
        width: _keySize,
        height: _keySize,
        decoration: BoxDecoration(
          color: fade >= 1 ? bg : bg.withValues(alpha: bg.a * fade),
          shape: BoxShape.circle,
        ),
        child: icon,
      ),
    );
    if (rail == null) return disc(1);
    return AnimatedBuilder(animation: rail, builder: (context, _) => disc(rail.value));
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


/// 草稿高过输入框时冒出来的「放大」键。36 方，安静的一颗，和发送键同高。
class _MagnifyKey extends StatelessWidget {
  const _MagnifyKey({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    // 裸符号，不铺底：和输入条里其他元素同一层，不抢发送键。
    return SizedBox.square(
      dimension: _keySize,
      child: IconButton(
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        iconSize: 20,
        style: IconButton.styleFrom(foregroundColor: DshColors.of(context).textTertiary),
        icon: const Icon(AppIcons.expandInput, size: 20),
      ),
    );
  }
}

/// 全屏输入页：同一个 controller，键盘在上面，发送键在右上角。
class _ComposerFullscreen extends StatefulWidget {
  const _ComposerFullscreen({
    required this.controller,
    required this.history,
    required this.style,
    required this.hint,
  });

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
  bool shouldRepaint(_BentArrowPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.forward != forward;
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
