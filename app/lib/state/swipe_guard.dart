// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;

/// 横滑闸：正在打字的时候，把左右滑（会话信息栏 / 会话列表）按住。
///
/// 引用计数而不是布尔——可能同时有两处持有：输入框聚焦、全屏输入页开着。
/// 计数归零才放行，所以谁先松手都不会把另一个的闸弄丢。
///
/// 只挡"从空白处起手"的横滑；[ChatScreen] 里的横竖滚动、内容区的横向拖动
/// 都不在此列，它们各有各的识别器。
final ValueNotifier<int> swipeGuard = ValueNotifier<int>(0);

/// 拿一次闸，用完 [release]。**必须成对**，漏掉一次横滑就永久失灵，
/// 所以只在 `initState`/`dispose` 或者 push 前后成对使用。
class SwipeHold {
  SwipeHold() {
    _held = true;
    swipeGuard.value++;
  }

  bool _held = false;

  void release() {
    if (!_held) return;
    _held = false;
    if (swipeGuard.value > 0) swipeGuard.value--;
  }
}


/// 包一层 [SelectionArea]：**有选区就压着横滑闸**，选区清掉就放开。
///
/// 这就是"选中文本时屏蔽左右滑"那半条：手指在消息里拖选的时候，
/// 从左边起手不该把会话抽屉拽出来。
class SelectionSwipeGuard extends StatefulWidget {
  const SelectionSwipeGuard({super.key, required this.child});

  final Widget child;

  @override
  State<SelectionSwipeGuard> createState() => _SelectionSwipeGuardState();
}

class _SelectionSwipeGuardState extends State<SelectionSwipeGuard> {
  SwipeHold? _hold;

  void _changed(SelectedContent? content) {
    final has = content != null && content.plainText.trim().isNotEmpty;
    if (has) {
      _hold ??= SwipeHold();
    } else {
      _hold?.release();
      _hold = null;
    }
  }

  @override
  void dispose() {
    _hold?.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SelectionArea(onSelectionChanged: _changed, child: widget.child);
}
