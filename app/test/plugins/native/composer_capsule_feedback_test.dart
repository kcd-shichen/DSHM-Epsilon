// 一颗胶囊的六件事（He 2026-11-26「重做胶囊」）：
// 版式一套 · 位置和规格一套 · 进出场在原位升降 · 按压是本体伸 · 点一下响一次 ·
// 长按把话说全（叫什么、从哪来）。

import 'package:dsh_app/ui/chat/usage_sheet.dart' show ContextRing;
import 'package:dsh_app/ui/common/pressable.dart';
import 'package:dsh_app/ui/plugins/native/composer_capsules.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../chat/support/harness.dart';

const _double = 0.01;

void expectClose(double actual, double expected, String what) =>
    expect(actual, closeTo(expected, _double), reason: what);

Widget row(List<CapsuleItem> items, {Widget? ring}) => testApp(
  Scaffold(
    backgroundColor: Colors.transparent,
    body: Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: ComposerCapsuleRow(items: items, ring: ring),
      ),
    ),
  ),
);

CapsuleItem ui(String label, {int n = 0, VoidCallback? onTap}) =>
    CapsuleItem(id: 'ui:$n', label: label, onTap: onTap ?? () {});

final _pluginCapsule = CapsuleItem(
  id: 'com.example.usage#cost',
  label: '看看成本',
  icon: AppIcons.plugin,
  source: '用量',
  onTap: () {},
);

Opacity _lift(WidgetTester tester, String id) =>
    tester.widget<Opacity>(find.byKey(ValueKey('capsule-lift-' + id)));

