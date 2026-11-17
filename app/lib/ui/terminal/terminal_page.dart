// The conversation's terminal (the official web client's right-sidebar
// terminal, dsh-client-ui-sidebar-terminal) as a full-screen phone page:
// capsule tabs over one dark terminal card, the key row above the keyboard.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart' show RuntimeSupport, TerminalShell;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../mod/native_terminal.dart';
import '../../state/android_features.dart';
import '../../state/runtime_capabilities_state.dart';
import '../../state/terminal_state.dart';
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../common/empty_view.dart';
import '../common/feature_tile.dart';
import '../common/list_page_row.dart';
import '../common/pressable.dart';
import '../common/sheet_navigator.dart';
import '../common/sheet_title_bar.dart';
import '../common/side_insets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../../mod/native_terminal.dart';
import '../workspace/text_prompt.dart';
import 'terminal_keys.dart';
import 'terminal_palette.dart';
import 'terminal_screen.dart';

/// The conversation's terminal (a full-screen detail page): the bar with
/// 「终端」 over the current directory, a row of capsule tabs, then one dark
/// terminal card whose bottom slot is the key row above the keyboard.
///
/// Leaving the page only disconnects: the terminal keeps running in the engine
/// and reattaches on return. Only closing a tab ends its process.
class TerminalPage extends ConsumerStatefulWidget {
  const TerminalPage({super.key, required this.sessionId});

  final String sessionId;

  static Route<void> route(String sessionId) =>
      MaterialPageRoute<void>(builder: (_) => TerminalPage(sessionId: sessionId));

  /// Side and bottom inset of the card; the top bar's buttons sit on the same
  /// 12 line.
  static const gutter = 12.0;
  /// 顶栏（胶囊那一行）的高度。终端从这里往下起排——留白够，第一行才不像被削掉。
  static const barHeight = 72.0;
  static const tabsHeight = 48.0;

