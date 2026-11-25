// The capsule row above the composer — ui.json's `composer.quickActions`
// (docs/design/plugin-seams.md §10.2) and the plugins' `composer.actions`
// (docs/design/native-plugins.md §3.3) in one row. ui.json's come first and in
// its order; plugins add up to two each, up to eight in all. A tap puts text in
// the composer or does what the capsule says; nothing is ever sent by it. The
// row steps aside while a reply is generating (the activity strip takes the
// place). Last, outside the eight, 「插件」 opens the conversation's plugin
// sheet (chat_plugins_sheet.dart) while it has something. The chat's own
// pills (「自动允许中」, 「完全权限」, the generation mode) lead the row, pinned
// while the capsules scroll: one row above the composer, not two.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart' show DshGoScope;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../plugins/native/native_model.dart';
import '../../../plugins/native/native_state.dart';
import '../../../ui_config/ui_config_model.dart';
import '../../../ui_config/ui_config_state.dart';
import '../../common/edge_fade.dart';
import '../../pets/pet_perch.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import 'chat_plugins_sheet.dart';
import 'native_taps.dart';
import 'rise_reveal.dart';

/// One capsule.
@immutable
class CapsuleItem {
  const CapsuleItem({required this.id, required this.label, this.icon, this.source, this.busyKey, required this.onTap});

  /// Stable across rebuilds (`ui:2`, `<package>#<id>`).
  final String id;
  final String label;
  final IconData? icon;

  /// The plugin it comes from (read out with the label).
  final String? source;

  /// The control whose work it shows ([nativeControlKey]); null for one
  /// that never waits.
  final String? busyKey;
  final VoidCallback onTap;
}

/// Capsule geometry, shared with the geometry tests.
abstract final class CapsuleMetrics {
  static const height = 34.0;

  /// Left and right of the content, equal on both sides.
  static const inset = 14.0;
  static const icon = 16.0;
  static const iconGap = 6.0;

  /// Between capsules.
  static const gap = 8.0;

  /// Between the row and the composer (the banners' rhythm).
  static const below = 8.0;

  /// 环那颗收起来时往下沉多少：**不动宽度、不裁边**（裁会把玻璃投影切在四角，
  /// 正是 He 指出的那道黑影），沉到输入框玻璃底下由它盖住（He 2026-11-26）。
  /// 这个数不能大过 [ComposerCapsuleRow.shadowRoom]，否则会被行的可视区切掉。
  static const sink = 30.0;
}

/// A glass capsule: an optional icon and a label, the same air left and
/// right, the height of the row. At work, its content gives way to a small
/// ring in the middle: the capsule keeps its size, nothing moves.
///
/// 一颗胶囊的六件事全在这里，别处不再各写一套（He 2026-11-26「重做胶囊」）：
///
/// - 版式：[CapsuleMetrics] 那批数，玻璃 `chrome` + `stadium` + `grouped`；
/// - 位置/规格：由 [ComposerCapsuleRow] 排，同一道 [CapsuleMetrics.gap]；
/// - 衔接：进出场由行的 `_CapsuleSlot` 管，这颗自己不管；
/// - 按压：本体伸到 [AppMotion.pressLift]，和发送键、⛶、侧栏「新对话」同一套；
/// - 震动：点一下 `selectionClick`（InkWell 那下关掉，免得两响），长按走
///   Tooltip 自带的那下；
/// - 长按：把话说全——这颗叫什么、从哪来（插件名 / ui.json），不改状态。
/// 这一行每一颗按钮的共同外壳：玻璃 + 水波 + 按压 + 震动 + 长按提示。
///
/// 文字胶囊和上下文环那颗**只在这里分叉**——里面放什么由调用方给，外壳一套。
class CapsuleChrome extends StatelessWidget {
  const CapsuleChrome({super.key, required this.child, this.onTap, this.hint});

  final Widget child;
  final VoidCallback? onTap;

  /// 长按给的那一句（Tooltip）。null 就不挂。
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final glass = GlassSurface(
      tier: GlassTier.chrome,
      stadium: true,
      grouped: true,
      // 按压：和发送键、⛶、侧栏「新对话」同一套——本体伸（He 2026-11-24 定的标准）。
      pressScale: AppMotion.pressLift,
      // 反馈自己发（一次 selectionClick），免得 InkWell 再响一次。
      tapFeedback: false,
      onTap: onTap == null
          ? null
          : () {
              HapticFeedback.selectionClick();
              onTap!();
            },
      child: child,
    );
    final hint = this.hint;
    if (hint == null) return glass;
    return Tooltip(
      // 长按不改状态，只把话说全。和 ⛶ 的长按提示同一路（§82.2）。
      message: hint,
      triggerMode: TooltipTriggerMode.longPress,
      excludeFromSemantics: true,
      // 这一行长在输入条上面，提示往下会被键盘吃掉。
      preferBelow: false,
      child: glass,
    );
  }
}

