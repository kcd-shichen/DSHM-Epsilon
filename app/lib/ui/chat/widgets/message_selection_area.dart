// 消息的可选文本层：长按选字；**滚列表不掉选区**；点一下屏幕才清掉。
//
// 让选区消失的只有一条路，是**丢焦点**：框架里
// `SelectableRegion._handleFocusChanged` 在 `hasFocus` 变 false 时直接
// `clearSelection()`。真机探针（sel_probe.txt）打出来的栈就是这条。
// 治法：给 `SelectionArea` 传一个 `canRequestFocus: false` 的 `FocusNode`——
// 它永远不会"从有到无"，这条路径就不成立了（手机端选区不需要焦点）。
//
// 顺带澄清一条曾经的误判：滚动本身**不**清选区。翻 `tap_and_drag.dart` 可见，
// 识别器输掉竞技场走的是 `rejectGesture`（只 `_giveUpPointer` / `_resetTaps`），
// 不调 `_checkCancel`，所以 `onCancel = clearSelection` 不会被触发。曾为此加过
// 一层 `IgnorePointer`，已删 —— 那是冗余。
//
// 第二件事：消息在 `SliverList` 里懒构建，滚出视口会被 dispose，选区随宿主一起没。
// 治法：`AutomaticKeepAliveClientMixin`，持有选区时 `wantKeepAlive = true`。
//
// 第三件：一次只允许一个选区。每条消息是**彼此独立**的 `SelectableRegion`，
// 框架那套"只能选一处"管不到跨消息，所以要自己收（见 [_activeClears]）。
//
// 横滑闸（`SwipeHold`）仍在：有选区就压住会话抽屉那侧的手势，和以前一样。

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;

import '../../../state/swipe_guard.dart';

/// 当前有选区的那些消息层。可能不止一个，所以按集合收。
final Set<VoidCallback> _activeClears = <VoidCallback>{};

/// 点屏幕时把所有选区都清掉。壳层（`HomeShell`）在"短按且没移动"时调用。
void clearMessageSelection() {
  if (_activeClears.isEmpty) return;
  final clears = List<VoidCallback>.of(_activeClears);
  _activeClears.clear();
  for (final clear in clears) {
    clear();
  }
}

/// 一处的选区起来了：先把别处的收掉，再把这处登记上。
///
/// 每一条消息是**彼此独立**的 `SelectableRegion`，框架那套"只能选一处"管不到
/// 跨消息，所以要自己收。`MessageSelection` 也走这里，两个实现共用一本账。
void ownSelection(VoidCallback clear) {
  for (final other in List<VoidCallback>.of(_activeClears)) {
    if (other != clear) other();
  }
  _activeClears.add(clear);
}

/// 这处没有选区了：撤掉登记，点屏幕时不再找它。
void releaseSelection(VoidCallback clear) => _activeClears.remove(clear);

class MessageSelectionArea extends StatefulWidget {
  const MessageSelectionArea({super.key, required this.child});

  final Widget child;

  @override
  State<MessageSelectionArea> createState() => _MessageSelectionAreaState();
}

class _MessageSelectionAreaState extends State<MessageSelectionArea> with AutomaticKeepAliveClientMixin {
  final GlobalKey<SelectionAreaState> _areaKey = GlobalKey<SelectionAreaState>();
  late final VoidCallback _clearCallback = _clear;

  /// 选区不需要焦点：框架在区域丢焦点时就清选区（见文件头）。
  final FocusNode _focus = FocusNode(canRequestFocus: false, skipTraversal: true, debugLabel: 'message-selection');

  SwipeHold? _hold;
  bool _hasSelection = false;

  @override
  bool get wantKeepAlive => _hasSelection;

  void _onSelectionChanged(SelectedContent? content) {
    // 与 message_selection.dart 同一条：手柄收到一处、内容为空时选区还开着，也算在册。
    final has = content != null && (content.plainText.trim().isNotEmpty || _hasSelection);
    if (has == _hasSelection) return;
    setState(() => _hasSelection = has);
    updateKeepAlive();
    if (has) {
      // 一次只留一个选区（He 2026-11-21 的截图：好几个高亮、点一下只清一个）。
      ownSelection(_clearCallback);
      _hold ??= SwipeHold();
    } else {
      _hold?.release();
      _hold = null;
      releaseSelection(_clearCallback);
    }
  }

  void _clear() => _areaKey.currentState?.selectableRegion.clearSelection();

  @override
  void dispose() {
    releaseSelection(_clearCallback);
    _hold?.release();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SelectionArea(
      key: _areaKey,
      focusNode: _focus,
      onSelectionChanged: _onSelectionChanged,
      child: widget.child,
    );
  }
}

/// 一次按下到抬起是不是"点了一下"：[slop] 内没移动、也没超过 [maxMs]。
bool isTapGesture(Offset from, Offset to, Duration elapsed, {double slop = kTouchSlop, int maxMs = 300}) =>
    (to - from).distance <= slop && elapsed.inMilliseconds <= maxMs;
