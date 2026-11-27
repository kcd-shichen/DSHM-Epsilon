// 空草稿开键盘时，那颗发送键**不许鼓**。
//
// 2026-11-27：右栏的高度是 `lerp(36, 这一列的高度, 1 - _open)`，而"这一列的高度"
// 本身在开合过程中也在动——两次插值叠加，那颗键就 36 → 45.5 → 36 地鼓一下。
// 这是我们的输入条和原版 1.4 唯一真正的差别（原版那颗键是一颗固定的圆），
// 白画一层、白重排一帧地陪着整段动画跑。修法：目标高度只在开合的两端取。

import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

void main() {
  setUpAll(loadTestFonts);

  testWidgets('空草稿开键盘：发送键高度一路上都是 36', (tester) async {
    usePhoneView(tester);
    final c = TextEditingController();
    final f = FocusNode();
    addTearDown(c.dispose);
    addTearDown(f.dispose);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Composer(
                  controller: c,
                  focusNode: f,
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

    final heights = <double>[];
    f.requestFocus();
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      heights.add(tester.getRect(find.byKey(const ValueKey('composer-send-shape'))).height);
    }
    final worst = heights.reduce((a, b) => a > b ? a : b);
    expect(
      worst,
      lessThan(37),
      reason: '这颗键在开合中间鼓起来了：${heights.map((h) => h.toStringAsFixed(1)).join(" ")}',
    );
  });
}
