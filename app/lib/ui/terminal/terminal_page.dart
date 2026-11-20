// The conversation's terminal (the official web client's right-sidebar
// terminal, dsh-client-ui-sidebar-terminal) as a full-screen phone page:
// capsule tabs over one dark terminal card, the key row above the keyboard.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart' show RuntimeSupport, TerminalShell;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../dev/screen_probe.dart';
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
import '../workspace/text_prompt.dart';
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

/// [TerminalPage] 的语义切片：只装"变了就必须整页重画"的字段。
typedef _Slice = (
  bool, bool, String?, bool,
  String?, int,
  String?, Object?, bool?,
  String?, Object?, String?, String?,
);

class _TerminalPageState extends ConsumerState<TerminalPage> {
  /// 菜单键要把侧栏拉出来，所以得捏着 Scaffold 的 state。
  final _scaffoldKey = GlobalKey<ScaffoldState>();
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

  // ── 重建面收窄 ──
  //
  // B1 读数（#93）：page/screen/native/topbar 四个计数分毫不差 = 零隔离，
  // 平台视图被整页重建拖着一起重建。
  //
  // #97 先断了重建链：把两棵贵的子树（终端 body、顶栏）按语义记录缓存成
  // Widget 实例，输入不变就交回同一个实例，`Element.updateChild` 认出
  // identical 直接跳过整棵子树。读数验证 page.reuse 100%，子树三个计数归零。
  //
  // #98 再断驱动源：`page` 仍然按**每次方向键**涨一次（+16~27/2s），说明
  // provider 每按一键就发一个新状态。改成 `select` 语义切片，字段没变的
  // 更新不再触发整页重建。缓存留着当第二道闸。
  Object? _cacheKey;
  Widget? _cacheBody;
  Widget? _cacheBar;
  Object? _treeKey;
  Widget? _tree;
  Object? _lastSlice;

  /// 页面真正依赖的字段。改这里之前先问一句：它变了，整页非得重建吗？
  static _Slice _slice(TerminalWorkspaceState s) => (
    s.offline, s.supported, s.error, s.loading,
    s.selectedId, s.tabs.length,
    s.selected?.title, s.selected?.phase, s.selected?.writable,
    s.selected?.message, s.selected?.terminal, s.selected?.info?.cwd,
    s.environment?.cwd,
  );

  @override
  Widget build(BuildContext context) {
    ScreenProbe.hit('page');
    final l10n = context.l10n;
    final theme = Theme.of(context);
    // #98：**不再 watch 整个状态**。
    //
    // #97 的数据说明问题：拖动光标那几秒里 `page` 从 0 涨到 16~27，与按键数同阶——
    // 每按一次方向键，这条 provider 就发一次新状态，页面跟着重建一次（缓存让它
    // 便宜，但 layout 照样跑到平台视图那一层）。所以这次把依赖收窄成**语义切片**：
    // 只有切片变了页面才重建；方向键那种"发新对象但字段没变"的更新被 select 拦掉。
    final state = ref.read(_provider);
    ref.watch(_provider.select(_slice));

    // #113：分因计数。
    //
    // 页面已经不订阅 MediaQuery 了，`page` 却还有 45~91 次/2s。两个可能：
    // 切片真的变了（该重建），或者切片没变却被祖先牵着重建（白重建）。
    // 这不是理论问题——`page.slice` 与 `page.ancestor` 谁涨，下一步就动谁。
    final Object sliceNow = _slice(state);
    final bool sliceChanged = sliceNow != _lastSlice;
    _lastSlice = sliceNow;
    ScreenProbe.hit(sliceChanged ? 'page.slice' : 'page.ancestor');
    final workspace = ref.read(_provider.notifier);
    final selected = state.selected;
    // #110：内缩彻底移出这个 build。
    //
    // #103 读数：`page.tree` 命中 44/45，但 `page` 仍 ~44 次/秒、build 仍 2ms。
    // 根因是这页订阅了 MediaQuery——键盘一次抖动就把它牵着重建一遍，重建就得
    // 走 layout，一路排到平台视图。缓存只挡住了子树，挡不住这一层。
    //
    final cwd = selected?.info?.cwd ?? state.environment?.cwd ?? '';
    // HarmonyOS's own engine has no PTY and says so; asked before the first attach fails.
    final ohos = ref.watch(operatingSystemProvider) == 'ohos';
    final capabilities = ohos ? ref.watch(runtimeCapabilitiesProvider) : null;
    final noPty = capabilities?.value?.shell.pty == RuntimeSupport.unsupported;

    // 现在内缩交给帧末的 _Insets 小叶去读：本页 build 里一个 MediaQuery 都不碰，
    // 拖动光标期间 `page` 应该归零。

    // 缓存键：状态对象本身、明暗、以及顶栏要显示的那两行字。任何一样变了就重算。
    final String barTitle = selected?.title ?? '';
    final String barSubtitle = _directoryName(cwd);
    final Object bodyKey = (
      state.offline,
      state.supported,
      state.error,
      state.loading,
      selected?.id,
      selected?.title,
      selected?.phase,
      selected?.writable,
      selected?.terminal,
      selected?.message,
      selected?.info?.cwd,
      state.environment?.cwd,
      theme.brightness,
      // 侧栏要列**全部**会话，所以 tab 的增删改也必须翻缓存键。
      // 只取 id+title：tab.terminal 每次输出都会换身份，带上它缓存就废了。
      state.selectedId,
      Object.hashAll(state.tabs.map((t) => '${t.id}\u0000${t.title}')),
    );
    final reuse = bodyKey == _cacheKey && _cacheBody != null && _cacheBar != null;

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
      // 原生终端要直角、四面到底：不再套那层圆角卡片壳。
      body = TerminalScreen(
        sessionId: widget.sessionId,
        tab: selected,
      );
    }

