// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/selection_toolbar_state.dart';
import '../../../state/swipe_guard.dart';
import '../../speech/speech_ui.dart';
import '../../theme/app_icons.dart';
import '../secret_mask.dart';
import 'message_menu.dart';
// 选区登记簿（一次只留一个、点屏幕全清）住在 message_selection_area.dart，
// 那边的 MessageSelectionArea 与这里的 MessageSelection 共用一本账。
import 'message_selection_area.dart' show ownSelection, releaseSelection;

/// A message's text, selectable where it is: a long-press selects the word
/// under the finger, the handles drag the range. The toolbar over the
/// selection: 复制 · 引用 ([onQuote]) · 分享 · 播音 · ⓘ ([onMore], the
/// message's own menu) · 全选, then the system's text actions.
///
/// 照上游同步，只有两处不一样：上游那格写「更多」，我们换成 ⓘ 图标（无文字）；
/// 同一行第四项上游叫「朗读」，我们叫「播音」——系统自带的选字菜单里也有一个
/// 「朗读」，两个同名分不清。容器、溢出折叠、⋮、定位一概不动，全交给框架。
///
/// 摆哪几项、什么顺序由 [selectionToolbarProvider] 决定（设置 → 通用 → 界面 →
/// 选字工具条）。系统自己塞进来的项（查询、翻译之类）永远接在最后。
///
/// It copies and shares what is drawn (a masked credential stays
/// masked; the eye shows it, the menu's 「复制」 takes the original); 播音
/// leaves credentials out ([speakableSelection]).
class MessageSelection extends ConsumerStatefulWidget {
  const MessageSelection({
    super.key,
    required this.text,
    required this.child,
    this.onQuote,
    this.onMore,
    this.live = false,
  });

  /// The whole message: 播音 finds its credentials here, where a selected
  /// piece of one would no longer look like one.
  final String text;

  final Widget child;
  final ValueChanged<String>? onQuote;
  final VoidCallback? onMore;

  /// Still being written. Selecting works as on a finished message, but the
  /// text is handed to the selection only once a finger comes down on it or
  /// the writing stops ([_HeldSelectables]), not with every delta.
  final bool live;

  @override
  ConsumerState<MessageSelection> createState() => _MessageSelectionState();
}

/// 工具条上一格的高度：框架那条工具条是 44。
const double _kToolbarItem = 44;

class _MessageSelectionState extends ConsumerState<MessageSelection> with AutomaticKeepAliveClientMixin {
  /// What is selected right now (plain text).
  String _selected = '';

  final GlobalKey<SelectionAreaState> _areaKey = GlobalKey<SelectionAreaState>();
  late final VoidCallback _clearCallback = _clear;

  /// 选区不需要焦点：框架在区域丢焦点时就地清掉选区
  /// （`SelectableRegion._handleFocusChanged`）。`canRequestFocus: false` 让它
  /// 永远不会"从有到无"，这条路就不成立了（手机端选区不需要焦点）。
  final FocusNode _focus = FocusNode(
    canRequestFocus: false,
    skipTraversal: true,
    debugLabel: 'message-selection',
  );

  SwipeHold? _hold;
  bool _hasSelection = false;

  /// 消息在 `SliverList` 里懒构建，滚出视口会被 dispose；持有选区时就留住它。
  @override
  bool get wantKeepAlive => _hasSelection;

  void _clear() => _areaKey.currentState?.selectableRegion.clearSelection();

  void _onSelectionChanged(SelectedContent? content) {
    final text = content?.plainText ?? '';
    // 工具条要的是"现在是哪一段"：不上 setState，免得每个字都重建一次。
    _selected = text;
    final has = text.trim().isNotEmpty;
    if (has == _hasSelection) return;
    setState(() => _hasSelection = has);
    updateKeepAlive();
    if (has) {
      // 一次只留一个选区（He 2026-11-21 的截图：好几个高亮、点一下只清一个）。
      ownSelection(_clearCallback);
      _hold ??= SwipeHold();
    } else {
      _hold?.release();
      _hold = null;
      releaseSelection(_clearCallback);
    }
  }

