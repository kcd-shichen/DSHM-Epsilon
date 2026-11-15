// Fork-side replacement for `ui/terminal/terminal_keyboard.dart`.
//
// Upstream's bridge has two separate defects. Only one of them is still ours to
// fix.
//
// 1. The IME's right-arrow key did nothing.  (fixed here)
//
// Upstream returns early whenever the IME reports unchanged text, so a caret
// move produces no event at all. Worse, its sentinel is two spaces with the
// caret at offset 2 -- the end of the text. A caret cannot move right from the
// end, so `arrow right` was clamped back to 2 and produced nothing even in
// principle. `arrow left` only appeared to work: some IMEs report a shorter
// text alongside the caret move, which a prefix-only diff read as one backspace.
//
// Here the sentinel is three spaces with the caret at 2: one slot left, one
// slot right. A caret move of N places becomes N arrow keys -- left/right on a
// terminal is the pty cursor -- and the caret is put back so the next diff
// still means what it says. Because the caret is no longer pinned to the end,
// the diff is measured from both ends (`_diffAgainstSentinel`).
//
// 2. The keyboard did not come back.  (NOT fixed here -- upstream fixed it)
//
// `show()` must close the connection before opening a new one. That close is
// the load-bearing part: it sends `clearClient`, which is what makes the
// platform forget the old input session. Re-attaching without it leaves Android
// still holding a client, and the following show request is ignored -- silently,
// with no error and no callback. `attached` is only Dart-side bookkeeping and
// says nothing about whether the platform still has a session.
//
// This file used to deviate from that in three ways, and all three made it
// worse, which is why they are gone:
//
//   * `_arm()` dropped the old connection without closing it;
//   * a retry chain (120/350/800 ms) re-showed the IME after the user had
//     already dismissed it -- it surfaced as "the keyboard pops back once";
//   * an AppLifecycleListener re-armed on resume, so coming back from the home
//     screen raised the keyboard where stock 1.1.0 does not.
//
// `show()` now does what upstream does: flush, close, open. What is left of the
// fork is the arrow-key handling above, and nothing else.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart' show TerminalKey;

/// Prefix for the diagnostic lines this file writes to logcat. Kept short and
/// greppable: `adb logcat -s flutter | grep modterm`.
///
/// These are load-bearing for a bug that only reproduces against a real IME on a
/// real device; there is no test that can see the platform's session state.
const String _tag = '[modterm]';

/// Opens the soft keyboard while [focusNode] has focus and [enabled], and turns
/// IME edits into terminal input.
class ModTerminalKeyboard extends StatefulWidget {
  const ModTerminalKeyboard({
    super.key,
    required this.focusNode,
    required this.enabled,
    required this.onText,
    required this.onBackspace,
    required this.onEnter,
    required this.onArrow,
    required this.onComposing,
    required this.child,
  });

  final FocusNode focusNode;
  final bool enabled;

  /// Committed text (Enter inside it already turned into [onEnter]).
  final ValueChanged<String> onText;
  final VoidCallback onBackspace;
  final VoidCallback onEnter;

  /// The IME moved its caret instead of editing text. Left/right on a terminal
  /// is the pty cursor, so the page turns this into `keyInput`.
  final ValueChanged<TerminalKey> onArrow;

  /// Text the IME is still composing (pinyin before a candidate is picked);
  /// null when nothing is pending.
  final ValueChanged<String?> onComposing;
  final Widget child;

  @override
  State<ModTerminalKeyboard> createState() => ModTerminalKeyboardState();
}

class ModTerminalKeyboardState extends State<ModTerminalKeyboard> with TextInputClient {
  /// Three spaces, caret in the middle: a slot to the left and a slot to the
  /// right. With the caret at the end (two spaces, offset 2) an IME "move right"
  /// is clamped and never reports anything.
  ///
  /// Kept as a separate constant because `_sentinel.text` is a property access
  /// and not usable in a constant expression.
  static const String _pad = '   ';
  static const TextEditingValue _sentinel = TextEditingValue(
    text: _pad,
    selection: TextSelection.collapsed(offset: 2),
  );

  /// Where [setEditingState] puts the caret back to after every edit.
  static const int _caretHome = 2;

