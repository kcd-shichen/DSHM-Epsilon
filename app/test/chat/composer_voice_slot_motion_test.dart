// 听写那一格（波形 / ✕）的收放：不许"蹦"。
//
// 2026-11-27 的同步验收里，He 肉眼看出这一格是"一帧铺满、一帧消失"——因为当时为了
// 让波形能出来，写成 `dictating ? child : AnimatedBuilder(...)`，绕过了整条收放动画。
// 这台容器上像素比不了（字体栅格不同），但**几何能比**：逐帧量这一格的宽度，
// 只要它从 0 到满之间出现过中间值、且是单调长出来的，就说明它在动，而不是跳。
//
// 这条断言的作用不是"证明好看"，是**证明它不是一帧完成的**——下次谁再写成
// 三元短路，这里当场红。

import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/mention/mention_text_controller.dart';
import 'package:dsh_app/ui/chat/voice/voice_bridge.dart';
import 'package:dsh_app/ui/chat/voice/voice_controller.dart';
import 'package:dsh_app/ui/chat/voice/voice_widgets.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/composer_fakes.dart';
import 'support/harness.dart';

class _Rig {
  final bridge = FakeVoiceBridge();
  final input = MentionTextController();
  late final voice = VoiceInputController(
    input: input,
    bridge: bridge,
    client: () => null,
    modelReady: () => false,
    observeLifecycle: false,
  );

  Future<void> pump(WidgetTester tester) async {
    usePhoneView(tester);
    addTearDown(voice.dispose);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Composer(
                  controller: input,
                  connected: true,
                  running: false,
                  onSend: () {},
                  onStop: () {},
                  leading: AttachButton(onPressed: () {}),
                  voice: voice,
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
}

/// 听写那一格的实际宽度：它是 `Align(widthFactor: t)` 外面那层 `ClipRect` 的宽度。
double _slotWidth(WidgetTester tester) {
  final clip = find.ancestor(of: find.byType(VoiceWaveform), matching: find.byType(ClipRect));
  if (clip.evaluate().isEmpty) return 0;
  return tester.getSize(clip.first).width;
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('听写那一格是长出来的，不是一帧蹦出来的', (tester) async {
    final rig = _Rig();
    await rig.pump(tester);

    expect(find.byType(VoiceWaveform), findsNothing, reason: '没听写时这一格不该在');

    await tester.tap(find.byIcon(AppIcons.voice));
    await tester.pump();

    // 逐帧（16ms 一帧）量：120ms 的过渡，落到帧上应该有四五个中间值。
    final widths = <double>[_slotWidth(tester)];
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      widths.add(_slotWidth(tester));
    }
    await tester.pump(const Duration(milliseconds: 200));
    final full = _slotWidth(tester);
    widths.add(full);

    final middle = widths.where((w) => w > 0.5 && w < full - 0.5).toList();
    expect(middle.length, greaterThanOrEqualTo(3), reason: '中间宽度只出现 ${middle.length} 个：这一格是跳出来的，不是长出来的。逐帧宽度：$widths');
    for (var i = 1; i < widths.length; i++) {
      expect(widths[i], greaterThanOrEqualTo(widths[i - 1] - 0.01), reason: '宽度不是单调长的：$widths');
    }
    expect(full, greaterThan(0), reason: '听写时这一格应该是满宽');
  });

  testWidgets('停止听写，这一格是缩回去的，不是一帧消失', (tester) async {
    final rig = _Rig();
    await rig.pump(tester);
    await tester.tap(find.byIcon(AppIcons.voice));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final full = _slotWidth(tester);
    expect(full, greaterThan(0));

    rig.voice.cancel();
    await tester.pump();
    final widths = <double>[_slotWidth(tester)];
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      widths.add(_slotWidth(tester));
    }

    final middle = widths.where((w) => w > 0.5 && w < full - 0.5).toList();
    expect(middle.length, greaterThanOrEqualTo(2), reason: '收回去也是一帧完成的：逐帧宽度：$widths');
  });
}
