// The terminal page with a scripted Host: the key row and sticky modifiers,
// the soft keyboard bridge, status rows, tabs, selection copy / paste and
// pinch to zoom.

import 'dart:ui' show Tristate;

import 'package:dsh_app/l10n/l10n.dart';

import 'dart:async';

import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/runtime_capabilities_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dsh_client/dsh_client.dart' show RuntimeCapabilities, RuntimeShellCapabilities, RuntimeSupport;
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart' show TerminalView;

import '../clipboard/fake_paste.dart';
import 'support.dart';


void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));


  group('what the engine says about a terminal', () {
    final zh = lookupL10n(AppLocale.zhCN);
    List<Override> on(String os, RuntimeSupport pty) => [
      operatingSystemProvider.overrideWithValue(os),
      runtimeCapabilitiesProvider.overrideWith(
        (ref) async => RuntimeCapabilities(shell: RuntimeShellCapabilities(pty: pty)),
      ),
    ];

    testWidgets('on HarmonyOS, no PTY: said up front, with no terminal card to fail', (tester) async {
      await pumpTerminalPage(tester, FakeTerminalBackend(), overrides: on('ohos', RuntimeSupport.unsupported));
      expect(find.text(zh.harmonyTerminalNoPty), findsOneWidget);
      expect(find.byType(TerminalView), findsNothing);
      expect(find.text(zh.commonRetry), findsNothing);
    });

    testWidgets('on HarmonyOS, a host that has one: it opens', (tester) async {
      final backend = FakeTerminalBackend();
      await pumpTerminalPage(tester, backend, overrides: on('ohos', RuntimeSupport.supported));
      expect(find.text(zh.harmonyTerminalNoPty), findsNothing);
      expect(backend.created, hasLength(1));
    });

    testWidgets('on Android the engine is not asked: it opens as ever', (tester) async {
      final backend = FakeTerminalBackend();
      await pumpTerminalPage(tester, backend, overrides: on('android', RuntimeSupport.unsupported));
      expect(find.text(zh.harmonyTerminalNoPty), findsNothing);
      expect(backend.created, hasLength(1));
    });

    for (final (os, hint) in [('ohos', zh.harmonyTerminalSupportedHosts), ('android', zh.botsTerminalSupportedHosts)]) {
      testWidgets('on $os a connection without terminals says where they are', (tester) async {
        await pumpTerminalPage(
          tester,
          FakeTerminalBackend(supported: false),
          overrides: [operatingSystemProvider.overrideWithValue(os)],
        );
        expect(find.text(hint), findsOneWidget);
      });
    }
  });

  testWidgets('the selected terminal tab exposes its selected semantics', (tester) async {
    final handle = tester.ensureSemantics();
    final backend = FakeTerminalBackend();
    await pumpTerminalPage(tester, backend);
    final id = backend.created.single['id']! as String;
    final node = tester.getSemantics(find.byKey(ValueKey('terminal-tab-$id')));
    expect(node.flagsCollection.isSelected, Tristate.isTrue);
    expect(node.flagsCollection.isInMutuallyExclusiveGroup, isTrue);
    handle.dispose();
  });



  testWidgets('ended: 已结束 with the exit code; 新建终端 starts a fresh one in place', (tester) async {
    final backend = FakeTerminalBackend(terminals: [infoJson('a', title: 'build')]);
    await pumpTerminalPage(tester, backend);
    backend.attachOf('a').state(infoJson('a', title: 'build', state: 'exited', exitCode: 1), writable: false);
    await settleTerminal(tester);
    expect(find.text('已结束 · 退出码 1'), findsOneWidget);

    await tester.tap(find.text('新建终端'));
    await settleTerminal(tester);
    expect(backend.calls, contains('close:a'));
    expect(backend.created, hasLength(1));
    expect(find.text('已结束 · 退出码 1'), findsNothing);
  });

  testWidgets('a dropped link offers 重新连接; another device holding input offers 接管', (tester) async {
    final backend = FakeTerminalBackend(terminals: [infoJson('a')]);
    await pumpTerminalPage(tester, backend);
    backend.attachOf('a').lose();
    await settleTerminal(tester);
    expect(find.text('连接已断开'), findsOneWidget);
    await tester.tap(find.text('重新连接'));
    await settleTerminal(tester);
    expect(backend.attaches, hasLength(2));

    backend.attachOf('a').state(infoJson('a'), writable: false);
    await settleTerminal(tester);
    expect(find.text('其他设备正在输入'), findsOneWidget);
    await tester.tap(find.text('接管'));
    await settleTerminal(tester);
    expect(backend.attaches, hasLength(3));
    expect(find.text('其他设备正在输入'), findsNothing);
  });

  testWidgets('tabs: switch, add, and the actions sheet closes one', (tester) async {
    final backend = FakeTerminalBackend(
      terminals: [
        infoJson('a', title: 'server'),
        infoJson('b', title: 'build', state: 'exited', exitCode: 0),
      ],
    );
    await pumpTerminalPage(tester, backend);
    expect(find.text('server'), findsOneWidget);
    expect(find.text('build'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('terminal-tab-b')));
    await settleTerminal(tester);
    expect(find.text('已结束'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('terminal-new')));
    await settleTerminal(tester);
    expect(backend.created, hasLength(1));
    expect(find.byKey(ValueKey('terminal-tab-${backend.created.single['id']}')), findsOneWidget);

    await tester.longPress(find.byKey(const ValueKey('terminal-tab-b')));
    await settleTerminal(tester);
    expect(find.text('重命名'), findsOneWidget);
    await tester.tap(find.text('关闭终端'));
    await settleTerminal(tester);
    expect(backend.calls, contains('close:b'));
    expect(find.byKey(const ValueKey('terminal-tab-b')), findsNothing);
  });

  testWidgets('closing a running terminal asks first', (tester) async {
    final backend = FakeTerminalBackend(terminals: [infoJson('a', title: 'server')]);
    await pumpTerminalPage(tester, backend);
    await tester.tap(find.byKey(const ValueKey('terminal-more')));
    await settleTerminal(tester);
    await tester.tap(find.text('关闭终端'));
    await settleTerminal(tester);
    expect(find.text('关闭「server」？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await settleTerminal(tester);
    expect(backend.calls.where((c) => c.startsWith('close:')), isEmpty);
  });

  testWidgets('the shell picker starts the chosen shell', (tester) async {
    final backend = FakeTerminalBackend(terminals: [infoJson('a')]);
    await pumpTerminalPage(tester, backend);
    await tester.tap(find.byKey(const ValueKey('terminal-more')));
    await settleTerminal(tester);
    await tester.tap(find.text('新建终端'));
    await settleTerminal(tester);
    expect(find.text('选择 Shell'), findsOneWidget);
    await tester.tap(find.text('fish'));
    await settleTerminal(tester);
    expect(backend.created.single['shellPath'], '/usr/bin/fish');
  });


  group('粘贴 on HarmonyOS', () {
    Future<void> selectAndPaste(WidgetTester tester) async {
      final view = tester.getRect(find.byType(TerminalView));
      await tester.longPressAt(view.topLeft + const Offset(14, 8));
      await settleTerminal(tester);
      await tester.tap(find.text('粘贴'));
      await settleTerminal(tester);
    }

    final onHarmony = [operatingSystemProvider.overrideWithValue('ohos')];

    testWidgets('the system paste button\'s text goes in as it is', (tester) async {
      final paste = FakePaste(tester, reply: FakePaste.text('echo pasted\n'), flutterText: 'wrong');
      final backend = FakeTerminalBackend(terminals: [infoJson('a')])..screens['a'] = 'hello world\r\n\$ ';
      await pumpTerminalPage(tester, backend, overrides: onHarmony);
      await selectAndPaste(tester);
      expect(backend.attachOf('a').written, contains('echo pasted'));
      expect(paste.flutterReads, 0);
    });

    testWidgets('backed out of, nothing goes in and nothing is said', (tester) async {
      FakePaste(tester, reply: {'status': 'cancelled'});
      final backend = FakeTerminalBackend(terminals: [infoJson('a')])..screens['a'] = 'hello world\r\n\$ ';
      await pumpTerminalPage(tester, backend, overrides: onHarmony);
      final before = backend.attachOf('a').written.length;
      await selectAndPaste(tester);
      expect(backend.attachOf('a').written.length, before);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a paste still waiting is for its terminal: another tab closes the window', (tester) async {
      final paste = FakePaste(tester, reply: FakePaste.text('echo late\n'))..gate = Completer<void>();
      final backend = FakeTerminalBackend(
        terminals: [
          infoJson('a', title: 'one'),
          infoJson('b', title: 'two'),
        ],
      )..screens['a'] = 'hello world\r\n\$ ';
      await pumpTerminalPage(tester, backend, overrides: onHarmony);
      await selectAndPaste(tester);
      expect(paste.reads, hasLength(1));
      await tester.tap(find.byKey(const ValueKey('terminal-tab-b')));
      await settleTerminal(tester);
      expect(paste.cancels, contains(paste.reads.single));
      paste.gate!.complete();
      await settleTerminal(tester);
      expect(backend.attachOf('a').written, isNot(contains('echo late')));
      expect(backend.attachOf('b').written, isNot(contains('echo late')));
    });
  });



  testWidgets('a connection without terminal support says so', (tester) async {
    await pumpTerminalPage(tester, FakeTerminalBackend(supported: false));
    expect(find.text('这个连接用不了终端'), findsOneWidget);
    expect(find.byType(TerminalView), findsNothing);
    expect(find.byKey(const ValueKey('terminal-more')), findsNothing);
  });

  testWidgets('a terminal the engine lost: 这个终端已不在了 → 新建终端', (tester) async {
    final backend = FakeTerminalBackend(terminals: [infoJson('a')]);
    await pumpTerminalPage(tester, backend);
    backend.host.remove('a');
    backend.attachOf('a').lose();
    await settleTerminal(tester);
    await tester.tap(find.text('重新连接'));
    await settleTerminal(tester);
    expect(find.text('这个终端已不在了'), findsOneWidget);
    await tester.tap(find.text('新建终端'));
    await settleTerminal(tester);
    expect(backend.created, hasLength(1));
    expect(find.text('这个终端已不在了'), findsNothing);
  });
}