class ComposerCapsule extends ConsumerWidget {
  const ComposerCapsule({super.key, required this.item});

  final CapsuleItem item;

  /// The working ring.
  static const ring = 14.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final style = theme.textTheme.labelMedium?.copyWith(color: colors.onSurface, fontWeight: FontWeight.w500);
    final source = item.source;
    final key = item.busyKey;
    final work = key == null ? null : ref.watch(nativeWorkOfProvider(key));
    final busy = work != null;
    // At work on a deferred result: a tap drops it.
    final cancel = work?.cancel;
    final duration = AppMotion.of(context, AppMotion.quick);
    final l10n = context.l10n;
    final tap = busy ? cancel : item.onTap;
    return Semantics(
      button: true,
      label: busy ? '${item.label} ${work.label ?? l10n.plugslotsWorking}' : item.label,
      hint: cancel != null
          ? l10n.plugslotsTapToCancel
          : source == null
          ? null
          : l10n.plugslotsFromPlugin(source),
      excludeSemantics: true,
      child: CapsuleChrome(
        hint: _capsuleHint(item),
        onTap: tap,
        child: SizedBox(
            height: CapsuleMetrics.height,
            child: Stack(
              alignment: Alignment.center,
              children: [
                AnimatedOpacity(
                  opacity: busy ? 0 : 1,
                  duration: duration,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: CapsuleMetrics.inset),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (item.icon case final icon?) ...[
                          Icon(icon, size: CapsuleMetrics.icon, color: colors.onSurfaceVariant),
                          const SizedBox(width: CapsuleMetrics.iconGap),
                        ],
                        Text(item.label, maxLines: 1, softWrap: false, style: style),
                      ],
                    ),
                  ),
                ),
                AnimatedOpacity(
                  opacity: busy ? 1 : 0,
                  duration: duration,
                  child: SizedBox.square(
                    key: busy ? const ValueKey('capsule-ring') : null,
                    dimension: ring,
                    child: busy
                        ? CircularProgressIndicator(strokeWidth: 1.6, color: colors.onSurfaceVariant)
                        : const SizedBox.shrink(),
                  ),
                ),
              ],
            ),
          ),
        ),
    );
  }
}

/// 长按那一句：它叫什么、从哪来。插件给的带插件名，ui.json 给的带 ui.json。
String _capsuleHint(CapsuleItem item) {
  final from = item.source ?? (item.id.startsWith('ui:') ? 'ui.json' : null);
  return from == null ? item.label : '${item.label} · $from';
}

/// 上下文环那颗：和文字胶囊**同一副外壳**（[CapsuleChrome]），里面放那颗环。
///
/// 键盘一开，它按 `open` 从右往左收到 0（He 2026-11-25 定的衔接：收它自己的宽度，
/// 前面那些胶囊一颗都不挪——「如果之后有三个四个以上的同一行的胶囊，每次打开都会
/// 经历一次胶囊的位置变换」）。收的同时淡出，免得那道竖切边看得见。
class CapsuleRing extends StatelessWidget {
  const CapsuleRing({super.key, required this.ring, required this.open, required this.onTap});

  final Widget ring;

  /// 0 = 收起（它在），1 = 键盘全开（它已经缩没了）。
  final ValueListenable<double> open;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: open,
      builder: (context, child) {
        final t = open.value.clamp(0.0, 1.0).toDouble();
        // 前半段只是往下沉，后半段才化掉——宽度一个像素都不动，所以前面的胶囊
        // 不会被推着走，也不需要用 ClipRect 去切它。
        final fade = (1 - (t - 0.35) / 0.65).clamp(0.0, 1.0).toDouble();
        return IgnorePointer(
          ignoring: t > 0.02,
          child: Opacity(
            opacity: fade,
            child: Transform.translate(offset: Offset(0, CapsuleMetrics.sink * t), child: child),
          ),
        );
      },
      child: CapsuleChrome(
        hint: '上下文用量',
        onTap: onTap,
        child: SizedBox(
          height: CapsuleMetrics.height,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: CapsuleMetrics.inset),
            child: Center(child: ring),
          ),
        ),
      ),
    );
  }
}

/// A row of capsules that scrolls sideways when it doesn't fit, fading at
/// the edge that has more.
///
/// The first capsule lines up with the composer's edge, but the scrolling
/// band reaches [bleed] further on each side (the screen's gutter) and
/// [shadowRoom] above and below, so the glass shadows are never cut and
/// capsules slide out under the screen's edge, not the composer's. A
/// [leading] widget stays put at the left; the band starts after it.
///
/// 增减一颗时它在原地升上来 / 沉下去（`_CapsuleSlot`），宽度不插值：插值会让
/// 后面每一颗每一帧重排，He 2026-11-25 提过这一条。
class ComposerCapsuleRow extends StatefulWidget {
  const ComposerCapsuleRow({super.key, required this.items, this.leading, this.ring, this.bleed = 12});

