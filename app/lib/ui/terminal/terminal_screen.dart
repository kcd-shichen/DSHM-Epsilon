// The dark terminal card of the terminal page — one tab's screen.
//
// C1（2026-11-20）：Dart 侧的 xterm 面板整条删掉了，原生终端是唯一路径。
// 这个文件只剩三样东西：卡片壳、占位卡、把字节转发给平台视图的那一层。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../dev/screen_probe.dart';
import '../../mod/native_terminal.dart';
import '../../state/terminal_state.dart';
import '../theme/theme.dart';
import 'terminal_keys.dart';
import 'terminal_palette.dart';

/// The card shell: the engine log card's dark surface (dark in both themes),
/// with the dark theme inside so buttons and empty states read on it.
class TerminalCardFrame extends StatelessWidget {
  const TerminalCardFrame({super.key, required this.child});

  final Widget child;

  /// The dark theme of the current palette (light mode keeps the card dark).
  static final _darkThemes = <AppAccent, ThemeData>{};

  static ThemeData _darkThemeFor(AppAccent accent) {
    if (_darkThemes.length > 4) _darkThemes.clear();
    return _darkThemes.putIfAbsent(accent, () => buildDarkTheme(accent: accent));
  }

  @override
  Widget build(BuildContext context) {
    final ambient = Theme.of(context);
    final palette = TerminalPalette.of(context);
    return Theme(
      data: ambient.brightness == Brightness.dark ? ambient : _darkThemeFor(DshSurfaces.of(context).accent),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: palette.background,
          shape: RoundedSuperellipseBorder(
            borderRadius: AppShape.radiusLg,
            side: BorderSide(color: palette.hairline, width: 0.5),
          ),
        ),
        child: ClipRSuperellipse(
          borderRadius: AppShape.radiusLg,
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    );
  }
}

/// A card with nothing but a status in its bottom slot (loading the list).
class TerminalCardPlaceholder extends StatelessWidget {
  const TerminalCardPlaceholder({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return TerminalCardFrame(
      child: Column(
        children: [
          const Spacer(),
          _Divider(),
          TerminalStatusBar(label: label, busy: true),
        ],
      ),
    );
  }
}

/// One tab's screen inside the card.
class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({super.key, required this.sessionId, required this.tab});

  final String sessionId;
  final TerminalTab tab;

  @override
  ConsumerState<TerminalScreen> createState() => TerminalScreenState();
}

class TerminalScreenState extends ConsumerState<TerminalScreen> {
  TerminalTab get _tab => widget.tab;

  TerminalWorkspace get _workspace =>
      ref.read(terminalWorkspaceProvider(widget.sessionId).notifier);

  @override
  Widget build(BuildContext context) {
    ScreenProbe.hit('screen');
    final tab = _tab;
    // 铺满整页、不留 gutter——顶栏浮在它上面（T17）。
    // 底部安全区由调用方（terminal_page）让出，按键栏仍然贴在键盘上方。
    return NativeTerminalView(
      id: tab.id,
      onInput: (data) => _workspace.send(tab.id, data),
      onResize: (cols, rows) => _workspace.resize(tab.id, cols, rows),
    );
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(height: 0.5, color: TerminalPalette.of(context).hairline);
}
