// 环的落点 + 发送栏分成的 1/2 两颗。
//
// He 2026-11-25 定的衔接：落点只有一个——打开时在行里、↑ 左边；
// 收起时那一格整条塌到 0（环这时是胶囊行里的最后一颗，见
// `composer_capsule_feedback_test`）。所以没有"三段"可跳了（E11 作废）。
// 发送栏：草稿滚起来之后，顶格分出 36 高的「1」（⛶），下面是「2」（↑）——
// 不是等分，2 更大；栏变高只有 2 长，1 不动。开键盘时栏缩回一颗圆，1 退回裸符号。

import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/usage_sheet.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/composer_fakes.dart';
import 'support/harness.dart';

/// 11 个中文字：有环时一行正好装得下（他的实测值）。
const _eleven = '一二三四五六七八九十百';

Future<TextEditingController> _pump(WidgetTester tester, String text) async {
  usePhoneView(tester);
  final controller = TextEditingController(text: text);
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
                accessory: ContextRing(fraction: 0.004, onTap: () {}),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

Rect _glass(WidgetTester t) => t.getRect(find.byType(Composer));
Rect _field(WidgetTester t) => t.getRect(find.byType(EditableText));
Rect _ring(WidgetTester t) => t.getRect(find.byType(ContextRing));
Rect _plus(WidgetTester t) => t.getRect(find.byIcon(AppIcons.add));
Rect _magnify(WidgetTester t) => t.getRect(find.byKey(const ValueKey('composer-magnify')));
Rect _sendShape(WidgetTester t) => t.getRect(find.byKey(const ValueKey('composer-send-shape')));

/// 四边内距：收起态照原版（1.4）的 6，开键盘后插值到我们的 11（He 2026-11-27）。
const _insetClosed = 6.0;
const _insetOpen = 11.0;

/// 内容区（玻璃去掉四边内距）。按用例所处的态取，两个态不是同一个数。
Rect _content(WidgetTester t, {double inset = _insetClosed}) {
  final g = _glass(t);
  return Rect.fromLTRB(g.left + inset, g.top + inset, g.right - inset, g.bottom - inset);
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('收键盘：行里没有环——那一格塌成 0，文本拿到整行', (tester) async {
    await _pump(tester, _eleven);
    expect(find.byType(ContextRing), findsNothing, reason: '收起时环是胶囊行里的最后一颗，行里那格是 0');
    final content = _content(tester);
    expect(_field(tester).right, greaterThan(content.right - 50), reason: '文本拿到整行，只让出发送键那一格');
  });

  testWidgets('滚动起来之后：发送栏顶格分出 1（⛶），2（↑）占剩下的', (tester) async {
    await _pump(tester, 'AI 助手会把你说的每个字都记下来然后逐条回答' * 8);
    final content = _content(tester);
    final one = _magnify(tester);
    final two = _sendShape(tester);
    expect(one.top, moreOrLessEquals(content.top, epsilon: 0.5), reason: '1 钉在栏顶');
    expect(one.width, 36);
    expect(one.height, 36);
    expect(two.top, moreOrLessEquals(one.bottom + 9, epsilon: 0.5), reason: '1 和 2 之间留 9（长条短一截）');
    expect(two.bottom, moreOrLessEquals(content.bottom, epsilon: 0.5), reason: '2 一路到底');
    expect(two.height, greaterThan(one.height), reason: '不是等分：2 比 1 大');
    expect(two.height, moreOrLessEquals(content.height - 45, epsilon: 0.5), reason: '2 = 整条减掉 1 那一格和那道 9 的缝');
  });

  testWidgets('开合全程：⛶ 不许在动画中间凭空出现或消失', (tester) async {
    // He 2026-11-26：收起态与全开态各判各的时候，判据会在动画中间翻脸，连带那条
    // 带子的高度、箭头键的落点、文字重排一起跳一下。现在判据只在「全开」那一态取，
    // 收起态跟着走——所以整段开合里它的有无必须是恒定的。
    usePhoneView(tester);
    final controller = TextEditingController(text: '一' * 120);
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
                  footer: const SizedBox(height: 28),
                  keyboardInset: 0,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    bool magnify() => find.byKey(const ValueKey('composer-magnify')).evaluate().isNotEmpty;
    final atRest = magnify();

    focus.requestFocus();
    final seen = <bool>[];
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      seen.add(magnify());
    }
    expect(seen.every((v) => v == atRest), isTrue, reason: '开键盘的过程中它变了：$seen');
  });

  testWidgets('开键盘：环回右下、⛶ 回到内容区右上、栏缩回一颗圆', (tester) async {
    usePhoneView(tester);
    final controller = TextEditingController(text: 'AI 助手会把你说的每个字都记下来然后逐条回答' * 8);
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
                  accessory: ContextRing(fraction: 0.004, onTap: () {}),
                  footer: const SizedBox(height: 40),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ContextRing), findsNothing, reason: '收起时那一格是 0');

    focus.requestFocus();
    await tester.pumpAndSettle();
    // 键盘开了：四边内距是展开态的 11。
    final content = _content(tester, inset: _insetOpen);
    final ring = _ring(tester);
    expect(ring.bottom, moreOrLessEquals(_plus(tester).bottom, epsilon: 0.5), reason: '和 ＋ 同一条底线');
    final two = _sendShape(tester);
    expect(two.height, 36, reason: '栏缩回那颗圆');
    expect(two.bottom, moreOrLessEquals(content.bottom, epsilon: 0.5));
    final one = _magnify(tester);
    expect(one.top, moreOrLessEquals(content.top, epsilon: 0.5), reason: '⛶ 还是最顶部右侧');
    expect(one.right, moreOrLessEquals(content.right, epsilon: 0.5));
  });
}
