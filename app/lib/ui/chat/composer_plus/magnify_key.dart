// 草稿高过输入框时冒出来的那颗「放大」键。
//
// 从 composer.dart 搬出来（原 `_MagnifyKey`）。理由见 docs/DSH-LSP-输入条搬迁.md。
//
// 收键盘时它就是发送栏顶上那半颗（「1」）：和那条键同一身衣服；键盘开着时栏缩成
// 一颗圆、它退回原来那颗裸符号 —— 只看这把 [fill]。
//
// 底色只有一层（`CircleBorder` + 主色，透明度 = [fill]）。
// 试过再叠一层"从底边中点涨满"的圆，He 2026-11-24 判：能感觉到掉帧 → 撤了。

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../common/pressable.dart';
import '../../theme/app_icons.dart';
import '../../theme/motion.dart';
import '../../theme/theme.dart';

class MagnifyKey extends StatelessWidget {
  const MagnifyKey({super.key, required this.onPressed, this.fill = 0, this.size = 36});

  final VoidCallback onPressed;

  /// 0 = 裸符号（原来那一态）；1 = 主色底（发送栏分出来的那半颗）。
  final double fill;

  /// 与发送键同高（36）。搬出来后不引用 composer 的私有常量，改由参数给。
  final double size;

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
        dimension: size,
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