    final Widget bar = _TopBar(
      title: barTitle,
      subtitle: barSubtitle,
      onMenu: () => _scaffoldKey.currentState?.openDrawer(),
      onActions: selected == null ? null : () => unawaited(_showActions(selected)),
    );
    // 缓存命中就交回上一次那两个实例——子树整棵跳过，一帧都不重建。
    if (!reuse) {
      _cacheKey = bodyKey;
      _cacheBody = body;
      _cacheBar = bar;
    } else {
      ScreenProbe.hit('page.reuse');
    }
    final Widget shownBody = reuse ? _cacheBody! : body;
    final Widget shownBar = reuse ? _cacheBar! : bar;

    // #100：连**整棵树**一起缓存。
    //
    // #98 的 select 切片没能压住 page 计数（仍是 19~38/2s，reuse 100%）——说明
    // 重建不是 provider 引起的，是**祖先**在牵动：页面 widget 被重新创建，build
    // 就跑一次。子树虽然靠上面的缓存保住了，但每跑一次 build 就会走一轮 layout，
    // 一路排到平台视图那层（这正是 build_avg 2.1ms 的来处）。
    //
    // 所以出口也缓存：key = (语义状态, 安全区 padding)。padding 在列是因为键盘
    // 升降必须照常重排；而光标拖动期间 padding 不变，整棵树交回同一个实例，
    // layout 一次都不跑。
    final Object treeKey = bodyKey;
    if (treeKey == _treeKey && _tree != null) {
      ScreenProbe.hit('page.tree');
      return _tree!;
    }