  final List<CapsuleItem> items;

  /// 这一行的最后一颗（上下文环）。节拍由它自己拿着（[CapsuleRing.open]）。
  final Widget? ring;

  /// Pinned before the capsules (the chat's pills), centred on the row.
  final Widget? leading;

  /// How far the band reaches past the row on each side.
  final double bleed;

  /// The chrome glass shadow's reach (blur 24, offset 8).
  static const shadowRoom = 32.0;

  @override
  State<ComposerCapsuleRow> createState() => _ComposerCapsuleRowState();
}

/// 一颗胶囊在行里的位置和出场进度。
class _CapsuleSlot {
  _CapsuleSlot(this.id, this.item, this.rise);

  final String id;
  CapsuleItem item;

  /// 0 = 还藏着（透明、往下 6），1 = 在位。
  final AnimationController rise;

  /// 已经不在这一行里了，正沉下去，沉完摘掉。
  bool leaving = false;
}

class _ComposerCapsuleRowState extends State<ComposerCapsuleRow> with TickerProviderStateMixin {
  /// 按出场顺序。正在下沉的那几颗留在原地，沉完才走。
  final List<_CapsuleSlot> _slots = [];

  @override
  void initState() {
    super.initState();
    // 第一次进来就到位：这一行自己由 RiseReveal 升起来，不再叠一层。
    for (final item in widget.items) {
      _slots.add(_CapsuleSlot(item.id, item, _controller(at: 1)));
    }
  }

  AnimationController _controller({required double at}) =>
      AnimationController(vsync: this, duration: AppMotion.standard, value: at);

  @override
  void didUpdateWidget(ComposerCapsuleRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    _reconcile(widget.items);
  }

  @override
  void dispose() {
    for (final slot in _slots) {
      slot.rise.dispose();
    }
    super.dispose();
  }

  void _reconcile(List<CapsuleItem> items) {
    final duration = AppMotion.of(context, AppMotion.standard);
    final byId = <String, CapsuleItem>{for (final item in items) item.id: item};

    for (final slot in List.of(_slots)) {
      final fresh = byId[slot.id];
      if (fresh == null) {
        if (slot.leaving) continue;
        slot.leaving = true;
        slot.rise.duration = duration;
        slot.rise.reverse().whenComplete(() {
          if (!mounted) return;
          setState(() => _slots.remove(slot));
          slot.rise.dispose();
        });
      } else {
        slot.item = fresh;
        if (slot.leaving) {
          slot.leaving = false;
          slot.rise.forward();
        }
      }
    }

    for (final item in items) {
      if (_slots.any((slot) => slot.id == item.id)) continue;
      final slot = _CapsuleSlot(item.id, item, _controller(at: 0));
      slot.rise.duration = duration;
      _slots.add(slot);
      slot.rise.forward();
    }

    // 顺序照 data 走；正在下沉的那几颗留在原地。
    final ordered = <_CapsuleSlot>[
      for (final item in items) _slots.firstWhere((slot) => slot.id == item.id),
      for (final slot in _slots)
        if (!items.any((item) => item.id == slot.id)) slot,
    ];
    _slots
      ..clear()
      ..addAll(ordered);
  }

