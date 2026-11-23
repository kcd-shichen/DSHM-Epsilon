// 环的三段落点 + 发送栏分成的 1/2 两颗。
//
// He 2026-11-23 在真机上量的规则：
//   一行装得下 → 环在行里、↑ 左边（原样）；
//   一行放不下 → 环收起来，那一列整条还给文本；
//   超过 4 行   → 环搬到 ＋ 上方那一列，竖排（环在上、<1% 在下）。
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

/// 14 个：一行装不下，环得让位。
const _fourteen = '一二三四五六七八九十百千万亿兆';

/// 五行的长草稿，但还没到滚动（maxLines 是 6）。
final _fiveLines = '把这句话重复几遍就够五行了' * 6;

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

/// 内容区（玻璃去掉四边 11）。
Rect _content(WidgetTester t) {
  final g = _glass(t);
  return Rect.fromLTRB(g.left + 11, g.top + 11, g.right - 11, g.bottom - 11);
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('收键盘 · 一行装得下：环还在行里，在 ↑ 左边', (tester) async {
    await _pump(tester, _eleven);
    final ring = _ring(tester);
    final field = _field(tester);
    final content = _content(tester);
    expect(field.right, lessThanOrEqualTo(ring.left), reason: '环占着右边那一列，文字不越过它');
    expect(ring.right, lessThanOrEqualTo(content.right - 36), reason: '环在发送栏左边');
    expect(field.width, lessThan(content.width - 40), reason: '文本没有拿到整行');
  });

  testWidgets('收键盘 · 一行放不下：环收起，那一列还给文本', (tester) async {
    await _pump(tester, _fourteen);
    expect(find.byType(ContextRing), findsNothing);
    final content = _content(tester);
    expect(_field(tester).right, moreOrLessEquals(content.right - 44, epsilon: 0.5), reason: '文本顶到发送栏左边（中间那条 8 的缝）');
  });

  testWidgets('收键盘 · 超过 4 行：环搬到 ＋ 正上方，竖排、左右居中', (tester) async {
    await _pump(tester, _fiveLines);
    final ring = _ring(tester);
    final plus = _plus(tester);
    expect(ring.center.dx, moreOrLessEquals(plus.center.dx, epsilon: 0.5), reason: '和 ＋ 同一列、左右居中');
    expect(ring.bottom, moreOrLessEquals(plus.top - 2, epsilon: 0.5), reason: '就贴在 ＋ 上方，隔 2');
    expect(ring.width, lessThan(40), reason: '竖排：只有环那么宽（横着是 54.4）');
    expect(_field(tester).right, moreOrLessEquals(_content(tester).right - 44, epsilon: 0.5), reason: '文本拿到整行');
  });

  testWidgets('滚动起来之后：发送栏顶格分出 1（⛶），2（↑）占剩下的', (tester) async {
    await _pump(tester, 'AI 助手会把你说的每个字都记下来然后逐条回答' * 8);
    final content = _content(tester);
    final one = _magnify(tester);
    final two = _sendShape(tester);
    expect(one.top, moreOrLessEquals(content.top, epsilon: 0.5), reason: '1 钉在栏顶');
    expect(one.width, 36);
    expect(one.height, 36);
    expect(two.bottom, moreOrLessEquals(content.bottom, epsilon: 0.5), reason: '2 一路到底');
    // 顶上有 1 的时候，2 自己只有一颗矮圆角矩形那么高，缝因此变大
    expect(two.height, moreOrLessEquals(44, epsilon: 0.5), reason: '2 缩回来：不再是整条');
    expect(one.top - two.top, lessThan(0), reason: '1 在上、2 在下');
    expect(two.top - one.bottom, greaterThan(2), reason: '两颗之间的缝比原来大');
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
    final closedRing = _ring(tester);

    focus.requestFocus();
    await tester.pumpAndSettle();
    final content = _content(tester);
    final ring = _ring(tester);
    expect(ring.center.dx, moreOrLessEquals(closedRing.center.dx, epsilon: 0.5), reason: '环回到底部、贴近 ↑：位置不动');
    expect(ring.bottom, moreOrLessEquals(_plus(tester).bottom, epsilon: 0.5), reason: '和 ＋ 同一条底线');
    final two = _sendShape(tester);
    expect(two.height, 36, reason: '栏缩回那颗圆');
    expect(two.bottom, moreOrLessEquals(content.bottom, epsilon: 0.5));
    final one = _magnify(tester);
    expect(one.top, moreOrLessEquals(content.top, epsilon: 0.5), reason: '⛶ 还是最顶部右侧');
    expect(one.right, moreOrLessEquals(content.right, epsilon: 0.5));
  });
}