    final Widget tree = AnnotatedRegion<SystemUiOverlayStyle>(
      // 终端永远是深色底，状态栏图标就永远是亮的——跟着主题走会在浅色模式下
      // 变成深色图标，压在近黑底上等于看不见。
      value: dshSystemOverlay(Brightness.dark),
      child: AppBackdrop(
        child: Scaffold(
          key: _scaffoldKey,
          backgroundColor: Colors.transparent,
          drawer: _TerminalDrawer(
            tabs: state.tabs,
            selectedId: state.selectedId,
            // 抽屉不是路由，`Navigator.pop` 关不掉它、只会把终端页弹掉。
            // 收抽屉只走 ScaffoldState.closeDrawer()。
            onSelect: (id) {
              _scaffoldKey.currentState?.closeDrawer();
              ref.read(_provider.notifier).select(id);
            },
            onNew: () {
              _scaffoldKey.currentState?.closeDrawer();
              unawaited(ref.read(_provider.notifier).newTerminal());
            },
            onRename: (tab) {
              _scaffoldKey.currentState?.closeDrawer();
              unawaited(_rename(tab));
            },
            onClose: (tab) {
              _scaffoldKey.currentState?.closeDrawer();
              unawaited(_close(tab));
            },
            // 退出 = 离开终端页，这一条才真的要 pop。
            onExit: () => Navigator.of(context).maybePop(),
          ),
          // A phone on its side: clear of the cutout on both sides.
          body: SideSafeArea(
            // 底色铺满整页、**包括状态栏那一条**。
            //
            // 原来 ColoredBox 在 _Insets 里面，于是状态栏区域露的是页面背景（浅一档），
            // 和终端本体之间接出一道硬边——就是截图里那条。Android 15+ 上
            // `statusBarColor` 已经不起作用，能改的只有"谁画在那块区域"，
            // 所以底色必须提到这一层，内缩只留给内容。
            child: Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.none,
              children: <Widget>[
                Positioned.fill(child: ColoredBox(color: TerminalPalette.of(context).background)),
                _Insets(
                  top: true,
                  bottom: true,
                  // T22：终端铺满整页，顶栏改成浮层。
                  //
                  // 终端是 Android 平台视图（hybrid composition），它被画在 Flutter
                  // 画布之上，所以压在它上面的东西只能走 overlay surface——这就是
                  // Stack 的用处。`clipBehavior: Clip.none` 是这里的要害：默认的
                  // `Clip.hardEdge` 会让引擎为了"裁剪平台视图"塞一层 FlutterImageView
                  // 回来，那一层是不透明的，终端会被整块盖住（T21 的现象：满屏黑、
                  // 无字、打字有去无回）。
                  child: Stack(
                    fit: StackFit.expand,
                    clipBehavior: Clip.none,
                    children: <Widget>[
                      // T22：终端从胶囊下方起排。行不能铺到胶囊底下——空屏时 prompt
                      // 就在第一行，压在胶囊下面等于看不见（#51/#52 的"全黑"就是这个）。
                      Padding(
                        // 终端仍然左右全屏：文字行的留白由原生侧做（setSideInset），
                        // 视图本身不缩窄。
                        padding: const EdgeInsets.only(top: TerminalPage.barHeight),
                        child: shownBody,
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        child: shownBar,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    _treeKey = treeKey;
    return _tree = tree;
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
  const _TopBar({required this.title, required this.subtitle, required this.onMenu, required this.onActions});

  final String title;
  final String subtitle;
  final VoidCallback onMenu;
  final VoidCallback? onActions;

  @override
  Widget build(BuildContext context) {
    ScreenProbe.hit('topbar');
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
              // 原来是返回键。T22 撤掉 tab 行之后，终端页再没有任何切换会话的入口，
              // 所以这颗改成菜单键，把切换 / 新建 / 退出收进侧栏；返回也一并进去。
              GlassIconButton(
                key: const ValueKey('terminal-menu'),
                icon: AppIcons.menu,
                tooltip: l10n.botsTerminalSessions,
                onPressed: onMenu,
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
              // 右侧不再放按钮：它和中间那颗胶囊点开的是同一个面板，留着只是重复。
              // 留同样宽的空白，胶囊才还在正中。
              const SizedBox(width: 44),
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


/// 安全区的叶子。
///
/// 为什么单独一个 widget：**订阅 MediaQuery 的代价不在"算一次"，而在"谁被重建"**。
/// 键盘抖一下、系统栏翻一下，MediaQuery 一变，所有订阅者一起重建——页面带着整棵
/// 子树往下重建，一路排到平台视图那层，`build_avg` 就是这么涨上去的。
///
/// 把它挪到叶子之后：页面 build 里一个 MediaQuery 都不碰，只有这一层跟着变；
/// 它的 child 是缓存好的同一个 Widget 实例，`updateChild` 认出 identical 直接跳过。
///
/// 底部内缩在输入法弹起时按 0 算：那条本来就被键盘盖住，但它的值会在系统栏显隐
/// 之间反复翻，翻了就重排。夹成 0 之后，拖动光标期间这里完全静止。
class _Insets extends StatelessWidget {
  const _Insets({required this.top, required this.bottom, required this.child});

  final bool top;
  final bool bottom;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.maybeOf(context);
    if (mq == null) return child;
    final imeUp = mq.viewInsets.bottom > 0;
    return Padding(
      padding: EdgeInsets.only(
        top: top ? mq.padding.top : 0,
        bottom: bottom ? (imeUp ? 0 : mq.padding.bottom) : 0,
      ),
      child: child,
    );
  }
}

/// 终端侧栏：会话切换 · 新建 · 退出。
///
/// 为什么要有它：T22 把 tab 行整个撤掉了，终端页从此没有任何切换会话的入口。
/// 顶栏左侧那颗原来是返回键，现在改成菜单键，返回（退出）也一并收进来。
/// 形状照 `ui/shell/sessions_drawer.dart` 的会话列表：标题 + 目录，选中那条染色,
/// 行尾两颗小图标（重命名 / 关闭）。
class _TerminalDrawer extends StatelessWidget {
  const _TerminalDrawer({
    required this.tabs,
    required this.selectedId,
    required this.onSelect,
    required this.onNew,
    required this.onRename,
    required this.onClose,
    required this.onExit,
  });

  final List<TerminalTab> tabs;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final VoidCallback onNew;
  final ValueChanged<TerminalTab> onRename;
  final ValueChanged<TerminalTab> onClose;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 和 sessionSelectionColor() 同一条算式（那边在 shell 里，为这一处把整个
    // sessions_drawer 的依赖拖进来不值当）。
    final selectedFill = scheme.primary.withValues(alpha: scheme.brightness == Brightness.dark ? 0.18 : 0.09);
    final tertiary = DshColors.of(context).textTertiary;
    return Drawer(
      width: 320,
      backgroundColor: scheme.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 10, 6),
              child: Row(
                children: [
                  Expanded(child: Text(l10n.botsTerminalSessions, style: theme.textTheme.titleLarge)),
                  GlassIconButton(
                    key: const ValueKey('terminal-drawer-new'),
                    icon: AppIcons.add,
                    tooltip: l10n.botsTerminalNew,
                    onPressed: onNew,
                  ),
                ],
              ),
            ),
            if (tabs.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: Text(l10n.botsTerminalNone, style: theme.textTheme.bodyMedium?.copyWith(color: tertiary)),
              )
            else
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: tabs.length,
                  itemBuilder: (context, i) {
                    final tab = tabs[i];
                    final selected = tab.id == selectedId;
                    final name = tab.title.isEmpty ? l10n.botsTerminal : tab.title;
                    final cwd = tab.info?.cwd ?? '';
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(10, 2, 10, 2),
                      child: DecoratedBox(
                        decoration: ShapeDecoration(
                          color: selected ? selectedFill : Colors.transparent,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Pressable(
                                onTap: () => onSelect(tab.id),
                                semanticLabel: name,
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.titleSmall,
                                      ),
                                      if (cwd.isNotEmpty)
                                        Text(
                                          cwd,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: AppType.monoLabel(color: tertiary).copyWith(fontSize: 10.5, height: 1.2),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            IconButton(
                              key: ValueKey('terminal-drawer-rename-${tab.id}'),
                              icon: const Icon(AppIcons.rename, size: 18),
                              tooltip: l10n.commonRename,
                              onPressed: () => onRename(tab),
                            ),
                            IconButton(
                              key: ValueKey('terminal-drawer-close-${tab.id}'),
                              icon: const Icon(AppIcons.delete, size: 18),
                              tooltip: l10n.botsTerminalClose,
                              onPressed: () => onClose(tab),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            const Divider(height: 1),
            Pressable(
              onTap: onExit,
              semanticLabel: l10n.botsTerminalExit,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
                child: Row(
                  children: [
                    Icon(AppIcons.logout, size: 18, color: DshColors.of(context).textTertiary),
                    const SizedBox(width: 12),
                    Text(l10n.botsTerminalExit, style: theme.textTheme.bodyLarge),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
