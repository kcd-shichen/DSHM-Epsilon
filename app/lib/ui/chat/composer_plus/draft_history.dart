// 输入条的草稿撤销 / 重做。
//
// 原来住在 composer.dart 里（`_DraftHistory`）。搬出来的理由只有一个：
// composer.dart 是我们的**厚账**——上游一改输入条就要解一堆冲突。纯自有的东西
// 放在自有文件里，上游永远不会碰到它（见 docs/DSH-LSP-输入条搬迁.md）。

import 'package:flutter/widgets.dart';

/// 一串快照：每次改动记一笔，撤销就退回去，重做再取回来。
///
/// 只比文本，不比选区——光标位置跟着快照走，但同一段文字连续输入只记一笔。
class DraftHistory extends ChangeNotifier {
  DraftHistory(this.controller) {
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
