// 键盘抬起那一段，整屏消息必须**匀速**上移。
//
// 2026-11-27：从 1.4 同步之后，在消息底部推键盘会觉得"顿"，但 HUD 显示一帧都没掉
// （drop 0/60f）。逐帧量出来是这个形状：
//   键盘 inset 每帧均匀 +16.67，输入条却按 easeInOut 自己加速减速，
//   两段叠加，消息每帧位移在 8.6 → 15.1 → 8.6 px 之间摆。
// 所以这不是性能问题，是**两段动画的节奏不一致**。把 `_open` 改成线性之后，
// 18 帧全部 −10.85 px，这条测试就是守住这个。

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_list.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/empty_state.dart' show chatClock;
import 'package:dsh_app/ui/chat/widgets/whale_tail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/sample_chat.dart';

void main() {
  setUpAll(() async {
    await loadTestFonts();
    await WhaleSprites.load();
    chatClock = () => DateTime(2026, 10, 23, 15, 20);
  });

  testWidgets('点输入框推起键盘：消息每帧的位移要一样大', (tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    final harness = ChatHarness(
      session: 's1',
      states: {
        's1': ChatState(
          title: '测试',
          loading: false,
          items: [
            for (var i = 0; i < 30; i++) assistant(i + 1, '第 $i 段回答，稍微长一点点让它有高度。'),
          ],
        ),
      },
    );
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester, 10);

    final scrollable = find.descendant(of: find.byType(ChatList), matching: find.byType(Scrollable)).first;
    final pos = tester.state<ScrollableState>(scrollable).position;
    pos.jumpTo(pos.maxScrollExtent);
    await pumpFrames(tester, 6);

    // 点输入框：键盘抬起和输入条展开同时开始（真机就是这样）。
    await tester.tap(find.byType(TextField));

    final tracked = find.text('第 29 段回答，稍微长一点点让它有高度。');
    double? prev;
    final steps = <double>[];
    for (var i = 1; i <= 18; i++) {
      tester.view.viewInsets = FakeViewPadding(bottom: 300.0 * i / 18);
      await tester.pump(const Duration(milliseconds: 16));
      final top = tracked.evaluate().isEmpty ? null : tester.getRect(tracked.first).top;
      if (top != null && prev != null) steps.add((top - prev).abs());
      prev = top;
    }

    expect(steps.length, greaterThan(10), reason: '有一条消息一直可见，才量得到位移');
    final even = steps.first;
    final worst = steps.reduce((a, b) => a > b ? a : b);
    final best = steps.reduce((a, b) => a < b ? a : b);
    expect(
      worst - best,
      lessThan(0.6),
      reason: '每帧位移不许忽快忽慢：最快 ${worst.toStringAsFixed(2)}px、最慢 ${best.toStringAsFixed(2)}px'
          '（第一帧 $even）——两段动画的节奏对不上时会摆到 8.6~15.1',
    );
  });
}
