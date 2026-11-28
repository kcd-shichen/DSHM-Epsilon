// 输入条的内距：跟着 `_open`（键盘开合）与 `_snug`（折行与否）在两组值之间插值。
//
// 从 composer.dart 搬出来（原 `_OpenPadding` / `_RenderOpenPadding`）。
// 理由见 docs/DSH-LSP-输入条搬迁.md：上游永远不会碰这个文件。
//
// 全在**布局**里做：每帧只走一次 layout，widget 树一次都不重建。

import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 内距由 `max(open, snug)` 插值：收起态到展开态、单行到折行，两个来源取大者。
class OpenPadding extends SingleChildRenderObjectWidget {
  const OpenPadding({
    super.key,
    required this.open,
    required this.snug,
    required this.closed,
    required this.wide,
    super.child,
  });

  final Animation<double> open;
  final Animation<double> snug;
  final EdgeInsets closed;
  final EdgeInsets wide;

  @override
  RenderOpenPadding createRenderObject(BuildContext context) =>
      RenderOpenPadding(open: open, snug: snug, closed: closed, wide: wide);

  @override
  void updateRenderObject(BuildContext context, RenderOpenPadding renderObject) {
    renderObject
      ..open = open
      ..snug = snug
      ..closed = closed
      ..wide = wide;
  }
}

class RenderOpenPadding extends RenderShiftedBox {
  RenderOpenPadding({
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