  @override
  ConsumerState<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends ConsumerState<TerminalPage> {
  final _focus = FocusNode(debugLabel: 'terminal');
  final _modifiers = TerminalModifiers();
  late final AppLifecycleListener _lifecycle;

  NotifierProvider<TerminalWorkspace, TerminalWorkspaceState> get _provider =>
      terminalWorkspaceProvider(widget.sessionId);

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () => ref.read(_provider.notifier).reconnectAll());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _focus.dispose();
    _modifiers.dispose();
    super.dispose();
  }

  // ── Actions ──

  Future<void> _showActions(TerminalTab tab) {
    final workspace = ref.read(_provider.notifier);
    return showAppSheet<void>(
      context,
      isScrollControlled: true,
      builder: (sheet) => SheetNavigator(
        root: (_) => _TabActions(
          title: tab.title.isEmpty ? appL10n.botsTerminal : tab.title,
          onRename: () {
            Navigator.of(sheet).pop();
            unawaited(_rename(tab));
          },
          loadShells: workspace.shells,
          onNew: (shell) {
            Navigator.of(sheet).pop();
            unawaited(workspace.newTerminal(shellPath: shell?.path));
          },
          onClose: () {
            Navigator.of(sheet).pop();
            unawaited(_close(tab));
          },
          fontSize: NativeTerminal.fontDp.value,
          onFontSize: (dp) => NativeTerminal.fontDp.value = dp,
        ),
      ),
    );
  }

  Future<void> _rename(TerminalTab tab) async {
    final next = await showTextPrompt(
      context,
      title: appL10n.botsTerminalRename,
      initial: tab.title,
      hint: appL10n.botsTerminalName,
      maxLength: 120,
    );
    if (next == null || next.isEmpty || next == tab.title || !mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await ref.read(_provider.notifier).rename(tab.id, next);
    if (!ok) messenger?.showSnackBar(SnackBar(content: Text(appL10n.botsTerminalRenameFailed)));
  }

  Future<void> _close(TerminalTab tab) async {
    if (tab.phase == TerminalPhase.live && (tab.info?.running ?? false)) {
      final ok = await showAppDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(appL10n.botsTerminalCloseNamed(tab.title.isEmpty ? appL10n.botsTerminal : tab.title)),
          content: Text(appL10n.botsTerminalCloseBody),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(appL10n.commonCancel)),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: DshColors.of(dialog).danger,
                foregroundColor: DshColors.of(dialog).onDanger,
              ),
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(appL10n.commonClose),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    ref.read(_provider.notifier).closeTab(tab.id);
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final state = ref.watch(_provider);
    final workspace = ref.read(_provider.notifier);
    final selected = state.selected;
    final padding = MediaQuery.paddingOf(context);
    final cwd = selected?.info?.cwd ?? state.environment?.cwd ?? '';
    // HarmonyOS's own engine has no PTY and says so; asked before the first attach fails.
    final ohos = ref.watch(operatingSystemProvider) == 'ohos';
    final capabilities = ohos ? ref.watch(runtimeCapabilitiesProvider) : null;
    final noPty = capabilities?.value?.shell.pty == RuntimeSupport.unsupported;

    final Widget body;
    if (state.offline) {
      body = Center(
        child: EmptyView(icon: AppIcons.offline, title: TerminalCopy.offline),
      );
    } else if (!state.supported || noPty) {
      body = Center(
        child: EmptyView(
          art: FeatureTile(FeatureKind.terminal, size: FeatureTile.empty),
          title: l10n.botsTerminalUnsupported,
          message: noPty
              ? l10n.harmonyTerminalNoPty
              : (ohos ? l10n.harmonyTerminalSupportedHosts : l10n.botsTerminalSupportedHosts),
        ),
      );
    } else if (capabilities?.isLoading ?? false) {
      body = TerminalCardPlaceholder(label: l10n.botsTerminalOpening);
    } else if (state.error case final error?) {
      body = Center(
        child: EmptyView(
          icon: AppIcons.offline,
          title: error,
          actionLabel: l10n.commonRetry,
          onAction: workspace.reload,
        ),
      );
    } else if (state.loading) {
      body = TerminalCardPlaceholder(label: l10n.botsTerminalOpening);
    } else if (selected == null) {
      body = Center(
        child: EmptyView(
          art: const FeatureTile(FeatureKind.terminal, size: FeatureTile.empty),
          title: l10n.botsTerminalNone,
          actionLabel: l10n.botsTerminalNew,
          onAction: () => unawaited(workspace.newTerminal()),
        ),
      );
    } else {
      final screen = TerminalScreen(
        sessionId: widget.sessionId,
        tab: selected,
        focusNode: _focus,
        modifiers: _modifiers,
      );
      // 原生终端要直角、四面到底：不再套那层圆角卡片壳。
      body = NativeTerminal.enabled ? screen : TerminalCardFrame(child: screen);
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dshSystemOverlay(theme.brightness),
      child: AppBackdrop(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          // A phone on its side: clear of the cutout on both sides.
          body: SideSafeArea(
            child: Padding(
              padding: EdgeInsets.only(top: padding.top),
              // T22：终端铺满整页，顶栏改成浮层。
              //
              // 终端是 Android 平台视图（hybrid composition），它被画在 Flutter
              // 画布之上，所以压在它上面的东西只能走 overlay surface——这就是
              // Stack 的用处。`clipBehavior: Clip.none` 是这里的要害：默认的
              // `Clip.hardEdge` 会让引擎为了"裁剪平台视图"塞一层 FlutterImageView
              // 回来，那一层是不透明的，终端会被整块盖住（T21 的现象：满屏黑、无字、
              // 打字有去无回）。
              child: Stack(
                fit: StackFit.expand,
                clipBehavior: Clip.none,
                children: <Widget>[
                  // 顶栏下面那条带子必须是终端自己的底色：原来它是页面背景（浅一档），
                  // 和终端本体接出一条硬边，看着像内容被截断。原生那边的顶部羽化
                  // 也是往这个颜色淡，所以两边必须同源（都由 TerminalPalette 决定）。
                  if (NativeTerminal.enabled)
                    Positioned.fill(child: ColoredBox(color: TerminalPalette.of(context).background)),
                  // T22：终端从胶囊下方起排。行不能铺到胶囊底下——空屏时 prompt
                  // 就在第一行，压在胶囊下面等于看不见（#51/#52 的"全黑"就是这个）。
                  Padding(
                    // 终端仍然左右全屏：文字行的留白由原生侧做（setSideInset），
                    // 视图本身不缩窄。
                    padding: EdgeInsets.only(top: TerminalPage.barHeight, bottom: padding.bottom),
                    child: body,
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: _TopBar(
                      title: selected?.title ?? '',
                      subtitle: _directoryName(cwd),
                      onActions: selected == null ? null : () => unawaited(_showActions(selected)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Last path segment of the shell's starting directory.
  static String _directoryName(String path) {
    final trimmed = path.endsWith('/') && path.length > 1 ? path.substring(0, path.length - 1) : path;
    if (trimmed.isEmpty) return '';
    if (trimmed == '/') return '/';
    return trimmed.split('/').last;
  }
}

/// 一短一长一短:圆钮 · 长胶囊 · 圆钮。
///
/// 长胶囊就是"终端会话的标题"——`bash` 是它的主行,目录是副行;点它打开
/// 重命名 / 新建 / 关闭。tab 行不再单独存在(T17 定的版式)。
class _TopBar extends StatelessWidget {
  const _TopBar({required this.title, required this.subtitle, required this.onActions});

  final String title;
  final String subtitle;
  final VoidCallback? onActions;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final fill = dark ? Colors.white.withValues(alpha: 0.10) : scheme.onSurface.withValues(alpha: 0.06);
    final name = title.isEmpty ? l10n.botsTerminal : title;
    return SizedBox(
      height: TerminalPage.barHeight,
      child: BackdropGroup(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: TerminalPage.gutter),
          child: Row(
            children: [
              GlassIconButton(
                key: const ValueKey('terminal-back'),
                icon: AppIcons.back,
                tooltip: l10n.commonBack,
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Pressable(
                  onTap: onActions,
                  semanticLabel: name,
                  child: Container(
                    height: 44,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: ShapeDecoration(color: fill, shape: const StadiumBorder()),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // 两行是"标题 + 目录"，不是两段正文：行高压到 1.1、
                        // 副标题再小一档，整块才会往中心收，不散在 44 高里。
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(height: 1.1),
                        ),
                        if (subtitle.isNotEmpty)
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppType.monoLabel(
                              color: DshColors.of(context).textTertiary,
                            ).copyWith(fontSize: 10.5, height: 1.1),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Same width either way keeps the capsule centred.
              if (onActions == null)
                const SizedBox(width: 44)
              else
                GlassIconButton(
                  key: const ValueKey('terminal-more'),
                  icon: AppIcons.more,
                  tooltip: l10n.commonMore,
                  onPressed: onActions,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 重命名 · 新建终端(选 Shell) · 关闭终端.
class _TabActions extends StatelessWidget {
  const _TabActions({
    required this.title,
    required this.onRename,
    required this.loadShells,
    required this.onNew,
    required this.onClose,
    required this.fontSize,
    required this.onFontSize,
  });

  final String title;
  final VoidCallback onRename;
  final Future<List<TerminalShell>> Function() loadShells;
  final ValueChanged<TerminalShell?> onNew;
  final VoidCallback onClose;
  final double fontSize;
  final ValueChanged<double> onFontSize;

  static const _margin = EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(title),
            SheetGroup(
              margin: _margin,
              children: [
                ListPageRow(icon: AppIcons.rename, title: l10n.commonRename, chevron: false, onTap: onRename),
                ListPageRow(
                  icon: AppIcons.add,
                  title: l10n.botsTerminalNew,
                  onTap: () =>
                      SheetNavigator.of(context).push((_) => _ShellPicker(loadShells: loadShells, onPick: onNew)),
                ),
                // 字号：原生分支的手势归平台视图，双指缩放不可靠，改成这里设。
                ListPageRow(
                  icon: AppIcons.selectText,
                  title: '字号',
                  value: '${fontSize.toStringAsFixed(0)}sp',
                  onTap: () => SheetNavigator.of(context).push(
                    (_) => _FontSizePicker(value: fontSize, onPick: onFontSize),
                  ),
                ),
              ],
            ),
            SheetGroup(
              margin: _margin,
              children: [
                ListPageRow(
                  icon: AppIcons.close,
                  title: l10n.botsTerminalClose,
                  danger: true,
                  chevron: false,
                  onTap: onClose,
                ),
              ],
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}

/// Installed shells; the first is the environment's default.
class _ShellPicker extends StatefulWidget {
  const _ShellPicker({required this.loadShells, required this.onPick});

  final Future<List<TerminalShell>> Function() loadShells;
  final ValueChanged<TerminalShell?> onPick;

  @override
  State<_ShellPicker> createState() => _ShellPickerState();
}

class _ShellPickerState extends State<_ShellPicker> {
  late Future<List<TerminalShell>> _shells = widget.loadShells();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(l10n.botsTerminalChooseShell),
            FutureBuilder<List<TerminalShell>>(
              future: _shells,
              builder: (context, snapshot) {
                final shells = snapshot.data;
                final List<Widget> rows;
                if (snapshot.hasError) {
                  rows = [
                    ListPageRow(
                      icon: AppIcons.refresh,
                      title: l10n.botsTerminalShellFailed,
                      meta: l10n.commonRetry,
                      onTap: () => setState(() => _shells = widget.loadShells()),
                    ),
                  ];
                } else if (shells == null) {
                  rows = [
                    ListPageRow(
                      leading: const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 1.6)),
                      title: l10n.botsTerminalReading,
                      titleStyle: TextStyle(color: colors.textTertiary),
                    ),
                  ];
                } else if (shells.isEmpty) {
                  rows = [
                    ListPageRow(
                      icon: AppIcons.terminal,
                      title: l10n.botsTerminalDefaultShell,
                      onTap: () => widget.onPick(null),
                    ),
                  ];
                } else {
                  rows = [
                    for (final shell in shells)
                      ListPageRow(
                        icon: AppIcons.terminal,
                        title: shell.name,
                        subtitle: shell.path,
                        chevron: false,
                        onTap: () => widget.onPick(shell),
                      ),
                  ];
                }
                return SheetGroup(margin: _TabActions._margin, children: rows);
              },
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}

/// 字号选择：10–28sp，滑块拖动时实时生效（能看到字在变），确认后关闭。
class _FontSizePicker extends StatefulWidget {
  const _FontSizePicker({required this.value, required this.onPick});

  final double value;
  final ValueChanged<double> onPick;

  @override
  State<_FontSizePicker> createState() => _FontSizePickerState();
}

class _FontSizePickerState extends State<_FontSizePicker> {
  late double _value = widget.value;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetTitleBar('字号'),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: _value,
                    min: 10,
                    max: 28,
                    divisions: 18,
                    label: '${_value.toStringAsFixed(0)}sp',
                    onChanged: (v) {
                      setState(() => _value = v);
                      widget.onPick(v);
                    },
                  ),
                ),
                SizedBox(
                  width: 48,
                  child: Text(
                    '${_value.toStringAsFixed(0)}sp',
                    textAlign: TextAlign.end,
                    style: AppType.monoLabel(color: DshColors.of(context).textTertiary),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('完成'),
            ),
          ],
        ),
      ),
    );
  }
}
