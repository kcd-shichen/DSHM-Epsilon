// 输入条右栏那一格：高度由 `_open` 逐帧从 36 长到整列，靠**布局**给到子树，
// 子树（键、Semantics、InkWell）一次都不重建。
//
// 从 composer.dart 搬出来（原 `_KeyRail` / `_RenderKeyRail`）。理由见
// docs/DSH-LSP-输入条搬迁.md：上游永远不会碰这个文件。
//
// 两个尺寸由调用方给（`size` = 键的边长，`slot` = ⛶ 那一格让出的高度），
// 不在这里另立常量——免得同一个数在两处漂。

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

class KeyRail extends SingleChildRenderObjectWidget {
  const KeyRail({
    super.key,
    required this.open,
    required this.split,
    required this.keySize,
    required this.slot,
    super.child,
  });

  final Animation<double> open;

  /// ⛶ 占掉上面那一格（1 = 占着）。
  final double split;

  /// 键的边长（36）。
  final double keySize;

  /// ⛶ 那一格让出的高度（9）。
  final double slot;

  @override
  RenderKeyRail createRenderObject(BuildContext context) =>
      RenderKeyRail(open: open, split: split, keySize: keySize, slot: slot);

  @override
  void updateRenderObject(BuildContext context, RenderKeyRail renderObject) {
    renderObject
      ..open = open
      ..split = split
      ..keySize = keySize
      ..slot = slot;
  }
}

class RenderKeyRail extends RenderShiftedBox {
  RenderKeyRail({required Animation<double> open, required double split, required double keySize, required double slot})
    : _open = open,
      _split = split,
      _keySize = keySize,
      _slot = slot,
      super(null);

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

  double _keySize;
  set keySize(double value) {
    if (value == _keySize) return;
    _keySize = value;
    markNeedsLayout();
  }

  double _slot;
  set slot(double value) {
    if (value == _slot) return;
    _slot = value;
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
  void performLayout() {
    final child = this.child;
    final height = constraints.maxHeight;
    if (child == null) {
      size = constraints.constrain(Size(_keySize, height));
      return;
    }
    // 这一列有多高：键从 36 长到它；⛶ 在上头时让出那一格和那道缝。
    final room = math.max(_keySize, height - (_keySize + _slot) * _split);
    final grown = ui.lerpDouble(_keySize, room, 1 - _open.value)!;
    child.layout(BoxConstraints.tightFor(width: _keySize, height: grown), parentUsesSize: true);
    size = constraints.constrain(Size(_keySize, height));
    (child.parentData! as BoxParentData).offset = Offset(0, math.max(0.0, height - grown));
  }
}
