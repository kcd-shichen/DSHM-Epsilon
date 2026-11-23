// 放大键（⛶）的两个落点：收键盘落在「◔ 那一列」的顶——文字那一行的顶，左右在那一格里居中；
// 开键盘回到内容区顶、那条 38 的带子里（原版位置）。两者之间是移过去的，不是跳过去的。
//
// 这一列是 He 2026-11-23 画的：文字到那里为止，键在上、圆环在下，键的中心对上圆环的中心。
// 上一版在真机上把键留在了顶上（附件条在时），所以这几条盯的就是"它到底落在哪"。

import 'dart:typed_data';

import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/usage_sheet.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/composer_fakes.dart';
import 'support/harness.dart';

/// 六行装不下的草稿：放大键靠"输入框真的能滚"长出来（见 §69）。
const _long = '现在我们优化一下按钮的逻辑这样我新建一个会话给你做替换和之前做的那件事一样替换它'
    '这样我新建一个会话给你做替换和之前做的那件事一样替换它'
    '现在我们优化一下按钮的逻辑这样我新建一个会话给你做替换和之前做的那件事一样替换它'
    '这样我新建一个会话给你做替换和之前做的那件事一样替换它'
    '现在我们优化一下按钮的逻辑这样我新建一个会话给你做替换';

final _trayItems = [
  for (var i = 0; i < 3; i++)
    DraftAttachment(name: 'img$i.png', bytes: Uint8List.fromList(List.filled(8, i))),
];

Widget _tray() => ComposerTray(items: _trayItems, onRemove: (_) {});

Widget _app({required TextEditingController text, required FocusNode focus, Widget? tray, Widget? footer}) => testApp(
      Scaffold(
        body: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Composer(
                controller: text,
                focusNode: focus,
                connected: true,
                running: false,
                onSend: () {},
                onStop: () {},
                leading: AttachButton(onPressed: () {}),
                hasAttachments: tray != null,
                tray: tray,
                accessory: ContextRing(fraction: 0.004, onTap: () {}),
                footer: footer,
              ),
            ),
          ],
        ),
      ),
    );

Rect _magnify(WidgetTester tester) => tester.getRect(find.byKey(const ValueKey('composer-magnify')));
Rect _ring(WidgetTester tester) => tester.getRect(find.byType(ContextRing));
Rect _glass(WidgetTester tester) => tester.getRect(find.byType(Composer));

void main() {
  setUpAll(loadTestFonts);

  /// 收键盘：键在那一列的正中，顶和文字那一行的顶齐平（附件条下 6）。
  void expectHome(WidgetTester tester) {
    final key = _magnify(tester);
    final ring = _ring(tester);
    final tray = tester.getRect(find.byType(ComposerTray));
    expect(key.center.dx, moreOrLessEquals(ring.center.dx, epsilon: 0.5), reason: '键的中心要落在圆环那一格的正中');
    expect(key.top, moreOrLessEquals(tray.bottom + 6, epsilon: 0.5), reason: '键的顶和文字那一行的顶齐平');
    expect(key.bottom, lessThan(ring.top), reason: '键在上面、圆环在下面，不重叠');
  }

  testWidgets('收键盘：键落在圆环那一列的顶（有附件条）', (tester) async {
    usePhoneView(tester);
    final text = TextEditingController(text: _long);
    final focus = FocusNode();
    addTearDown(text.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(_app(text: text, focus: focus, tray: _tray()));
    await tester.pumpAndSettle();
    expectHome(tester);
  });

  testWidgets('附件条后到（它自己展开，不走 build）：键跟着它落到新的顶上', (tester) async {
    usePhoneView(tester);
    final text = TextEditingController(text: _long);
    final focus = FocusNode();
    addTearDown(text.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(_app(text: text, focus: focus));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_app(text: text, focus: focus, tray: _tray()));
    await tester.pumpAndSettle();
    expectHome(tester);
  });

  testWidgets('开键盘：键回到内容区顶、右端（原版那条带子里）', (tester) async {
    usePhoneView(tester);
    final text = TextEditingController(text: _long);
    final focus = FocusNode();
    addTearDown(text.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(_app(text: text, focus: focus, tray: _tray(), footer: const SizedBox(height: 40)));
    await tester.pumpAndSettle();
    final home = _magnify(tester);

    focus.requestFocus();
    await tester.pumpAndSettle();
    final glass = _glass(tester);
    final open = _magnify(tester);
    expect(open.top, moreOrLessEquals(glass.top + 11, epsilon: 0.5), reason: '顶到内容区上沿');
    expect(open.right, moreOrLessEquals(glass.right - 11, epsilon: 0.5), reason: '右端');
    expect(open.left, greaterThan(home.left), reason: '一路往右');
    expect(open.top, lessThan(home.top), reason: '一路往上');
    // 上去的是同一个键，不是换了一颗：宽度不变。
    expect(open.width, moreOrLessEquals(home.width, epsilon: 0.5));

    focus.unfocus();
    await tester.pumpAndSettle();
    expectHome(tester);
  });

  testWidgets('收键盘的那一下是移过去的：中途在两处之间', (tester) async {
    usePhoneView(tester);
    final text = TextEditingController(text: _long);
    final focus = FocusNode();
    addTearDown(text.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(_app(text: text, focus: focus, tray: _tray(), footer: const SizedBox(height: 40)));
    await tester.pumpAndSettle();

    focus.requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final mid = _magnify(tester);
    await tester.pumpAndSettle();
    final open = _magnify(tester);
    expect(mid.top, greaterThan(open.top), reason: '还在路上');
    expect(mid.left, lessThan(open.left), reason: '还在路上');
  });
}
