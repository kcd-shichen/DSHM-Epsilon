// 环的三段落点 + 发送栏分出的 1/2 两颗。
//
// He 2026-11-23 在真机上量的规则（**两条布局都要过**：手机上 `_composerOpens` 永远为真，
// 走的是带 footer 那条；上一版把规则只写在没有 footer 那条上，等于没生效）：
//   一行装得下 → 环在行里、↑ 左边（原样）；
//   一行放不下 → 环收起来，那一格整条还给文本；
//   超过 4 行   → 环搬到 ＋ 那一列（行的左上角），竖排（环在上、<1% 在下）；
//   键盘打开     → 一律回到行里，位置和原来一样（那一态不动）。
// 发送栏：草稿滚起来之后，顶格分出 36 的「1」（⛶），下面是「2」（↑）——
// 不是等分，2 更大；栏变高只有 2 长，1 不动。

import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/usage_sheet.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/composer_fakes.dart';
import 'support/harness.dart';

/// 短：一行肯定装得下（环该在行里）。
const _short = '好的';

/// 一句长话：一行装不下、但还没到五行（环该收起来）。
const _oneFullLine = '把这句话多写一点就装不下了呀呀呀';

/// 五行以上（环该搬到 ＋ 那一列）。
final _fiveLines = '把这句话重复几遍就够五行了' * 6;

/// 滚起来（发送栏该分成 1 / 2）。
final _overflowing = 'AI 助手会把你说的每个字都记下来然后逐条回答' * 8;

Future<TextEditingController> _mount(WidgetTester tester, String text, {required bool withFooter}) async {
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
                footer: withFooter ? const SizedBox(height: 40) : null,
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

Rect _content(WidgetTester t) {
  final g = _glass(t);
  return Rect.fromLTRB(g.left + 11, g.top + 11, g.right - 11, g.bottom - 11);
}

void main() {
  setUpAll(loadTestFonts);

  for (final withFooter in [false, true]) {
    final tag = withFooter ? '（带 footer：手机上那条）' : '（无 footer）';

    testWidgets('收起 · 一行装得下：环在行里、↑ 左边$tag', (tester) async {
      await _mount(tester, _short, withFooter: withFooter);
      final ring = _ring(tester);
      expect(_field(tester).right, lessThanOrEqualTo(ring.left), reason: '环占着右边那一格');
      expect(ring.right, lessThanOrEqualTo(_content(tester).right - 36), reason: '环在发送栏左边');
    });

    testWidgets('收起 · 一行装不下：环收起，那一格还给文本$tag', (tester) async {
      final short = await _mount(tester, _short, withFooter: withFooter);
      final narrow = _field(tester).width;
      short.text = _oneFullLine;
      await tester.pumpAndSettle();
      expect(find.byType(ContextRing), findsNothing);
      expect(_field(tester).width, greaterThan(narrow + 20), reason: '环那一格整条还给文本');
    });

    testWidgets('收起 · 超过 4 行：环搬到 ＋ 那一列，竖排$tag', (tester) async {
      await _mount(tester, _fiveLines, withFooter: withFooter);
      final ring = _ring(tester);
      final plus = _plus(tester);
      expect(ring.center.dx, moreOrLessEquals(plus.center.dx, epsilon: 0.5), reason: '和 ＋ 同一列、左右居中');
      expect(ring.width, lessThan(40), reason: '竖排：只有环那么宽（横着是 54.4）');
      expect(ring.bottom, lessThan(plus.top), reason: '在 ＋ 上方');
    });

    testWidgets('滚动起来：栏顶分出 1（⛶），2（↑）占剩下的$tag', (tester) async {
      await _mount(tester, _overflowing, withFooter: withFooter);
      final content = _content(tester);
      final one = _magnify(tester);
      final two = _sendShape(tester);
      expect(one.top, moreOrLessEquals(content.top, epsilon: 0.5), reason: '1 钉在栏顶');
      expect(one.size, const Size(36, 36));
      expect(two.top, moreOrLessEquals(one.bottom + 2, epsilon: 0.5), reason: '1 和 2 之间留 2');
      expect(two.bottom, moreOrLessEquals(content.bottom, epsilon: 0.5), reason: '2 一路到底');
      expect(two.height, greaterThan(one.height), reason: '不是等分：2 比 1 大');
    });

    if (withFooter) {
      testWidgets('开键盘：环回到行里、位置和原来一样；栏缩回一颗圆', (tester) async {
        usePhoneView(tester);
        final controller = TextEditingController(text: _overflowing);
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
        final plus = _plus(tester);

        focus.requestFocus();
        await tester.pumpAndSettle();
        final content = _content(tester);
        final ring = _ring(tester);
        expect(ring.center.dx, greaterThan(content.center.dx), reason: '回到右下、贴近 ↑');
        expect(ring.bottom, moreOrLessEquals(plus.bottom, epsilon: 0.5), reason: '和 ＋ 同一条底线');
        final two = _sendShape(tester);
        expect(two.height, 36, reason: '栏缩回那颗圆');
        expect(two.bottom, moreOrLessEquals(content.bottom, epsilon: 0.5));
        final one = _magnify(tester);
        expect(one.top, moreOrLessEquals(content.top, epsilon: 0.5), reason: '⛶ 还是最顶部右侧');
        expect(one.right, moreOrLessEquals(content.right, epsilon: 0.5));
      });
    }
  }
}
