// 环的三段落点 + 发送栏分成的 1/2 两颗。
//
// He 2026-11-23 在真机上量的规则：
//   一行装得下 → 环在行里、↑ 左边（原样）；
//   一行放不下 → 环收起来，那一列整条还给文本；
//   超过 4 行   → 环搬到 ＋ 上方那一列，竖排（环在上、<1% 在下）。
// 发送栏：草稿滚起来之后，顶格分出 36 高的「1」（⛶），下面是「2」（↑）——
// 不是等分，2 更大；栏变高只有 2 长，1 不动。开键盘时栏缩回一颗圆，1 退回裸符号。
//
// 1 和 2 的形状按 He 2026-11-24 给的示例图：同一套圆角（贴内容 6、靠外 18），
// 相对的那两刀都收在 6，中间留 4.5 的缝 —— 两格拼回去就是原来那一整条。

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

Future<TextEditingController> _pump(WidgetTester tester, String text, {bool footer = false}) async {
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
                footer: footer ? const SizedBox(height: 40) : null,
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

/// 2（↑）的底色。
Color? _twoFill(WidgetTester t) {
  final box = t.widget<Container>(find.byKey(const ValueKey('composer-send-shape')));
  return (box.decoration as BoxDecoration?)?.color;
}

/// 2（↑）四个角：读它自己那层 BoxDecoration。
BorderRadiusDirectional? _twoCorners(WidgetTester t) {
  final box = t.widget<Container>(find.byKey(const ValueKey('composer-send-shape')));
  return (box.decoration as BoxDecoration?)?.borderRadius as BorderRadiusDirectional?;
}

/// 1（⛶）四个角：它画在 ShapeDecoration 上。
BorderRadiusDirectional? _oneCorners(WidgetTester t) {
  final box = t
      .widgetList<DecoratedBox>(
        find.descendant(of: find.byKey(const ValueKey('composer-magnify')), matching: find.byType(DecoratedBox)),
      )
      .first;
  final shape = (box.decoration as ShapeDecoration).shape as RoundedRectangleBorder;
  return shape.borderRadius as BorderRadiusDirectional?;
}

/// 1（⛶）的底色。
Color? _oneFill(WidgetTester t) => (t
    .widgetList<DecoratedBox>(
      find.descendant(of: find.byKey(const ValueKey('composer-magnify')), matching: find.byType(DecoratedBox)),
    )
    .first
    .decoration as ShapeDecoration)
    .color;

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
    expect(two.top, moreOrLessEquals(one.bottom + 10, epsilon: 0.5), reason: '1 和 2 之间那道缝（He 要再拉开一点）');
    expect(two.bottom, moreOrLessEquals(content.bottom, epsilon: 0.5), reason: '2 一路到底');
    expect(two.height, greaterThan(one.height), reason: '不是等分：2 比 1 大');
    expect(
      two.height,
      moreOrLessEquals(content.height - 46, epsilon: 0.5),
      reason: '2 = 整条减掉 1 那一格和那道缝 —— 1 + 缝 + 2 拼回原来那一整条',
    );
    expect(one.top, moreOrLessEquals(content.top, epsilon: 0.5), reason: '1 从栏顶起，不留缺口');
  });

  testWidgets('1 和 2 是同一个形状家族：贴内容 6、靠外 18，相对那两刀都收在 6', (tester) async {
    await _pump(tester, 'AI 助手会把你说的每个字都记下来然后逐条回答' * 8);
    final one = _oneCorners(tester);
    final two = _twoCorners(tester);
    expect(one, isNotNull);
    expect(two, isNotNull);
    // 1：靠外那侧的上角是整条原来那道弧（18），朝下那一刀和左侧两角都是 6。
    expect(one!.topEnd, const Radius.circular(18), reason: '1 的右上角 = 整条的外圆');
    expect(one.topStart, const Radius.circular(6), reason: '1 的左上角 = 贴内容那侧');
    expect(one.bottomStart, const Radius.circular(6));
    expect(one.bottomEnd, const Radius.circular(6), reason: '朝 2 那一刀');
    // 2：整条原来那道弧交给 1 了，自己收到 6；底下那一刀仍是 18。
    expect(two!.topEnd, const Radius.circular(6), reason: '2 的顶部形变适配 1 的底');
    expect(two.topStart, const Radius.circular(6));
    expect(two.bottomStart, const Radius.circular(6));
    expect(two.bottomEnd, const Radius.circular(18), reason: '2 的下端还是整条那个外圆');

    // 两颗同色（He 2026-11-24）：1 的底色就是发送栏那个色，一位不差。
    final oneFill = _oneFill(tester);
    expect(oneFill, isNotNull);
    expect(oneFill!.a, 1.0, reason: '1 是实底');
    expect(oneFill.toARGB32(), _twoFill(tester)!.toARGB32(), reason: '1 和 2 同一个颜色');
  });

  testWidgets('带 footer 那条（手机上永远为真的那条）：1 和 2 同样是这两颗', (tester) async {
    await _pump(tester, 'AI 助手会把你说的每个字都记下来然后逐条回答' * 8, footer: true);
    final content = _content(tester);
    final one = _magnify(tester);
    final two = _sendShape(tester);
    expect(one.top, moreOrLessEquals(content.top, epsilon: 0.5), reason: '1 钉在栏顶');
    expect(one.height, 36);
    expect(two.top, moreOrLessEquals(one.bottom + 10, epsilon: 0.5), reason: '同一道 10 的缝');
    expect(two.bottom, moreOrLessEquals(content.bottom, epsilon: 0.5));
    expect(_twoCorners(tester)!.topEnd, const Radius.circular(6), reason: '两个分支一套逻辑');
  });

  testWidgets('没有 1 的时候：2 就是原来那一整条，上角还是 18', (tester) async {
    await _pump(tester, '一二三四五六七八九十百');
    expect(find.byKey(const ValueKey('composer-magnify')), findsNothing);
    expect(_twoCorners(tester)!.topEnd, const Radius.circular(18), reason: '没分栏时上角不许收');
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

  // He 2026-11-24：⛶ 的按键反馈原来还是 Material 那个**圆**水波，盖在一个方角块上。
  // 现在缩的是它自己的形状，和 ↑ 同一套（0.9）。
  testWidgets('按 ⛶：缩的是它自己的形状，不是盖一个圆水波', (tester) async {
    await _pump(tester, 'AI 助手会把你说的每个字都记下来然后逐条回答' * 8);
    final tile = find.byKey(const ValueKey('composer-magnify'));
    AnimatedScale scaleOf() => tester.widget<AnimatedScale>(
      find.descendant(of: tile, matching: find.byType(AnimatedScale)),
    );
    expect(scaleOf().scale, 1.0);
    final gesture = await tester.startGesture(tester.getCenter(tile));
    await tester.pump(const Duration(milliseconds: 150)); // 过 kPressTimeout，onTapDown 才发
    expect(scaleOf().scale, 0.9, reason: '按下时形状自己缩到 0.9');
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(scaleOf().scale, 1.0, reason: '松手弹回');
  });

  // 这一条是 He 2026-11-24 报"↑ 像从原点放大、很僵硬"查出来的：
  // 那颗「1」的底色原来是按 `split` 算的，而 `split` 在键盘开合时不跳 ——
  // 于是它一直是个实心的方块停在上沿，下面的键看着是在往它那儿"顶"。
  testWidgets('开键盘之后 1 只剩裸符号：底色跟着 _open 一帧一帧退干净', (tester) async {
    await _pump(tester, 'AI 助手会把你说的每个字都记下来然后逐条回答' * 8, footer: true);
    expect(_oneFill(tester)!.a, 1.0, reason: '收着键盘时它是实心的那一颗');

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    final focusNode = tester.widget<EditableText>(find.byType(EditableText)).focusNode;
    focusNode.requestFocus();
    await tester.pumpAndSettle();
    expect(_oneFill(tester)!.a, 0.0, reason: '键盘起来、栏缩成一颗圆，它退回裸符号');
    expect(_twoCorners(tester)!.topEnd, const Radius.circular(18), reason: '这时那颗是圆的，上角回到 18');
  });
}