void main() {
  setUpAll(loadTestFonts);

  testWidgets('环是这一行的最后一颗：紧跟「插件」、同高、同一副外壳', (tester) async {
    usePhoneView(tester);
    final open = ValueNotifier<double>(0);
    addTearDown(open.dispose);
    await tester.pumpWidget(
      row([
        ui('胶囊甲'),
        CapsuleItem(id: 'p#1', label: '看看成本', icon: AppIcons.plugin, source: '用量', onTap: () {}),
      ], ring: CapsuleRing(ring: const ContextRing(fraction: 0.004), open: open, onTap: () {})),
    );
    await tester.pumpAndSettle();

    final ring = tester.getRect(find.byType(CapsuleRing));
    final last = tester.getRect(find.byType(ComposerCapsule).at(1));
    expect(ring.left, greaterThan(last.right), reason: '排在「插件」后面');
    expectClose(ring.left - last.right, CapsuleMetrics.gap, '行的间距');
    expectClose(ring.height, CapsuleMetrics.height, '同高');
    expectClose(ring.top, last.top, '同一行');
  });

  testWidgets('键盘一开，环那颗往下沉进输入框下层；前面的胶囊一颗都不挪', (tester) async {
    usePhoneView(tester);
    final open = ValueNotifier<double>(0);
    addTearDown(open.dispose);
    await tester.pumpWidget(
      row([ui('胶囊甲'), ui('胶囊乙', n: 1)], ring: CapsuleRing(ring: const ContextRing(fraction: 0.004), open: open, onTap: () {})),
    );
    await tester.pumpAndSettle();
    final before = [for (var i = 0; i < 2; i++) tester.getRect(find.byType(ComposerCapsule).at(i))];
    final boxBefore = tester.getRect(find.byType(CapsuleRing));
    // 位移是画在里面的，量那颗环本身才准。
    final ringBefore = tester.getRect(find.byType(ContextRing));

    open.value = 0.5;
    await tester.pump();
    final boxHalf = tester.getRect(find.byType(CapsuleRing));
    expectClose(boxHalf.width, boxBefore.width, '宽度一个像素都不动（不动宽度，就没有四角黑影）');
    expectClose(boxHalf.left, boxBefore.left, '左边界不动');
    expect(tester.getRect(find.byType(ContextRing)).top, greaterThan(ringBefore.top + 10), reason: '往下沉了');
    for (var i = 0; i < 2; i++) {
      expectClose(tester.getRect(find.byType(ComposerCapsule).at(i)).left, before[i].left, '第 $i 颗不动');
    }

    open.value = 1;
    await tester.pump();
    expectClose(tester.getRect(find.byType(ContextRing)).top, ringBefore.top + CapsuleMetrics.sink, '沉到底');
    final fade = tester.widget<Opacity>(
      find.descendant(of: find.byType(CapsuleRing), matching: find.byType(Opacity)).first,
    );
    expect(fade.opacity, 0, reason: '后半段化掉，收进玻璃底下');
    for (var i = 0; i < 2; i++) {
      expectClose(tester.getRect(find.byType(ComposerCapsule).at(i)).left, before[i].left, '第 $i 颗还是不动');
    }
  });

  testWidgets('版式一套：同高、内距左右相等、行距同一条', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(row([ui('胶囊甲'), _pluginCapsule]));
    await tester.pumpAndSettle();

    final capsules = find.byType(ComposerCapsule);
    expect(capsules, findsNWidgets(2));
    final a = tester.getRect(capsules.at(0));
    final b = tester.getRect(capsules.at(1));
    expectClose(a.height, CapsuleMetrics.height, '第一颗高');
    expectClose(b.height, CapsuleMetrics.height, '带图标那颗一样高');
    expectClose(b.top, a.top, '同一行');
    expectClose(b.left - a.right, CapsuleMetrics.gap, '行距');

    // 有图标 / 没图标，右边那段留白一样宽（图标是内容，不是版式）。
    for (final (i, r) in [a, b].indexed) {
      final text = tester.getRect(find.descendant(of: capsules.at(i), matching: find.byType(Text)));
      expectClose(r.right - text.right, CapsuleMetrics.inset, '第 $i 颗右内距');
    }
  });

  testWidgets('宽度跟着字数走：长几颗字就宽几颗字，两边留白一样', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(row([ui('甲', n: 0), ui('甲甲甲甲甲甲', n: 1)]));
    await tester.pumpAndSettle();

    final short = find.byType(ComposerCapsule).at(0);
    final long = find.byType(ComposerCapsule).at(1);
    final shortRect = tester.getRect(short);
    final longRect = tester.getRect(long);
    final shortText = tester.getRect(find.descendant(of: short, matching: find.byType(Text)));
    final longText = tester.getRect(find.descendant(of: long, matching: find.byType(Text)));

    expectClose(
      longRect.width - shortRect.width,
      longText.width - shortText.width,
      '胶囊宽出来的部分，正好是文字宽出来的部分',
    );
    for (final (name, rect, text) in [('短', shortRect, shortText), ('长', longRect, longText)]) {
      expectClose(text.left - rect.left, CapsuleMetrics.inset, '$name：左留白');
      expectClose(rect.right - text.right, CapsuleMetrics.inset, '$name：右留白');
    }
  });

  testWidgets('环那颗的字也顶住胶囊，颜色和别的胶囊一样', (tester) async {
    usePhoneView(tester);
    final open = ValueNotifier<double>(0);
    addTearDown(open.dispose);
    await tester.pumpWidget(
      row(
        [ui('胶囊甲')],
        ring: CapsuleRing(ring: const ContextRing(fraction: 0.004, bare: true), open: open, onTap: () {}),
      ),
    );
    await tester.pumpAndSettle();

    final capsule = find.byType(ComposerCapsule);
    final ringCapsule = find.byType(CapsuleRing);
    final capsuleText = find.descendant(of: capsule, matching: find.byType(Text));
    final ringText = find.descendant(of: ringCapsule, matching: find.byType(Text));

    // 顶住：右边那段留白和别的胶囊一模一样（以前这里多套了 6）。
    expectClose(
      tester.getRect(ringCapsule).right - tester.getRect(ringText).right,
      CapsuleMetrics.inset,
      '环那颗：右留白',
    );
    // 颜色统一。
    expect(
      tester.widget<Text>(ringText).style?.color,
      tester.widget<Text>(capsuleText).style?.color,
      reason: '两边的字同一个颜色',
    );
  });

  testWidgets('按下去是本体伸；水波那下反馈关掉；点一下只响一次', (tester) async {
    usePhoneView(tester);
    final haptics = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') haptics.add(call.arguments);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    var taps = 0;
    await tester.pumpWidget(row([ui('胶囊甲', onTap: () => taps++)]));
    await tester.pumpAndSettle();

    final press = tester.widget<Pressable>(
      find.descendant(of: find.byType(ComposerCapsule), matching: find.byType(Pressable)),
    );
    expect(press.scale, AppMotion.pressLift, reason: '和发送键、⛶ 同一套：本体伸');
    expect(press.onTap, isNull, reason: 'Pressable 只管缩放，不抢手势');
    final ink = tester.widget<InkWell>(
      find.descendant(of: find.byType(ComposerCapsule), matching: find.byType(InkWell)),
    );
    expect(ink.enableFeedback, isFalse, reason: 'InkWell 不再自己响');

    await tester.tap(find.byType(ComposerCapsule));
    await tester.pumpAndSettle();
    expect(taps, 1, reason: '点一下，动作照做');
    expect(haptics, ['HapticFeedbackType.selectionClick'], reason: '一下，就是这一下');
  });

  testWidgets('长按把话说全：叫什么、从哪来；不改状态', (tester) async {
    usePhoneView(tester);
    var taps = 0;
    await tester.pumpWidget(row([ui('胶囊甲', onTap: () => taps++), _pluginCapsule]));
    await tester.pumpAndSettle();

    final second = find.byType(ComposerCapsule).at(1);
    final tip = tester.widget<Tooltip>(find.descendant(of: second, matching: find.byType(Tooltip)));
    expect(tip.message, '看看成本 · 用量');
    expect(tip.triggerMode, TooltipTriggerMode.longPress);
    expect(tip.preferBelow, isFalse, reason: '这一行在输入条上面，提示要往上弹');

    await tester.longPress(second);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('看看成本 · 用量'), findsOneWidget, reason: '长按出提示');
    expect(taps, 0, reason: '长按不改状态');
    await tester.pumpAndSettle();
  });

  testWidgets('增减一颗：新来的在原位升上来，在位的不动；走掉的沉完才摘', (tester) async {
    usePhoneView(tester);
    final a = ui('胶囊甲');
    final b = ui('胶囊乙', n: 1);

    await tester.pumpWidget(row([a]));
    await tester.pumpAndSettle();
    expect(find.byType(ComposerCapsule), findsOneWidget);

    await tester.pumpWidget(row([a, b]));
    await tester.pump();
    expect(_lift(tester, 'ui:0').opacity, 1.0, reason: '在位的那颗一个像素都不动');
    expect(_lift(tester, 'ui:1').opacity, lessThan(0.5), reason: '新来的从透明升上来');
    await tester.pumpAndSettle();
    expect(_lift(tester, 'ui:1').opacity, 1.0, reason: '升到位');

    await tester.pumpWidget(row([a]));
    await tester.pump();
    expect(find.byType(ComposerCapsule), findsNWidgets(2), reason: '沉的过程中还在');
    await tester.pump(const Duration(milliseconds: 80));
    expect(_lift(tester, 'ui:1').opacity, lessThan(1.0), reason: '正在沉');
    await tester.pumpAndSettle();
    expect(find.byType(ComposerCapsule), findsOneWidget, reason: '沉完摘掉');
  });
}
