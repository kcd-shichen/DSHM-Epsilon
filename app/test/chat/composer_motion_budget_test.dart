// 输入条开合那一段，每帧只许做"布局和绘制"，不许重建 widget 树。
//
// 2026-11-27 的实测（14 帧，手机视口，从收起走到全开）：
//   改之前 ours=302，原版 1.4 的 composer 同样测法 up=148；
//   根因是右栏那个 LayoutBuilder 每帧重建整颗发送键（Pressable / Semantics /
//   AnimatedSwitcher / Icon 各 13 次），外面那层内距 Padding 也是每帧重建。
//   改成布局驱动（`_KeyRail` / `_OpenPadding`）之后 ours=148。
//
// 这条守的就是那个数：输入条再长东西也不能把开合那一段拖回"每帧重建"。

import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

void main() {
  setUpAll(loadTestFonts);

  testWidgets('开合那一段：每帧重建的 widget 数不许超过原版（148 / 14 帧）', (tester) async {
    usePhoneView(tester);
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Composer(
                  controller: controller,
                  focusNode: focus,
                  connected: true,
                  running: false,
                  onSend: () {},
                  onStop: () {},
                  leading: AttachButton(onPressed: () {}),
                  footer: const SizedBox(height: 36),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final perType = <String, int>{};
    var frame = <String, int>{};
    debugOnRebuildDirtyWidget = (Element e, bool wasDirty) {
      final t = e.widget.runtimeType.toString();
      frame[t] = (frame[t] ?? 0) + 1;
    };
    focus.requestFocus();
    await tester.pump();
    for (var i = 0; i < 14; i++) {
      frame = <String, int>{};
      await tester.pump(const Duration(milliseconds: 16));
      for (final e in frame.entries) {
        perType[e.key] = (perType[e.key] ?? 0) + e.value;
      }
    }
    debugOnRebuildDirtyWidget = null;
    await tester.pumpAndSettle();

    final total = perType.values.fold(0, (a, b) => a + b);
    // 单条最贵的几类点出来，红了能直接看出是谁又跑回每帧重建。
    final hot = perType.entries.where((e) => e.value > 14).toList()..sort((a, b) => b.value.compareTo(a.value));
    expect(
      total,
      lessThanOrEqualTo(155),
      reason: '开合那一段每帧重建的 widget 数：$total（原版 148）。超标的：$hot',
    );
  });
}
