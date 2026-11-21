// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

// 消息的可选文本层：长按就地选字，选中的字上浮一条工具条。
//
// 工具条内容照上游：复制 · 引用 · 分享 · 播音 · 全选 · 系统那几项文字操作，
// 右端多两颗图标——ⓘ（这条消息的菜单）和 ⋮（折起来的那些项）。
//
// 和上游写法不一样的三处，逐条记在这里：
//
// 一、工具条是自己排的一行，不走 `AdaptiveTextSelectionToolbar.buttonItems`。
//    `buttonItems` 的 `label` 只能是字符串，做不出只有图标的「更多」。走 `children:`
//    能塞 IconButton，但框架的溢出是**从尾巴往前折**的，而 ⋮ 本身又排在最后一个：
//    紧挨着 ⋮ 的那一项必然是最先被折进菜单的那一项。想让 ⓘ 永远贴在 ⋮ 左边，
//    只能自己排：文字项按宽度能放几项放几项，剩下的折进 ⋮，ⓘ 与 ⋮ 钉在右端。
//    宽度用 TextPainter 量，一律按最宽那档内边距算——只会早折，不会溢出。
//
// 二、「朗读」这一项在这条工具条里叫「播音」（`chatAnnounce`）。工具条上还有系统那套
//    文字操作带来的「朗读」，两个同名，点的时候分不清。系统那项照旧，我们自己这项改名。
//
// 三、选区三条修复必须留着，上游没有这三条，直抄会把它们退回去：
//    · 不可聚焦的 FocusNode——框架在选区丢焦点时 clearSelection（探针实测，§53）；
//    · AutomaticKeepAliveClientMixin——消息在 SliverList 里懒构建，滚出视口就被 dispose；
//    · [_activeClears] 集合——一次只留一个选区，新选区起来先把别处的收掉。

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;

import '../../../l10n/l10n.dart';
import '../../../state/swipe_guard.dart';
import '../../speech/speech_ui.dart';
import '../../theme/app_icons.dart';
import '../secret_mask.dart';
import 'message_actions.dart';

/// A message's text, selectable where it is: a long-press selects the word
/// under the finger, the handles drag the range. The toolbar over the
/// selection: 复制 · 引用 ([onQuote]) · 分享 · 播音 · 全选 · 系统项, then ⓘ
/// ([onMore], this message's own menu) and ⋮ (whatever did not fit).
///
/// It copies and shares what is drawn (a masked credential stays
/// masked; the eye shows it, the menu's 「复制」 takes the original); 播音
/// leaves credentials out ([speakableSelection]).
class MessageSelection extends StatefulWidget {
  const MessageSelection({super.key, required this.text, required this.child, this.onQuote, this.onMore});

  /// The whole message: 播音 finds its credentials here, where a selected
  /// piece of one would no longer look like one.
  final String text;

  final Widget child;
  final ValueChanged<String>? onQuote;
  final VoidCallback? onMore;

  @override
  State<MessageSelection> createState() => _MessageSelectionState();
}

/// 当前有选区的那些消息层。可能不止一个，所以按集合收。
final Set<VoidCallback> _activeClears = <VoidCallback>{};

/// 点屏幕时把所有选区都清掉。壳层（`HomeShell`）在"短按且没移动"时调用。
void clearMessageSelection() {
  if (_activeClears.isEmpty) return;
  final clears = List<VoidCallback>.of(_activeClears);
  _activeClears.clear();
  for (final clear in clears) {
    clear();
  }
}

class _MessageSelectionState extends State<MessageSelection> with AutomaticKeepAliveClientMixin {
  final GlobalKey<SelectionAreaState> _areaKey = GlobalKey<SelectionAreaState>();
  late final VoidCallback _clearCallback = _clear;

  /// 选区不需要焦点：框架在区域丢焦点时就清选区（见文件头）。
  final FocusNode _focus = FocusNode(canRequestFocus: false, skipTraversal: true, debugLabel: 'message-selection');

  SwipeHold? _hold;
  bool _hasSelection = false;

  /// 工具条要的文字，随选区边走边更；不为它 setState——工具条由框架自己重建。
  String _selected = '';

  @override
  bool get wantKeepAlive => _hasSelection;

  void _onSelectionChanged(SelectedContent? content) {
    final text = content?.plainText ?? '';
    _selected = text;
    final has = text.trim().isNotEmpty;
    if (has == _hasSelection) return;
    setState(() => _hasSelection = has);
    updateKeepAlive();
    if (has) {
      // 一次只留一个选区：新选区起来时把别处的收掉，否则会出现"好几个高亮、
      // 点一下只清掉一个"的局面。
      for (final other in List<VoidCallback>.of(_activeClears)) {
        if (other != _clearCallback) other();
      }
      _activeClears.add(_clearCallback);
      _hold ??= SwipeHold();
    } else {
      _hold?.release();
      _hold = null;
      _activeClears.remove(_clearCallback);
    }
  }

  void _clear() => _areaKey.currentState?.selectableRegion.clearSelection();

  @override
  void dispose() {
    _activeClears.remove(_clearCallback);
    _hold?.release();
    _focus.dispose();
    super.dispose();
  }

