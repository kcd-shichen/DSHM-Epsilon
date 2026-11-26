// Symmetry of the terminal page, measured: the key row is twelve equal cells
// with centred labels and equal side insets (scrolling, never uneven, when
// too narrow); the status row has the same height and
// its button is concentric with the card corner; the top bar's round keys
// mirror each other around a centred title; the tab capsules and 「+」 share
// one height and one centre line, flush with the card's edge.

import 'package:dsh_app/ui/terminal/terminal_keys.dart';
import 'package:dsh_app/ui/terminal/terminal_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

/// 状态槽的两个尺寸：按钮 36，槽 52（terminal_keys.dart 里同一组数，那边是私有的）。
const double _barHeight = 52.0;
const double _keyHeight = 36.0;

Rect _rect(WidgetTester tester, Finder finder) => tester.getRect(finder);

Rect _card(WidgetTester tester) => _rect(tester, find.byType(TerminalCardFrame));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('status row: same height as the key row; the button 8 from the corner', (tester) async {
    final backend = FakeTerminalBackend(terminals: [infoJson('a')]);
    await pumpTerminalPage(tester, backend);
    backend.attachOf('a').lose();
    await settleTerminal(tester);
    final card = _card(tester);
    final bar = _rect(tester, find.byType(TerminalStatusBar));
    expect(bar.height, _barHeight);
    expect(bar.bottom, moreOrLessEquals(card.bottom));
    final button = _rect(tester, find.byKey(const ValueKey('terminal-status-action')));
    expect(button.height, _keyHeight);
    expect(card.right - button.right, moreOrLessEquals(8));
    expect(button.top - bar.top, moreOrLessEquals(8));
    expect(bar.bottom - button.bottom, moreOrLessEquals(8));
  });

  testWidgets('top bar: mirrored round keys, centred title', (tester) async {
    await pumpTerminalPage(tester, FakeTerminalBackend(terminals: [infoJson('a')]));
    final screen = tester.getSize(find.byType(Scaffold));
    final back = _rect(tester, find.byKey(const ValueKey('terminal-back')));
    final more = _rect(tester, find.byKey(const ValueKey('terminal-more')));
    expect(back.size, more.size);
    expect(back.width, 44);
    expect(back.left, moreOrLessEquals(screen.width - more.right));
    expect(back.center.dy, moreOrLessEquals(more.center.dy));
    final title = _rect(tester, find.text('终端'));
    expect(title.center.dx, moreOrLessEquals(screen.width / 2, epsilon: 0.5));
    // The card lines up with the round keys.
    final card = _card(tester);
    expect(card.left, moreOrLessEquals(back.left));
    expect(screen.width - card.right, moreOrLessEquals(screen.width - more.right));
  });

  testWidgets('tabs: capsules and 「+」 share a height and a centre line, flush with the card', (tester) async {
    await pumpTerminalPage(
      tester,
      FakeTerminalBackend(
        terminals: [
          infoJson('a', title: 'server'),
          infoJson('b', title: 'build'),
        ],
      ),
    );
    final a = _rect(tester, find.byKey(const ValueKey('terminal-tab-a')));
    final b = _rect(tester, find.byKey(const ValueKey('terminal-tab-b')));
    final plus = _rect(tester, find.byKey(const ValueKey('terminal-new')));
    expect(a.height, 32);
    expect(b.height, a.height);
    expect(plus.height, a.height);
    expect(plus.width, plus.height);
    expect(b.center.dy, moreOrLessEquals(a.center.dy));
    expect(plus.center.dy, moreOrLessEquals(a.center.dy));
    expect(b.left - a.right, moreOrLessEquals(plus.left - b.right));
    expect(a.left, moreOrLessEquals(_card(tester).left));
  });
}
