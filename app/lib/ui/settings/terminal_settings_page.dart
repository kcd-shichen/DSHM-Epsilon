// 终端设置：字号、光标形状、光标闪烁。
//
// 三样东西的真源都在 `NativeTerminal` 的 ValueNotifier 上——改完立刻下发给所有
// 已挂载的终端视图，并且立即持久化。这一页只是它们的界面。
//
// 为什么单开一页而不是塞进「界面」：那一页管的是应用壳（首页、语言、通知），
// 终端是另一块面，设置项还会长（字体、调色板、键栏），先把入口立起来。

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../mod/native_terminal.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import 'settings_screen.dart';
import 'settings_widgets.dart';

/// 字号可选项（dp）。和原生 `TerminalView.setTextSize` 收的值同一个单位。
const terminalFontSizes = <double>[10, 12, 14, 16, 18, 20, 22];

/// 光标闪烁可选项（毫秒）。0 = 不闪，与 Termux 的 terminal-cursor-blink-rate 同义。
const terminalCursorBlinkRates = <int>[0, 300, 500, 800];

class TerminalSettingsPage extends StatelessWidget {
  const TerminalSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AppPage.list(
      title: l10n.terminalSettingsTitle,
      children: [
        SettingsSection(
          title: l10n.terminalSectionAppearance,
          children: [
            ValueListenableBuilder<double>(
              valueListenable: NativeTerminal.fontDp,
              builder: (context, fontDp, _) => SettingsSegmentTile<double>(
                icon: AppIcons.textSize,
                tint: SettingsHues.appearance,
                title: l10n.terminalSettingsFontSize,
                segments: [
                  for (final size in terminalFontSizes)
                    PillSegment<double>(size, size == fontDp ? '${size.toInt()} •' : '${size.toInt()}'),
                ],
                selected: fontDp,
                onChanged: NativeTerminal.setFontDp,
              ),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.terminalSectionCursor,
          children: [
            ValueListenableBuilder<int>(
              valueListenable: NativeTerminal.cursorStyle,
              builder: (context, style, _) => SettingsSegmentTile<int>(
                icon: AppIcons.selectText,
                tint: SettingsHues.appearance,
                title: l10n.terminalSettingsCursorShape,
                segments: [
                  PillSegment<int>(0, l10n.terminalCursorBlock),
                  PillSegment<int>(1, l10n.terminalCursorUnderline),
                  PillSegment<int>(2, l10n.terminalCursorBar),
                ],
                selected: style,
                onChanged: NativeTerminal.setCursorStyle,
              ),
            ),
            ValueListenableBuilder<int>(
              valueListenable: NativeTerminal.cursorBlinkMs,
              builder: (context, blink, _) => SettingsSegmentTile<int>(
                icon: AppIcons.terminal,
                tint: SettingsHues.appearance,
                title: l10n.terminalSettingsCursorBlink,
                segments: [
                  for (final ms in terminalCursorBlinkRates)
                    PillSegment<int>(ms, ms == 0 ? l10n.terminalCursorBlinkOff : '${ms}ms'),
                ],
                selected: blink,
                onChanged: NativeTerminal.setCursorBlinkMs,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