  Widget _toolbar(BuildContext context, SelectableRegionState region) {
    final l10n = context.l10n;
    final system = region.contextMenuButtonItems;
    ContextMenuButtonItem? systemItem(ContextMenuButtonType type) {
      for (final item in system) {
        if (item.type == type) return item;
      }
      return null;
    }

    // 这几类我们自己排，系统那份不再重复端上来。
    const ours = {ContextMenuButtonType.copy, ContextMenuButtonType.share, ContextMenuButtonType.selectAll};
    final selected = _selected;
    final some = selected.trim().isNotEmpty;
    final onQuote = widget.onQuote;

    final items = <_BarItem>[
      if (systemItem(ContextMenuButtonType.copy) case final copy?) _BarItem.of(context, copy),
      if (some && onQuote != null)
        _BarItem(
          MessageAction.quote.label,
          () {
            region.clearSelection();
            onQuote(selected);
          },
        ),
      if (systemItem(ContextMenuButtonType.share) case final share?) _BarItem.of(context, share),
      if (some)
        _BarItem(
          l10n.chatAnnounce,
          () {
            region.hideToolbar();
            // 自己的 id：换一段重头念，同一段再点一下停。
            readAloudReply(this.context, 'selection:$selected', speakableSelection(selected, widget.text));
          },
        ),
      if (systemItem(ContextMenuButtonType.selectAll) case final all?) _BarItem.of(context, all),
      for (final item in system)
        if (!ours.contains(item.type)) _BarItem.of(context, item),
    ];

    return AdaptiveTextSelectionToolbar(
      anchors: region.contextMenuAnchors,
      children: [
        // 一个孩子：宽度算得准，框架那层溢出就不会接管（它一接管就要么把整行折进去、
        // 要么把 ⋮ 换成它自己的那颗）。
        LayoutBuilder(
          builder: (context, constraints) => _bar(context, items, region, constraints.maxWidth),
        ),
      ],
    );
  }

  Widget _bar(BuildContext context, List<_BarItem> items, SelectableRegionState region, double maxWidth) {
    final onMore = widget.onMore;
    final widths = [for (final item in items) _buttonWidth(context, item.label)];
    double sum(Iterable<double> w) => w.fold(0.0, (a, b) => a + b);

    // 先看"只留 ⓘ"放不放得下：放得下就没有折叠，也就没有 ⋮。
    final infoOnly = maxWidth - (onMore == null ? 0 : _iconSide) - _slack;
    var visible = items.length;
    if (sum(widths) > infoOnly) {
      final budget = infoOnly - _iconSide;
      var used = 0.0;
      visible = 0;
      while (visible < items.length && used + widths[visible] <= budget) {
        used += widths[visible];
        visible++;
      }
      if (visible == 0 && items.isNotEmpty) visible = 1; // 再窄也留一项，不摆一颗光杆 ⋮
    }
    final folded = items.sublist(visible);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < visible; i++)
          TextSelectionToolbarTextButton(
            padding: TextSelectionToolbarTextButton.getPadding(i, visible),
            onPressed: items[i].onPressed,
            child: Text(items[i].label),
          ),
        if (onMore != null)
          IconButton(
            key: const ValueKey('selection-menu'),
            tooltip: context.l10n.commonMore,
            onPressed: () {
              region.clearSelection();
              onMore();
            },
            icon: const Icon(AppIcons.info, size: 22),
          ),
        if (folded.isNotEmpty)
          PopupMenuButton<_BarItem>(
            key: const ValueKey('selection-overflow'),
            tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
            icon: const Icon(Icons.more_vert),
            onSelected: (item) {
              region.hideToolbar();
              item.onPressed?.call();
            },
            itemBuilder: (context) => [for (final item in folded) PopupMenuItem(value: item, child: Text(item.label))],
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SelectionArea(
      key: _areaKey,
      focusNode: _focus,
      onSelectionChanged: _onSelectionChanged,
      contextMenuBuilder: _toolbar,
      child: widget.child,
    );
  }
}

/// 一颗图标按钮的固定宽度，和框架那颗 ⋮ 一样大。
const double _iconSide = 48;

/// 余量：量出来的宽比实际用的宽会差一点点，宁可早折一项。
const double _slack = 6;

/// 文字按钮的真实宽度：`TextSelectionToolbarTextButton` 最小 48，内边距最宽那档
/// 两头各 14.5。按最宽算，实际只会更窄。
double _buttonWidth(BuildContext context, String label) {
  final style = Theme.of(context).textTheme.labelLarge ?? const TextStyle(fontSize: 14);
  final painter = TextPainter(
    text: TextSpan(text: label, style: style),
    textDirection: Directionality.of(context),
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return math.max(kMinInteractiveDimension, width + 29 + 2);
}

/// 工具条上的一项：文字由谁给、点了做什么。
class _BarItem {
  const _BarItem(this.label, this.onPressed);

  /// 系统给的项（复制 / 分享 / 全选 / 别的应用加进来的那些）：文字和动作都照用，
  /// 文案由框架本地化，不自己编。
  factory _BarItem.of(BuildContext context, ContextMenuButtonItem item) =>
      _BarItem(AdaptiveTextSelectionToolbar.getButtonLabel(context, item), item.onPressed);

  final String label;
  final VoidCallback? onPressed;
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

/// 一次按下到抬起是不是"点了一下"：[slop] 内没移动、也没超过 [maxMs]。
bool isTapGesture(Offset from, Offset to, Duration elapsed, {double slop = kTouchSlop, int maxMs = 300}) =>
    (to - from).distance <= slop && elapsed.inMilliseconds <= maxMs;