  /// 工具条上由我们摆放的一格。ⓘ 是图标，其余是文字，所以只有一个不是
  /// [ContextMenuButtonItem]。
  Widget _menuSlot(BuildContext context, SelectableRegionState region, VoidCallback onMore) => SizedBox.square(
    dimension: _kToolbarItem,
    child: IconButton(
      key: const ValueKey('selection-more'),
      tooltip: context.l10n.chatMessageMenu,
      padding: EdgeInsets.zero,
      iconSize: 22,
      color: Theme.of(context).colorScheme.onSurface,
      onPressed: () {
        region.clearSelection();
        onMore();
      },
      icon: const Icon(AppIcons.info),
    ),
  );

  Widget _toolbar(BuildContext context, SelectableRegionState region) {
    final system = region.contextMenuButtonItems;
    ContextMenuButtonItem? item(ContextMenuButtonType type) => system.where((i) => i.type == type).firstOrNull;
    // 这几种由我们自己摆位置；系统剩下的（查询、翻译之类）接在最后。
    // 分享不在工具条上了：它在 ⓘ 打开的二级菜单里（这条消息自己的菜单）。
    const ours = {ContextMenuButtonType.copy, ContextMenuButtonType.share, ContextMenuButtonType.selectAll};
    final selected = _selected;
    final some = selected.trim().isNotEmpty;
    final onQuote = widget.onQuote;
    final onMore = widget.onMore;

    ContextMenuButtonItem? text(SelectionToolbarItem slot) => switch (slot) {
      SelectionToolbarItem.copy => item(ContextMenuButtonType.copy),
      SelectionToolbarItem.selectAll => item(ContextMenuButtonType.selectAll),
      SelectionToolbarItem.quote => some && onQuote != null
          ? ContextMenuButtonItem(
              label: MessageAction.quote.label,
              onPressed: () {
                region.clearSelection();
                onQuote(selected);
              },
            )
          : null,
      SelectionToolbarItem.announce => some
          ? ContextMenuButtonItem(
              // 系统自带的选字菜单里叫「朗读」；这一格改叫「播音」分开。
              label: context.l10n.chatAnnounce,
              onPressed: () {
                region.hideToolbar();
                // Its own id: another passage starts over, the same one stops.
                readAloudReply(this.context, 'selection:$selected', speakableSelection(selected, widget.text));
              },
            )
          : null,
      SelectionToolbarItem.menu => null,
    };

    // 整批量好间距再插 ⓘ：框架的 padding 是按 (第几个, 共几个) 算的，逐个算会宽出来。
    final items = <ContextMenuButtonItem>[];
    int? menuAt;
    for (final slot in ref.read(selectionToolbarProvider).items) {
      if (slot == SelectionToolbarItem.menu) {
        if (onMore != null) menuAt = items.length;
        continue;
      }
      final one = text(slot);
      if (one != null) items.add(one);
    }
    items.addAll(system.where((i) => !ours.contains(i.type)));

    final children = AdaptiveTextSelectionToolbar.getAdaptiveButtons(context, items).toList();
    if (menuAt != null) children.insert(menuAt, _menuSlot(context, region, onMore!));
    if (children.isEmpty) return const SizedBox.shrink();
    return AdaptiveTextSelectionToolbar(anchors: region.contextMenuAnchors, children: children);
  }

  @override
  void dispose() {
    releaseSelection(_clearCallback);
    _hold?.release();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SelectionArea(
      key: _areaKey,
      focusNode: _focus,
      onSelectionChanged: _onSelectionChanged,
      contextMenuBuilder: _toolbar,
      child: _HeldSelectables(live: widget.live, child: widget.child),
    );
  }
}

