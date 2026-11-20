// 原 terminal_keys.dart：Dart 侧的键栏（十二格 ExtraKeysRow、粘滞 Ctrl/Alt、
// TerminalExtraKey 表）随 C1（2026-11-20）整条删除——键栏现在在原生侧
// （TerminalExtraKeysRow.kt），修饰键的粘滞状态也住在 Termux 的 ExtraKeysView 里。
//
// 这里只剩状态条：占位卡片的底槽用它显示「正在打开…」。

import 'package:flutter/material.dart';

import 'terminal_palette.dart';

/// 状态槽的高度（按钮 36，上下各 8）。
const double _barHeight = 52.0;
const double _keyHeight = 36.0;

class TerminalStatusBar extends StatelessWidget {
  const TerminalStatusBar({super.key, required this.label, this.busy = false, this.actionLabel, this.onAction});

  final String label;
  final bool busy;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = TerminalPalette.of(context);
    return SizedBox(
      height: _barHeight,
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: (_barHeight - _keyHeight) / 2),
        child: Row(
          children: [
            if (busy) ...[
              SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 1.6, color: palette.muted)),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(color: palette.muted),
              ),
            ),
            if (actionLabel case final action?)
              SizedBox(
                height: _keyHeight,
                child: TextButton(
                  key: const ValueKey('terminal-status-action'),
                  onPressed: onAction,
                  style: TextButton.styleFrom(
                    foregroundColor: palette.foreground,
                    backgroundColor: Colors.white.withValues(alpha: 0.1),
                    shape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    minimumSize: const Size(0, _keyHeight),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: theme.textTheme.labelLarge,
                  ),
                  child: Text(action),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
