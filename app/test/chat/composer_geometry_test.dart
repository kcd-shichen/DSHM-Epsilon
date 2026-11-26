// The composer's round keys sit in its capsule like a pill's end caps: on one
// line, the gap above, below and beside each key is the same, and the + on
// the left mirrors the send key on the right. Taller (multi-line) input keeps
// the keys at the bottom with the same bottom and side gaps. With voice, the
// mic takes the send key's place on an empty draft, and while dictating the
// ✕ takes the +'s: all four are the same 36 circle in the same two seats. A new
// line grows the capsule from its bottom edge, and a pinned list follows it.

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/mention/mention_text_controller.dart';
import 'package:dsh_app/ui/chat/voice/voice_controller.dart';
import 'package:dsh_app/ui/chat/voice/voice_widgets.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/composer_fakes.dart';
import 'support/harness.dart';
import 'support/sample_chat.dart';

Future<TextEditingController> _pump(
  WidgetTester tester, {
  String text = '',
  double textScale = 1,
  VoiceInputController? voice,
  bool running = false,
  bool stopping = false,
  bool waiting = false,
  String? waitHint,
  VoidCallback? onStop,
  TextEditingController? input,
}) async {
  usePhoneView(tester);
  final controller = input ?? TextEditingController(text: text);
  await tester.pumpWidget(
    testApp(
      MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        // As in the chat screen: a bottom column of intrinsic height.
        child: Scaffold(
          body: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Composer(
                  controller: controller,
                  connected: true,
                  running: running,
                  stopping: stopping,
                  waiting: waiting,
                  waitHint: waitHint,
                  onSend: () {},
                  onStop: onStop ?? () {},
                  leading: AttachButton(onPressed: () {}),
                  voice: voice,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return controller;
}

Rect _capsule(WidgetTester tester) => tester.getRect(find.byType(Composer));
Rect _plus(WidgetTester tester) =>
    tester.getRect(find.ancestor(of: find.byIcon(AppIcons.add), matching: find.byType(Container)).first);
Rect _send(WidgetTester tester) => _round(tester, AppIcons.send);

/// 发送键那**一块形状**：它现在由 `Pressable` 的 ScaleTransition 带着（按住伸 1.06），
/// 静止时缩放是 1，所以 rect 就是形状本人。不能再按 `AnimatedScale` 找 —— 那个已经没了。
Rect _round(WidgetTester tester, IconData icon) =>
    tester.getRect(find.byKey(const ValueKey('composer-send-shape')));

Rect _cancel(WidgetTester tester) =>
    tester.getRect(find.ancestor(of: find.byIcon(AppIcons.close), matching: find.byType(Container)).first);

/// The two keys sit like end caps: same size, same gap to every edge.
void _expectEndCaps(WidgetTester tester, Rect left, Rect right) {
  final capsule = _capsule(tester);
  final side = left.left - capsule.left;
  expect(left.size, const Size(36, 36));
  // 发送键现在是那个形状本人：宽永远是 36，高度跟这一行走（圆的时候就是这颗 36 的圆，
  // 只差字号带来的零点几像素）。
  expect(right.width, left.width);
  expect(right.height, moreOrLessEquals(left.height, epsilon: 0.5));
  expect(capsule.right - right.right, moreOrLessEquals(side, epsilon: 0.5));
  for (final key in [left, right]) {
    expect(capsule.bottom - key.bottom, moreOrLessEquals(side, epsilon: 0.5));
  }
}

VoiceInputController _voice(TextEditingController input) {
  final voice = VoiceInputController(
    input: input,
    bridge: FakeVoiceBridge(),
    client: () => null,
    observeLifecycle: false,
  );
  addTearDown(voice.dispose);
  return voice;
}

void main() {
  testWidgets('stopping keeps a symmetric 36dp key', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, running: true, stopping: true);
    final busy = find.byKey(const ValueKey('composer-send-shape'));
    _expectEndCaps(tester, _plus(tester), tester.getRect(busy));
    expect(find.bySemanticsLabel('正在停止'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a waiting stop key is quiet and still stops', (tester) async {
    var stops = 0;
    await _pump(tester, running: true, waiting: true, onStop: () => stops++);
    // The approval card and the header say what waits; the hint is the plain
    // one, not 「生成中」.
    expect(tester.widget<TextField>(find.byType(TextField)).decoration!.hintText, '给 DSH 发消息…');
    // 底色只有一层：形状本人画的（§67、§68）。
    final key = find.descendant(
      of: find.byKey(const ValueKey('composer-send-shape')),
      matching: find.byType(DecoratedBox),
    ).first;
    final decoration = tester.widget<DecoratedBox>(key).decoration as BoxDecoration;
    final colors = Theme.of(tester.element(find.byType(Composer))).colorScheme;
    expect(decoration.color, colors.onSurface.withValues(alpha: 0.06));
    await tester.tap(find.byIcon(AppIcons.stopGenerating));
    expect(stops, 1);
  });

  for (final scale in [1.0, 1.3]) {
    testWidgets('one line: equal gaps all round, + mirrors send (text ×$scale)', (tester) async {
      await _pump(tester, textScale: scale);
      final capsule = _capsule(tester);
      final plus = _plus(tester);
      final send = _send(tester);
      final side = plus.left - capsule.left;
      expect(capsule.right - send.right, moreOrLessEquals(side, epsilon: 0.5));
      for (final key in [plus, send]) {
        expect(key.top - capsule.top, moreOrLessEquals(side, epsilon: 0.5));
        expect(capsule.bottom - key.bottom, moreOrLessEquals(side, epsilon: 0.5));
      }
    });
  }

  testWidgets('several lines: keys stay at the bottom with the same gaps', (tester) async {
    await _pump(tester, text: '第一行\n第二行\n第三行');
    final capsule = _capsule(tester);
    final plus = _plus(tester);
    final send = _send(tester);
    final side = plus.left - capsule.left;
    expect(capsule.height, greaterThan(plus.height + 2 * side + 20));
    expect(capsule.right - send.right, moreOrLessEquals(side, epsilon: 0.5));
    expect(capsule.bottom - plus.bottom, moreOrLessEquals(side, epsilon: 0.5));
    expect(capsule.bottom - send.bottom, moreOrLessEquals(side, epsilon: 0.5));
  });

  testWidgets('a new line grows the capsule; the keys and the bottom edge stay put', (tester) async {
    final input = await _pump(tester);
    final one = _capsule(tester);
    final key = _plus(tester);

    input.text = '第一行\n第二行';
    await tester.pump();
    expect(_capsule(tester), one);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final growing = _capsule(tester);
    expect(growing.height, greaterThan(one.height));
    expect(growing.bottom, one.bottom);
    expect(_plus(tester), key);

    await tester.pump(const Duration(milliseconds: 81));
    final two = _capsule(tester);
    expect(two.height, greaterThan(growing.height));
    expect(two.bottom, one.bottom);
    expect(_plus(tester), key);

    // Fewer lines: the same way back.
    input.text = '第一行';
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(_capsule(tester).height, lessThan(two.height));
    expect(_capsule(tester).height, greaterThan(one.height));
    await tester.pump(const Duration(milliseconds: 81));
    expect(_capsule(tester), one);
  });

  testWidgets('a long line that wraps past the field grows the enlarge key', (tester) async {
    // 换行符一个都没有，但一行折到要滚——判据是"能不能滚"，不是数 \n（§69）。
    // 本机字体度量下 12 遍还够不着"要滚"的判据（判据 = 排版高度超过 maxLines 行），
    // 24 遍才真的越线。行数没变，只是让这条断言真的站在阈值另一侧。
    final input = await _pump(tester, text: '这是一段很长的话' * 24);
    await tester.pump();
    expect(find.byKey(const ValueKey('composer-magnify')), findsOneWidget);

    input.text = '短';
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('composer-magnify')), findsNothing);
  });

  testWidgets('reduced motion: a new line is simply there', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final input = await _pump(tester);
    final one = _capsule(tester);
    input.text = '第一行\n第二行';
    await tester.pump();
    expect(find.byType(AnimatedSize), findsNothing);
    expect(_capsule(tester).height, greaterThan(one.height));
  });

  testWidgets('a list pinned to the bottom stays on the capsule while it grows', (tester) async {
    usePhoneView(tester);
    final harness = ChatHarness(
      session: 's1',
      states: {
        's1': ChatState(
          title: '测试',
          loading: false,
          items: [for (var i = 0; i < 30; i++) assistant(i + 1, '第 $i 段回答')],
        ),
      },
    );
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester);
    double gap() => tester.getTopLeft(find.byType(Composer)).dy - tester.getBottomLeft(find.text('第 29 段回答')).dy;
    final resting = gap();
    final top = tester.getTopLeft(find.byType(Composer)).dy;

    tester.widget<TextField>(find.byType(TextField)).controller!.text = '第一行\n第二行';
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(gap(), moreOrLessEquals(resting, epsilon: 0.5), reason: 'frame $i');
    }
    expect(tester.getTopLeft(find.byType(Composer)).dy, lessThan(top));
  });

  testWidgets('the send key eases its new icon in', (tester) async {
    await _pump(tester);
    final swap = find.ancestor(of: find.byIcon(AppIcons.send), matching: find.byType(AnimatedSwitcher)).first;
    expect(tester.widget<AnimatedSwitcher>(swap).switchInCurve, AppMotion.enter);
  });

  for (final scale in [1.0, 1.3]) {
    testWidgets('the mic mirrors the + on an empty draft (text ×$scale)', (tester) async {
      final input = MentionTextController();
      await _pump(tester, input: input, voice: _voice(input), textScale: scale);
      await tester.pump();
      final mic = _round(tester, AppIcons.voice);
      final plus = _plus(tester);
      _expectEndCaps(tester, plus, mic);
      expect(mic.top - _capsule(tester).top, moreOrLessEquals(plus.top - _capsule(tester).top, epsilon: 0.5));
    });
  }

  testWidgets('dictating: ✕ and ■ in the same seats, the level bars lower '
      'than the keys and centred on them', (tester) async {
    final input = MentionTextController();
    final voice = _voice(input);
    await _pump(tester, input: input, voice: voice);
    await tester.pump();
    final empty = _capsule(tester);
    final plus = _plus(tester);
    await voice.start();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(voice.phase, VoicePhase.listening);

    final cancel = _cancel(tester);
    final stop = _round(tester, AppIcons.stopGenerating);
    expect(cancel, plus);
    _expectEndCaps(tester, cancel, stop);
    expect(_capsule(tester), empty);

    final bars = tester.getRect(find.byType(VoiceWaveform));
    expect(bars.height, 36);
    expect(bars.center.dy, moreOrLessEquals(stop.center.dy, epsilon: 0.5));
    expect(VoiceWaveform.maxHeight, lessThan(stop.height));
    // The bars sit next to the stop key like the context ring does.
    expect(stop.left - bars.right, moreOrLessEquals(2, epsilon: 0.5));
  });
}
