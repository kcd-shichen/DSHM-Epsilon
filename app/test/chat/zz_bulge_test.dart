import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

void main() {
  setUpAll(loadTestFonts);
  testWidgets('BULGE', (tester) async {
    usePhoneView(tester);
    final c = TextEditingController();
    final f = FocusNode();
    addTearDown(c.dispose);
    addTearDown(f.dispose);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Composer(
                  controller: c,
                  focusNode: f,
                  connected: true,
                  running: false,
                  onSend: () {},
                  onStop: () {},
                  leading: AttachButton(onPressed: () {}),
                  footer: const SizedBox(height: 36),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final heights = <double>[];
    f.requestFocus();
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      heights.add(tester.getRect(find.byKey(const ValueKey('composer-send-shape'))).height);
    }
    // ignore: avoid_print
    print('KEYH ${heights.map((h) => h.toStringAsFixed(1)).join(" ")}');
  });
}
