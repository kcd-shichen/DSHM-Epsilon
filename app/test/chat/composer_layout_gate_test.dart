// 输入条的**几何门禁**（2026-11-28）。
//
// 为什么要有这一条：2026-11-27 那次同步，三处毛病（托盘整排挪 5px、听写那格"蹦"、
// 开合时发送键"鼓"）全是**肉眼**发现的——当时全仓唯一的判据是 analyze + 断言，
// 一次视觉比对都没有。上游那 1006 张 golden 在这台机器上 154 张全红（像素差
// 0.2%–56%：字体栅格不同，而且我们的界面本来就与上游不一样），所以像素当不了门禁，
// **几何能**。
//
// 这里钉的是"会动的那些东西"的规矩，不钉某一版的绝对坐标：
//   1. 两键永远是 36 的方，左右等缝、底缝等于侧缝；
//   2. 开合是**一条**曲线：单调 0→1，单帧不许跳完，总时长不许压到一两帧；
//   3. 开合过程中发送键只许往终值长，一帧都不许冲过头（27 号那版 36→45.5→36）；
//   4. 玻璃高度跟着单向走，不许回退（"忽快忽慢"会在这里翻车）。

import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

const _key = 36.0;

/// 一次装好的输入条：`openValue` 是输入条自己吐出来的 `_open`（0 收起 / 1 键盘全开）。
class _Rig {
  final focus = FocusNode();
  final open = ValueNotifier<double>(0);
  final controller = TextEditingController();

