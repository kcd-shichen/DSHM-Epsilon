// 撤销 / 重做那对弯箭头（全屏编辑页用）。
//
// 从 composer.dart 搬出来（原 `_BentArrow`）。理由见 docs/DSH-LSP-输入条搬迁.md：
// 纯自绘的符号，上游永远不会碰它，放在自有文件里零冲突。

import 'package:flutter/material.dart';

/// 一条向左弯下去的回形箭头；[forward] 为真时镜像成向右（重做）。
class BentArrow extends StatelessWidget {
  const BentArrow({super.key, required this.size, required this.color, required this.forward});

  final double size;
  final Color color;

  /// true = 重做（↷，箭头尖在右）。
  final bool forward;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: BentArrowPainter(color, forward));
}

class BentArrowPainter extends CustomPainter {
  const BentArrowPainter(this.color, this.forward);

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
  bool shouldRepaint(BentArrowPainter oldDelegate) => oldDelegate.color != color || oldDelegate.forward != forward;
}
