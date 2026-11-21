// 消息的可选文本层：长按选字；**滚列表不掉选区**；点一下屏幕才清掉。
//
// 为什么不能直接用 [SelectionArea]：
//
// 1) 框架里 `SelectableRegion` 用 `TapAndHorizontalDragGestureRecognizer`，它的
//    `onCancel = clearSelection`。手指纵向拖去翻列表时，祖先 `Scrollable` 抢走手势，
//    这个识别器就被 cancel —— 选区当场消失。这是 He 2026-11-21 报的现象，翻的
//    还是 Flutter 自己的实现，不是我们哪里写错了。
//    治法：有选区时这层 `IgnorePointer(ignoring: true)`，指针根本不进选区的手势
//    竞技场，滚动自然 cancel 不到它。清除改由"点一下屏幕"发起（见 chat_list 里的
//    Listener 与 [clearMessageSelection]）。
//
// 2) 消息在 `SliverList` 里是懒构建的，滚出视口就会被 dispose，选区随宿主一起没。
//    治法：持有选区时打开 keep-alive（`AutomaticKeepAliveClientMixin`），让这条
//    消息在树里活到选区被清掉为止。
//
// 横滑闸（`SwipeHold`）仍在：有选区就压住会话抽屉那侧的手势，和以前一样。

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;

import 'package:path_provider/path_provider.dart';

import '../../../state/swipe_guard.dart';

// ── 临时探针（定位完删）：选区的生灭+清除时的调用栈写进 <app files>/sel_probe.txt ──
int _probeLines = 0;

void _probe(String line) {
  if (_probeLines > 500) return;
  _probeLines++;
  try {
    getApplicationSupportDirectory().then((dir) {
      File('${dir.path}/sel_probe.txt')
          .writeAsStringSync('$_probeLines | $line\n', mode: FileMode.append, flush: true);
    });
  } on Object {
    // 探针坏了不该影响应用。
  }
}


/// 点屏幕时清掉当前选区。`chat_list` 的 Listener 在"短按且没移动"时调用它。
VoidCallback? _activeClear;

void clearMessageSelection() {
  final clear = _activeClear;
  _activeClear = null;
  clear?.call();
}

class MessageSelectionArea extends StatefulWidget {
  const MessageSelectionArea({super.key, required this.child});

  final Widget child;

  @override
  State<MessageSelectionArea> createState() => _MessageSelectionAreaState();
}

class _MessageSelectionAreaState extends State<MessageSelectionArea> with AutomaticKeepAliveClientMixin {
  final GlobalKey<SelectionAreaState> _areaKey = GlobalKey<SelectionAreaState>();
  late final VoidCallback _clearCallback = _clear;

  SwipeHold? _hold;
  bool _hasSelection = false;

  @override
  bool get wantKeepAlive => _hasSelection;

  void _onSelectionChanged(SelectedContent? content) {
    final has = content != null && content.plainText.trim().isNotEmpty;
    _probe('changed has=$has prev=$_hasSelection len=${content?.plainText.length ?? -1}');
    if (!has && _hasSelection) {
      _probe('CLEARED by:\n${StackTrace.current.toString().split('\n').take(12).join('\n')}');
    }
    if (has == _hasSelection) return;
    setState(() => _hasSelection = has);
    updateKeepAlive();
    if (has) {
      _hold ??= SwipeHold();
      _activeClear = _clearCallback;
    } else {
      _hold?.release();
      _hold = null;
      if (identical(_activeClear, _clearCallback)) _activeClear = null;
    }
  }

  void _clear() {
    _probe('_clear() from tap');
    _areaKey.currentState?.selectableRegion.clearSelection();
  }

  @override
  void dispose() {
    _probe('dispose has=$_hasSelection');
    if (identical(_activeClear, _clearCallback)) _activeClear = null;
    _hold?.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    _probe('build ignoring=$_hasSelection');
    return IgnorePointer(
      // 有选区：指针穿过去（滚动、点击都归外面），选区的识别器不进竞技场，
      // 所以滚动不会 cancel 它 —— 这就是"翻列表选区不消失"的那一半。
      ignoring: _hasSelection,
      child: SelectionArea(
        key: _areaKey,
        onSelectionChanged: _onSelectionChanged,
        child: widget.child,
      ),
    );
  }
}

/// 一次按下到抬起是不是"点了一下"：[slop] 内没移动、也没超过 [maxMs]。
bool isTapGesture(Offset from, Offset to, Duration elapsed, {double slop = kTouchSlop, int maxMs = 300}) =>
    (to - from).distance <= slop && elapsed.inMilliseconds <= maxMs;