  Future<void> pump(WidgetTester tester, {bool footer = true, String text = '', double textScale = 1}) async {
    usePhoneView(tester);
    addTearDown(focus.dispose);
    addTearDown(open.dispose);
    addTearDown(controller.dispose);
    controller.text = text;
    await tester.pumpWidget(
      testApp(
        MediaQuery.withClampedTextScaling(
          minScaleFactor: textScale,
          maxScaleFactor: textScale,
          child: Scaffold(
            body: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Composer(
                    controller: controller,
                    connected: true,
                    running: false,
                    onSend: () {},
                    onStop: () {},
                    leading: AttachButton(onPressed: () {}),
                    focusNode: focus,
                    openValue: open,
                    footer: footer ? const SizedBox(height: 56) : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  /// 键盘弹开那一下：焦点回到输入条，`_open` 开始走。
  Future<void> openKeyboard(WidgetTester tester) async {
    focus.requestFocus();
    await tester.pumpAndSettle();
  }
}

/// 玻璃本人（`Composer` 的外框在展开态还包括 footer 那一条）。
Rect _glass(WidgetTester tester) =>
    tester.getRect(find.descendant(of: find.byType(Composer), matching: find.byType(GlassSurface)).first);

Rect _plus(WidgetTester tester) =>
    tester.getRect(find.ancestor(of: find.byIcon(AppIcons.add), matching: find.byType(Container)).first);

Rect _send(WidgetTester tester) => tester.getRect(find.byKey(const ValueKey('composer-send-shape')));

void _expectTwoKeys(WidgetTester tester, {bool checkBottom = true}) {
  final glass = _glass(tester);
  final plus = _plus(tester);
  final send = _send(tester);
  expect(plus.size, const Size(_key, _key), reason: '左键不是 36 的方：${plus.size}');
  expect(send.width, moreOrLessEquals(_key, epsilon: 0.6), reason: '发送键宽：${send.width}');
  final left = plus.left - glass.left;
  final right = glass.right - send.right;
  expect(left, moreOrLessEquals(right, epsilon: 0.5), reason: '左右两缝不一致：$left / $right');
  // 展开态那块玻璃把 footer 那条也算进去了，底缝没有可比性，只在收起态查。
  if (checkBottom) {
    expect(glass.bottom - plus.bottom, moreOrLessEquals(left, epsilon: 0.5), reason: '底缝与侧缝不一致');
  }
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('收起态：两键 36、左右等缝、底缝=侧缝', (tester) async {
    final rig = _Rig();
    await rig.pump(tester, footer: false);
    _expectTwoKeys(tester);
  });

  testWidgets('展开态：两键仍是 36，等缝关系不变', (tester) async {
    final rig = _Rig();
    await rig.pump(tester);
    await rig.openKeyboard(tester);
    expect(rig.open.value, moreOrLessEquals(1, epsilon: 0.01), reason: '`_open` 没走到 1：${rig.open.value}');
    _expectTwoKeys(tester, checkBottom: false);
  });

  for (final scale in [1.0, 1.3]) {
    testWidgets('文字放大 ×$scale，两键仍是 36 的方', (tester) async {
      final rig = _Rig();
      await rig.pump(tester, footer: false, textScale: scale);
      expect(_plus(tester).size, const Size(_key, _key));
      expect(_send(tester).width, moreOrLessEquals(_key, epsilon: 0.6));
    });
  }

  testWidgets('多行：左键仍是 36 的方，发送键只许长高、不许长宽', (tester) async {
    final rig = _Rig();
    await rig.pump(tester, footer: false, text: '第一行\n第二行\n第三行');
    await tester.pumpAndSettle();
    expect(_plus(tester).size, const Size(_key, _key), reason: '左键跟着文本变大了：${_plus(tester).size}');
    expect(_send(tester).width, moreOrLessEquals(_key, epsilon: 0.6), reason: '发送键变宽了：${_send(tester).size}');
    expect(_send(tester).height, greaterThan(_key), reason: '右栏是整列，多行时它应该跟行高：${_send(tester).size}');
  });

  testWidgets('开合逐帧：一条曲线、单帧不跳完、发送键不冲过头', (tester) async {
    final rig = _Rig();
    await rig.pump(tester);
    final closed = _glass(tester).height;

    rig.focus.requestFocus();
    final opens = <double>[rig.open.value];
    final heights = <double>[closed];
    final sends = <Size>[];
    var frames = 0;
    while (rig.open.value < 0.999 && frames < 120) {
      await tester.pump(const Duration(milliseconds: 16));
      frames++;
      opens.add(rig.open.value);
      heights.add(_glass(tester).height);
      sends.add(_send(tester).size);
    }
    final settled = _send(tester).size;

    // 1. 单调：`_open` 只许往上走，不许回弹。
    for (var i = 1; i < opens.length; i++) {
      expect(opens[i], greaterThanOrEqualTo(opens[i - 1] - 0.001), reason: '`_open` 回退了：$opens');
    }

    // 2. 不许一帧跳完：这一步就是"看得见的顿"与"看不见"的分界。
    expect(frames, greaterThanOrEqualTo(6), reason: '开合只用了 $frames 帧，等于瞬间完成');
    for (var i = 1; i < opens.length; i++) {
      expect(opens[i] - opens[i - 1], lessThanOrEqualTo(0.25), reason: '单帧跨了 ${opens[i] - opens[i - 1]}：$opens');
    }

    // 3. 发送键：宽度恒 36；高度从"收起那一条"收到 36，中间**不许先反向再回来**。
    //
    //    27 号那版是 36 → 45.5 → 36（先鼓出去再缩回来），那种会当场红。
    //    现在代码里还剩一次 2.1dp 的（56.0 → 58.1 → 36.0）——这笔**刻意保留**：
    //    2026-11-28 He 把修好的版本和原版来回对比，选了原动画，要求完全回退。
    //    所以容忍度是 3dp（放得过 2.1、拦得住 9.5），别再"顺手"去修它。
    final startH = sends.isEmpty ? settled.height : sends.first.height;
    final dir = settled.height <= startH ? -1 : 1;
    for (final size in sends) {
      expect(size.width, moreOrLessEquals(_key, epsilon: 0.6), reason: '发送键开合时变宽了：$size');
      final back = (size.height - startH) * dir;
      expect(back, greaterThanOrEqualTo(-3.0), reason: '高度先反向再回来（鼓包）：$size，起点 $startH，落点 $settled');
    }

    // 4. 玻璃高度单向：跟着 `_open` 走，不许忽快忽慢地回退。
    for (var i = 1; i < heights.length; i++) {
      expect(heights[i], greaterThanOrEqualTo(heights[i - 1] - 0.01), reason: '胶囊高度回退：$heights');
    }
  });
}