/// Holds back the text that registers for selection below it while [live].
///
/// Each delta of a reply being written changes its last paragraph's text, and
/// a paragraph whose text changes registers its pieces again: the region then
/// sorts them in among the whole reply's after the frame, walking each one's
/// transform up to the root. Nobody is selecting most of the time, so that is
/// held back here instead.
///
/// A pointer down on the message, the region taking focus (the keyboard), or
/// the end of [live], hands everything held to the region and lets later
/// registrations straight through. The
/// region takes them in at the end of the next frame, well before a
/// long-press fires or a double tap's second tap comes down, so selecting
/// works as on a finished message.
class _HeldSelectables extends StatefulWidget {
  const _HeldSelectables({required this.live, required this.child});

  final bool live;
  final Widget child;

  @override
  State<_HeldSelectables> createState() => _HeldSelectablesState();
}

class _HeldSelectablesState extends State<_HeldSelectables> {
  /// Open from the start on a finished message.
  late final _gate = _SelectableGate(!widget.live);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _gate.region = SelectionContainer.maybeOf(context);
    // The region's own focus, reached by the keyboard (Tab) with no pointer:
    // its select-all and copy shortcuts work on what it holds.
    if (Focus.maybeOf(context)?.hasFocus ?? false) _gate.open();
  }

  @override
  void didUpdateWidget(_HeldSelectables oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.live) _gate.open();
  }

  @override
  Widget build(BuildContext context) => Listener(
    // The region's own gesture detector is translucent over the same box.
    behavior: HitTestBehavior.translucent,
    onPointerDown: (_) => _gate.open(),
    child: SelectionRegistrarScope(registrar: _gate, child: widget.child),
  );
}

/// What registers below [_HeldSelectables]: kept, and passed on to [region]
/// once open.
class _SelectableGate implements SelectionRegistrar {
  _SelectableGate(this._open);

  final _held = <Selectable>{};
  bool _open;

  SelectionRegistrar? get region => _region;
  SelectionRegistrar? _region;
  set region(SelectionRegistrar? value) {
    if (identical(value, _region)) return;
    if (_open) {
      for (final selectable in _held) {
        _region?.remove(selectable);
        value?.add(selectable);
      }
    }
    _region = value;
  }

  void open() {
    if (_open) return;
    _open = true;
    final region = _region;
    if (region == null || _held.isEmpty) return;
    for (final selectable in _held) {
      region.add(selectable);
    }
    // The region sorts them in after a frame: make sure there is one.
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  @override
  void add(Selectable selectable) {
    _held.add(selectable);
    if (_open) _region?.add(selectable);
  }

  @override
  void remove(Selectable selectable) {
    if (!_held.remove(selectable)) return;
    if (_open) _region?.remove(selectable);
  }
}

/// [selected] without any part of a credential in [message]: a whole one, one
/// cut at either end of the selection, or a selection inside one (nothing is
/// left). Neither a voice service nor the speaker gets it, as with a whole
/// reply. Text only, without positions: a cut counts from [_least] characters,
/// so an ordinary word that merely shares a letter with a key stays.
@visibleForTesting
String speakableSelection(String selected, String message) {
  final cut = List.filled(selected.length, false);
  for (final secret in findSecrets(message)) {
    final value = message.substring(secret.start, secret.end);
    final words = selected.trim();
    if (words.length >= _least && value.contains(words)) return '';
    for (var at = selected.indexOf(value); at >= 0; at = selected.indexOf(value, at + 1)) {
      cut.fillRange(at, at + value.length, true);
    }
    for (var n = math.min(value.length, selected.length); n >= _least; n--) {
      if (selected.startsWith(value.substring(value.length - n))) {
        cut.fillRange(0, n, true);
        break;
      }
    }
    for (var n = math.min(value.length, selected.length); n >= _least; n--) {
      if (selected.endsWith(value.substring(0, n))) {
        cut.fillRange(selected.length - n, selected.length, true);
        break;
      }
    }
  }
  return String.fromCharCodes([
    for (var i = 0; i < selected.length; i++)
      if (!cut[i]) selected.codeUnitAt(i),
  ]);
}

const _least = 4;