  static const TextInputConfiguration _configuration = TextInputConfiguration(
    inputAction: TextInputAction.newline,
    keyboardAppearance: Brightness.dark,
    autocorrect: false,
    // Disabling suggestions sets Android's visible-password input type.
    enableSuggestions: true,
    enableIMEPersonalizedLearning: false,
    smartDashesType: SmartDashesType.disabled,
    smartQuotesType: SmartQuotesType.disabled,
  );

  TextInputConnection? _connection;
  TextEditingValue _value = _sentinel;

  /// Height of the IME as the system last reported it. Zero means no keyboard.
  double _inset = 0;

  /// The IME holds unfinished text: hardware-style key events must wait.
  bool get composing => _value.composing.isValid && !_value.composing.isCollapsed;

  bool get hasConnection => _connection?.attached ?? false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_sync);
  }

  @override
  void didUpdateWidget(ModTerminalKeyboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_sync);
      widget.focusNode.addListener(_sync);
    }
    if (oldWidget.enabled != widget.enabled) _sync();
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_sync);
    _close(tearDown: true);
    super.dispose();
  }

  /// Brings the keyboard back (a tap on the screen after it was dismissed).
  ///
  /// Closing the connection and opening a new one is NOT enough on its own --
  /// that is exactly what upstream does, and a tap still left the keyboard
  /// down. What the platform actually reacts to is a focus transition.
  ///
  /// The evidence is the two ways the keyboard does come back on this device:
  /// opening the overflow sheet and closing it, and renaming the session in a
  /// real text field. Both take the focus away from the terminal and give it
  /// back. Neither is a special IME call -- they are just a focus cycle. So a
  /// tap replays that cycle: close now, drop the focus, take it back on the
  /// next frame. `_sync` opens the new connection when the focus lands.
  ///
  /// The frame boundary matters: unfocusing and refocusing inside one callback
  /// is coalesced and behaves like a plain reopen, which is the thing that does
  /// not work.
  void show() {
    if (!widget.enabled) {
      debugPrint('$_tag show: ignored, disabled');
      return;
    }
    flushComposing();
    _close(tearDown: true);
    final focusNode = widget.focusNode;
    debugPrint('$_tag show: cycle, focus=${focusNode.hasFocus} inset=$_inset');
    if (focusNode.hasFocus) {
      focusNode.unfocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        debugPrint('$_tag show: refocus');
        focusNode.requestFocus();
      });
    } else {
      focusNode.requestFocus();
    }
  }

  TextInputConnection? _liveConnection() {
    final connection = _connection;
    return connection != null && connection.attached ? connection : null;
  }

  /// Sends what the IME is still composing as typed text and ends the
  /// composition, so a key from the key row lands after it (`git ch` + Tab).
  void flushComposing() {
    if (!composing) return;
    final text = _value.composing.textInside(_value.text);
    widget.onComposing(null);
    if (text.isNotEmpty) _emit(text);
    _reset();
  }

  void _sync() {
    if (widget.enabled && widget.focusNode.hasFocus) {
      // Focus that just came back means another text field very likely held the
      // client in between, so a fresh connection is opened rather than reused.
      _open();
    } else {
      _close(tearDown: false);
    }
  }

  /// Ends any old session, then attaches a brand-new connection and asks for
  /// the keyboard exactly once.
  ///
  /// No retry chain: re-showing after the user has dismissed the keyboard is
  /// what made it pop back up, and a request the platform ignores is not fixed
  /// by repeating it. If the keyboard does not appear, the session was never
  /// established -- closing and opening again is the only lever, and that is
  /// the caller's decision, not a timer's.
  void _open() {
    _close(tearDown: true);
    final connection = TextInput.attach(this, _configuration);
    _connection = connection;
    _value = _sentinel;
    connection.setEditingState(_sentinel);
    connection.show();
    debugPrint('$_tag open: attached, inset=$_inset');
  }

  void _close({required bool tearDown}) {
    final connection = _connection;
    _connection = null;
    if (composing) widget.onComposing(null);
    _value = _sentinel;
    // Only the owner of the client may close it. We still hold it when the
    // page is disposed, the tab stops accepting input, or we are about to open
    // a new connection (all `tearDown`) -- nothing else asked for it. We do not
    // hold it when the focus moved away, because whatever took the focus is
    // using it now, and closing it there would clear that field's client.
    if (tearDown && (connection?.attached ?? false)) connection!.close();
  }

  void _reset() {
    _value = _sentinel;
    _liveConnection()?.setEditingState(_sentinel);
  }

  // ── TextInputClient ──

  @override
  TextEditingValue? get currentTextEditingValue => _value;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    _value = value;
    if (composing) {
      widget.onComposing(value.composing.textInside(value.text));
      return;
    }
    widget.onComposing(null);

    // Lengths and offsets only: the terminal is where passwords get typed, so
    // the diagnostics must not carry the text itself.
    debugPrint(
      '$_tag edit: len=${value.text.length} sel=${value.selection.baseOffset} '
      'extent=${value.selection.extentOffset}',
    );

    final text = value.text;
    final (removed, inserted) = _diffAgainstSentinel(text);
    if (removed == 0 && inserted.isEmpty) {
      _followCaret(value.selection);
      return;
    }
    for (var i = 0; i < removed; i++) {
      widget.onBackspace();
    }
    if (inserted.isNotEmpty) _emit(inserted);
    _reset();
  }

  /// What the IME did to the sentinel, as (characters removed, text inserted).
  ///
  /// Both ends are measured. The caret no longer sits at the end of the
  /// sentinel, so an insertion can land in the middle: comparing only the
  /// common prefix reads `"  x "` against `"   "` as "one backspace, then
  /// insert `x `", which is the stray space plus phantom backspace that used to
  /// show up after a caret move.
  (int, String) _diffAgainstSentinel(String text) {
    const base = _pad;
    final limit = text.length < base.length ? text.length : base.length;

    var prefix = 0;
    while (prefix < limit && text.codeUnitAt(prefix) == base.codeUnitAt(prefix)) {
      prefix++;
    }
    var suffix = 0;
    final suffixLimit = limit - prefix;
    while (suffix < suffixLimit &&
        text.codeUnitAt(text.length - 1 - suffix) ==
            base.codeUnitAt(base.length - 1 - suffix)) {
      suffix++;
    }
    final removed = base.length - prefix - suffix;
    final inserted = text.substring(prefix, text.length - suffix);
    return (removed, inserted);
  }

  /// The IME moved its caret without editing text. The terminal has no caret to
  /// move -- the pty's cursor is what the arrows drive -- so the move becomes
  /// that many arrow keys, and the caret is put back where the diff expects it.
  void _followCaret(TextSelection selection) {
    if (!selection.isValid || !selection.isCollapsed) {
      _reset();
      return;
    }
    final delta = _caretHome - selection.baseOffset;
    if (delta == 0) return;
    // A jump bigger than the sentinel is not a caret move; ignore it rather
    // than spray arrow keys.
    if (delta.abs() > _sentinel.text.length) {
      _reset();
      return;
    }
    final key = delta > 0 ? TerminalKey.arrowLeft : TerminalKey.arrowRight;
    debugPrint('$_tag caret: delta=$delta -> ${delta > 0 ? 'left' : 'right'}');
    for (var i = 0; i < delta.abs(); i++) {
      widget.onArrow(key);
    }
    _reset();
  }

  /// Splits committed text at line breaks: each one is an Enter.
  void _emit(String text) {
    final lines = text.replaceAll('\r\n', '\n').split(RegExp('[\r\n]'));
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].isNotEmpty) widget.onText(lines[i]);
      if (i < lines.length - 1) widget.onEnter();
    }
  }

  @override
  void performAction(TextInputAction action) => widget.onEnter();

  @override
  void connectionClosed() {
    debugPrint('$_tag connectionClosed');
    _connection = null;
    if (composing) widget.onComposing(null);
    _value = _sentinel;
  }

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}

  @override
  void showToolbar() {}

  @override
  void didChangeInputControl(TextInputControl? oldControl, TextInputControl? newControl) {}

  @override
  void performSelector(String selectorName) {}

  @override
  void insertContent(KeyboardInsertedContent content) {}

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    if (inset != _inset) debugPrint('$_tag inset $_inset -> $inset');
    _inset = inset;
    return widget.child;
  }
}