  @override
  Widget build(BuildContext context) {
    final leading = widget.leading;
    final hasRow = _slots.isNotEmpty || widget.ring != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: CapsuleMetrics.below),
      child: SizedBox(
        height: CapsuleMetrics.height,
        child: leading == null
            ? _band(left: widget.bleed)
            : Row(
                children: [
                  leading,
                  if (hasRow) ...[
                    const SizedBox(width: CapsuleMetrics.gap),
                    // Under the pinned pills nothing slides: the band starts here.
                    Expanded(child: _band(left: 0)),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _band({required double left}) => LayoutBuilder(
    builder: (context, constraints) => OverflowBox(
      alignment: left == widget.bleed ? Alignment.center : Alignment.centerLeft,
      minWidth: constraints.maxWidth + left + widget.bleed,
      maxWidth: constraints.maxWidth + left + widget.bleed,
      minHeight: CapsuleMetrics.height + 2 * ComposerCapsuleRow.shadowRoom,
      maxHeight: CapsuleMetrics.height + 2 * ComposerCapsuleRow.shadowRoom,
      child: BackdropGroup(
        child: HorizontalEdgeFade(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.fromLTRB(
              left,
              ComposerCapsuleRow.shadowRoom,
              widget.bleed,
              ComposerCapsuleRow.shadowRoom,
            ),
            child: Row(
              children: [
                for (final (i, slot) in _slots.indexed) ...[
                  if (i > 0) const SizedBox(width: CapsuleMetrics.gap),
                  _risen(slot),
                ],
                // 环排在这一行最后：收的时候塌的是它自己，前面的一个都不挪。
                if (widget.ring case final ring?) ...[
                  if (_slots.isNotEmpty) const SizedBox(width: CapsuleMetrics.gap),
                  ring,
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _risen(_CapsuleSlot slot) => AnimatedBuilder(
    animation: slot.rise,
    child: ComposerCapsule(key: ValueKey(slot.id), item: slot.item),
    builder: (context, child) {
      final t = AppMotion.std.transform(slot.rise.value.clamp(0.0, 1.0).toDouble());
      return IgnorePointer(
        ignoring: slot.leaving,
        child: Opacity(
          key: ValueKey('capsule-lift-${slot.id}'),
          opacity: t,
          child: Transform.translate(offset: Offset(0, (1 - t) * 6), child: child),
        ),
      );
    },
  );
}

/// The capsules of the composer on screen, in order: ui.json's (commands
/// only with a conversation open), then each plugin's switched-on ones, at
/// most [NativeLimits.capsulesTotal].
List<CapsuleItem> composerCapsules(
  BuildContext context,
  WidgetRef ref, {
  required String? sessionId,
  required List<UiQuickAction> quick,
  required List<NativeAction> plugins,
}) {
  final items = <CapsuleItem>[];
  for (final (i, q) in quick.indexed) {
    if (q.action is UiCommandAction && sessionId == null) continue;
    items.add(CapsuleItem(id: 'ui:$i', label: q.label, onTap: () => unawaited(runUiAction(context, ref, q.action))));
  }
  for (final a in plugins) {
    if (items.length >= NativeLimits.capsulesTotal) break;
    items.add(
      CapsuleItem(
        id: '${a.package}#${a.id}',
        label: a.label,
        icon: a.icon,
        source: ref.read(nativePluginTitleProvider(a.package)),
        busyKey: a.effects.isEmpty ? nativeControlKey(a.package, a.surface, a.id) : null,
        onTap: () => unawaited(runNativeAction(context, ref, a, scope: DshGoScope(sessionId: sessionId))),
      ),
    );
  }
  return items.length > NativeLimits.capsulesTotal ? items.sublist(0, NativeLimits.capsulesTotal) : items;
}

/// The row on the chat screen. [visible] false (a reply generating, read
/// only) folds it away; with no capsules and no [leading] it takes no room.
class ComposerCapsuleBar extends ConsumerStatefulWidget {
  const ComposerCapsuleBar({
    super.key,
    required this.sessionId,
    required this.visible,
    this.leading,
    this.ring,
  });

  final String? sessionId;
  final bool visible;

  /// 这一行最后一颗（上下文环）。
  final Widget? ring;

  /// See [ComposerCapsuleRow.leading].
  final Widget? leading;

  @override
  ConsumerState<ComposerCapsuleBar> createState() => _ComposerCapsuleBarState();
}

class _ComposerCapsuleBarState extends ConsumerState<ComposerCapsuleBar> {
  /// The last capsules and pills shown: they stay while the row folds away.
  List<CapsuleItem> _last = const [];
  Widget? _lastLeading;

  @override
  Widget build(BuildContext context) {
    final quick = ref.watch(uiOverridesProvider.select((o) => o.config.quickActions)) ?? const <UiQuickAction>[];
    final plugins = ref.watch(nativeComposerActionsProvider);
    final hidePluginCapsule = ref.watch(uiHiddenProvider(UiHideItem.pluginCapsule));
    final session = widget.sessionId;
    final items = [
      ...composerCapsules(context, ref, sessionId: session, quick: quick, plugins: plugins),
      if (!hidePluginCapsule && session != null && ref.watch(chatPluginsHaveContentProvider(session)))
        CapsuleItem(
          id: chatPluginsCapsuleId,
          label: context.l10n.plugslotsChatEntry,
          icon: AppIcons.plugin,
          onTap: () => unawaited(showChatPluginsSheet(context, sessionId: session)),
        ),
    ];
    final leading = widget.leading;
    final open = widget.visible && (items.isNotEmpty || leading != null || widget.ring != null);
    if (open) {
      _last = items;
      _lastLeading = leading;
    }
    return RiseReveal(
      open: open,
      child: _last.isEmpty && _lastLeading == null && widget.ring == null
          ? const SizedBox(width: double.infinity)
          // The chat page's pet stands on the row's top edge, above the
          // capsules (never on them); not while the row sinks.
          : PetPerch(
              kind: PerchKind.plugin,
              active: open,
              child: ComposerCapsuleRow(
                items: _last,
                leading: _lastLeading,
                ring: widget.ring,
              ),
            ),
    );
  }
}
