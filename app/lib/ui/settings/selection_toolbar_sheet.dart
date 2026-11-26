// 选字工具条上有哪几项、按什么顺序：每一项都列出来，打了勾的才上条，右侧把手拖动排序。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/selection_toolbar_state.dart';
import '../common/app_sheet.dart';
import '../common/list_page_row.dart';
import '../common/sheet_title_bar.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// 每一项在设置里叫什么。
extension SelectionToolbarItemLabel on SelectionToolbarItem {
  String label(L10n l10n) => switch (this) {
    SelectionToolbarItem.copy => l10n.commonCopy,
    SelectionToolbarItem.quote => l10n.chatQuote,
    SelectionToolbarItem.selectAll => l10n.commonSelectAll,
    SelectionToolbarItem.announce => l10n.chatAnnounce,
    SelectionToolbarItem.menu => l10n.chatMessageMenu,
    SelectionToolbarItem.share => l10n.commonShare,
  };
}

Future<void> showSelectionToolbarItems(BuildContext context) =>
    showAppSheet<void>(context, isScrollControlled: true, builder: (_) => const SelectionToolbarItemsSheet());

class SelectionToolbarItemsSheet extends ConsumerStatefulWidget {
  const SelectionToolbarItemsSheet({super.key});

  @override
  ConsumerState<SelectionToolbarItemsSheet> createState() => _SelectionToolbarItemsSheetState();
}

class _SelectionToolbarItemsSheetState extends ConsumerState<SelectionToolbarItemsSheet> {
  /// 每一行按现在的样子排：存着的在前（照它的顺序），其余接在后面。
  /// 只有打了勾的那些，顺序才会被存下来。
  late final List<SelectionToolbarItem> _rows = [
    ...ref.read(selectionToolbarProvider).items,
    for (final i in SelectionToolbarItem.values)
      if (!ref.read(selectionToolbarProvider).items.contains(i)) i,
  ];
  late final Set<SelectionToolbarItem> _ticked = {...ref.read(selectionToolbarProvider).items};

  void _save() => unawaited(ref.read(selectionToolbarProvider.notifier).setItems(_rows.where(_ticked.contains).toList()));

  void _toggle(SelectionToolbarItem item) {
    setState(() => _ticked.contains(item) ? _ticked.remove(item) : _ticked.add(item));
    _save();
  }

  void _move(int from, int to) {
    setState(() {
      final moved = _rows.removeAt(from);
      _rows.insert(to.clamp(0, _rows.length), moved);
    });
    _save();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final colors = DshColors.of(context);
    Widget row(SelectionToolbarItem item, int index) {
      final ticked = _ticked.contains(item);
      return Semantics(
        key: ValueKey(item.name),
        checked: ticked,
        child: ListPageRow(
          leading: Icon(
            ticked ? AppIcons.checkboxOn : AppIcons.checkboxOff,
            size: 22,
            color: ticked ? scheme.primary : colors.textTertiary,
          ),
          title: item.label(l10n),
          trailing: ReorderableDragStartListener(
            index: index,
            child: Semantics(
              label: l10n.shellDragToReorder,
              child: SizedBox.square(
                dimension: 32,
                child: Icon(AppIcons.dragHandle, size: 20, color: colors.textTertiary),
              ),
            ),
          ),
          onTap: () => _toggle(item),
        ),
      );
    }

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(l10n.hubSelectionToolbarItems),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(kSheetGutter, 6, kSheetGutter, 6),
                child: GlassSurface(
                  tier: GlassTier.card,
                  borderRadius: AppShape.radiusLg,
                  child: Material(
                    type: MaterialType.transparency,
                    clipBehavior: Clip.antiAlias,
                    shape: const RoundedSuperellipseBorder(borderRadius: AppShape.radiusLg),
                    child: ReorderableListView.builder(
                      shrinkWrap: true,
                      buildDefaultDragHandles: false,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: _rows.length,
                      // 提起来的那一行保持玻璃质感，稍微浮一点。
                      proxyDecorator: (child, _, animation) => AnimatedBuilder(
                        animation: animation,
                        builder: (context, child) => Material(
                          color: scheme.surface.withValues(alpha: 0.92),
                          elevation: 6 * animation.value,
                          shadowColor: Colors.black26,
                          shape: Squircle.border(AppShape.md),
                          clipBehavior: Clip.antiAlias,
                          child: child,
                        ),
                        child: child,
                      ),
                      onReorderItem: _move,
                      itemBuilder: (context, i) => row(_rows[i], i),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}
