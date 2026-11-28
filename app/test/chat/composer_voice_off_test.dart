// 关掉语音以后那颗键长什么样（He 2026-11-28 定的开关）。
//
// 开关本身在 chat_screen 里决定要不要把 `VoiceInputController` 交给输入条；
// 输入条这边要保证的是：没有语音时**不出现麦克风**，空草稿时那颗 ↑ 是灰的、
// 点了也不发（和 1.2 / 1.3 一样）。

import 'package:dsh_app/state/composer_voice_off.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

Future<void> _pump(WidgetTester tester) async {
  usePhoneView(tester);
  await tester.pumpWidget(
    testApp(
      Scaffold(
        body: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Composer(
                controller: TextEditingController(),
                connected: true,
                running: false,
                onSend: () {},
                onStop: () {},
                leading: AttachButton(onPressed: () {}),
                // 开关打开时 chat_screen 传的就是 null。
                voice: null,
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('没有语音时，空草稿上不出现麦克风', (tester) async {
    await _pump(tester);
    expect(find.byIcon(AppIcons.voice), findsNothing, reason: '关掉语音后不该还有麦克风采石');
    expect(find.byKey(const ValueKey('composer-send-shape')), findsOneWidget, reason: '↑ 那颗键还在');
  });

  testWidgets('空草稿上那颗 ↑ 是灰的、点了不发', (tester) async {
    var sent = 0;
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Composer(
                  controller: TextEditingController(),
                  connected: true,
                  running: false,
                  onSend: () => sent++,
                  onStop: () {},
                  leading: AttachButton(onPressed: () {}),
                  voice: null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('composer-send-shape')), warnIfMissed: false);
    await tester.pump();
    expect(sent, 0, reason: '没字的时候这颗键不该发消息（1.2 / 1.3 的规矩）');
  });

  test('开关默认是"关闭语音"', () {
    final container = ProviderContainer(overrides: const []);
    addTearDown(container.dispose);
    expect(container.read(composerVoiceOffProvider), isTrue);
  });
}
