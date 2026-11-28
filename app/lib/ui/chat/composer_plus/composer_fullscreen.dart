// 输入条的全屏编辑页：草稿高过输入框时，从「放大」键推进来的那一页。
//
// 从 composer.dart 搬出来（原 `_ComposerFullscreen` / `_ComposerFullscreenState`）。
// 理由见 docs/DSH-LSP-输入条搬迁.md：上游永远不会碰这个文件。
//
// 左上角是撤回 / 重做（没有可撤回的动作时是灰的），右上角还是那颗四角括号，
// 展开只换颜色——染强调色，再点一下收起。

import 'package:flutter/material.dart';

import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import 'bent_arrow.dart';
import 'draft_history.dart';

class ComposerFullscreen extends StatefulWidget {
  const ComposerFullscreen({
    super.key,
    required this.controller,
    required this.history,
    required this.style,
    required this.hint,
    this.keySize = 36,
  });

  final TextEditingController controller;
  final DraftHistory history;
  final TextStyle? style;
  final String hint;

  /// 右上角那颗键的边长（与发送键同高）。
  final double keySize;

  @override
  State<ComposerFullscreen> createState() => _ComposerFullscreenState();
}

class _ComposerFullscreenState extends State<ComposerFullscreen> {
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
                          icon: BentArrow(
                            size: 20,
                            forward: false,
                            color: widget.history.canUndo
                                ? Theme.of(context).colorScheme.onSurface
                                : DshColors.of(context).textTertiary,
                          ),
                        ),
                        IconButton(
                          onPressed: widget.history.canRedo ? widget.history.redo : null,
                          icon: BentArrow(
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
                    dimension: widget.keySize,
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
