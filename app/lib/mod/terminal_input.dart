// Fork-side copy of `ui/terminal/terminal_keyboard.dart`.
//
// This file is upstream's bridge, byte for byte, with ONE addition: the IME's
// left/right keys drive the terminal cursor.
//
// Upstream has no path for that at all. Its sentinel is two spaces with the
// caret at offset 2 -- the end of the text. A caret cannot move right from the
// end, so `arrow right` is clamped back and reports nothing; and when a caret
// move does produce a value, upstream returns early because the text did not
// change. `arrow left` only appeared to work: some IMEs report a shorter text
// alongside the move, which a prefix-only diff reads as one backspace. That is
// why "left works, right does not" looked like a half-broken feature.
//
// The two changes that fix it:
//
//   * the sentinel is three spaces with the caret at 2 -- one slot left, one
//     slot right;
//   * a value whose text did not change is treated as a caret move and turned
//     into that many arrow keys (the pty cursor is what arrows drive).
//
// Because the caret is no longer pinned to the end, the diff is measured from
// both ends; comparing only the prefix reads `"  x "` against `"   "` as "one
// backspace, then insert `x `".
//
// Everything about the IME session -- `show()`, `_open()`, `_close()`, the
// focus sync, the sentinel lifecycle -- is upstream's, unchanged. Earlier
// revisions of this file deviated there (a retry chain, a lifecycle listener,
// dropping the connection without closing it) and every one of those made the
// "keyboard never comes back" bug worse. They are gone; do not bring them back
// without a device test that says otherwise.
//
// Keep this file in step with upstream: it is a copy, so a change on their side
// does not arrive on its own.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart' show TerminalKey;

/// Opens the soft keyboard while [focusNode] has focus and [enabled], and
/// turns IME edits into terminal input.
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
  /// right. With the caret at the end (upstream's two spaces, offset 2) an IME
  /// "move right" is clamped and never reports anything.
  ///
  /// The text is a separate constant because `_sentinel.text` is a property
  /// access and not usable in a constant expression.
  static const String _pad = '   ';
  static const TextEditingValue _sentinel = TextEditingValue(
    text: _pad,
    selection: TextSelection.collapsed(offset: 2),
  );

  /// Where [setEditingState] puts the caret back to after every edit.
  static const int _caretHome = 2;

  TextInputConnection? _connection;
  TextEditingValue _value = _sentinel;

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
    _close();
    super.dispose();
  }

  /// Brings the keyboard back (a tap on the screen after it was dismissed).
  /// On a fresh connection: some IMEs ignore show() once Back has hidden them
  /// (iFlytek on HyperOS, #1277), and a new attach is what brings them back,
  /// as leaving the page does. Attaching in the same frame keeps an open
  /// keyboard up.
  void show() {
    if (!widget.enabled) return;
    flushComposing();
    _close();
    if (!widget.focusNode.hasFocus) {
      widget.focusNode.requestFocus();
      return;
    }
    _open();
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
      _open();
    } else {
      _close();
    }
  }

  void _open() {
    final existing = _connection;
    if (existing != null && existing.attached) {
      existing.show();
      return;
    }
    final connection = TextInput.attach(
      this,
      const TextInputConfiguration(
        inputAction: TextInputAction.newline,
        keyboardAppearance: Brightness.dark,
        autocorrect: false,
        // Disabling suggestions sets Android's visible-password input type.
        enableSuggestions: true,
        enableIMEPersonalizedLearning: false,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
      ),
    );
    _connection = connection;
    _value = _sentinel;
    connection
      ..show()
      ..setEditingState(_sentinel);
  }

  void _close() {
    final connection = _connection;
    _connection = null;
    if (connection != null && connection.attached) connection.close();
    if (composing) widget.onComposing(null);
    _value = _sentinel;
  }

  void _reset() {
    _value = _sentinel;
    _connection?.setEditingState(_sentinel);
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
  Widget build(BuildContext context) => widget.child;
}
