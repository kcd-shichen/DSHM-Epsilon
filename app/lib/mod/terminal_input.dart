// Fork-side replacement for `ui/terminal/terminal_keyboard.dart`.
//
// Why this exists
// ---------------
// Upstream's bridge keeps one TextInputConnection for the whole life of the
// terminal page and, when it is asked to bring the keyboard back, calls
// `show()` on it if the object still exists.
//
// `show()` cannot do that job. It asks the platform to raise the IME, and the
// platform will not raise an IME for a view whose input connection it has
// already dropped -- it ignores `showSoftInput` silently, no error, no
// callback. Android drops that connection when the IME is swiped away, when the
// window goes to the background, and when the input method itself restarts.
// None of those change anything on the Dart side, so the bridge keeps a
// connection object that looks perfectly usable and taps do nothing, forever.
//
// The only thing that reliably brings the keyboard back is a fresh
// `TextInput.attach`, which makes the platform build a new InputConnection and
// call `restartInput`. That is what the rename-dialog workaround does by
// accident: opening the dialog makes the terminal lose focus, upstream's
// `_close()` drops its connection, and closing the dialog makes `_open()` take
// the attach branch again.
//
// So this version does not call `show()` and hope. It asks whether the keyboard
// is on screen -- `MediaQuery.viewInsets` reports the IME height while it is
// up, so a zero inset is a direct observation, not an inference -- and rebuilds
// the connection whenever it is not.
//
// The second difference is the caret. Upstream returns early when the IME
// reports an unchanged text, which swallows caret moves and leaves the caret
// off the end of the sentinel; the next keystroke then diffs against a sentinel
// the caret no longer sits at and types the wrong thing (`x ` instead of `x`,
// plus a phantom backspace). Here a caret move of N places becomes N arrow keys
// sent to the terminal -- which is what left/right mean on a real terminal --
// and the caret is pinned back so the diff keeps meaning what it says.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart' show TerminalKey;

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
  static const _sentinel = TextEditingValue(text: '  ', selection: TextSelection.collapsed(offset: 2));

  static const _configuration = TextInputConfiguration(
    inputAction: TextInputAction.newline,
    keyboardAppearance: Brightness.dark,
    autocorrect: false,
    // Disabling suggestions sets Android's visible-password input type.
    enableSuggestions: true,
    enableIMEPersonalizedLearning: false,
    smartDashesType: SmartDashesType.disabled,
    smartQuotesType: SmartQuotesType.disabled,
  );

  /// A connection armed this recently is still known-good even if the inset has
  /// not caught up yet, so a double tap does not rebuild it twice.
  static const _armWindow = Duration(milliseconds: 400);

  TextInputConnection? _connection;
  TextEditingValue _value = _sentinel;
  DateTime? _armedAt;

  /// Height of the IME as the system last reported it. Zero means no keyboard.
  double _inset = 0;

  late final AppLifecycleListener _lifecycle;

  /// The IME holds unfinished text: hardware-style key events must wait.
  bool get composing => _value.composing.isValid && !_value.composing.isCollapsed;

  bool get hasConnection => _connection?.attached ?? false;

  bool get _keyboardOnScreen => _inset > 0;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_sync);
    // Coming back from the background is the other way the platform drops the
    // connection without telling us, and focus never changes, so _sync stays
    // quiet. Re-arm by hand.
    _lifecycle = AppLifecycleListener(onResume: _onResume);
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
    _lifecycle.dispose();
    widget.focusNode.removeListener(_sync);
    _close(tearDown: true);
    super.dispose();
  }

  /// Brings the keyboard back (a tap on the screen after it was dismissed).
  void show() {
    if (!widget.enabled) return;
    if (!widget.focusNode.hasFocus) widget.focusNode.requestFocus();
    final live = _liveConnection();
    if (live != null) {
      // Mid-composition the keyboard is obviously still there, and rebuilding
      // the connection would throw away the pinyin the user is in the middle
      // of. Same for a keyboard the system says is on screen.
      if (composing || _keyboardOnScreen) {
        live.show();
        return;
      }
      final armed = _armedAt;
      if (armed != null && DateTime.now().difference(armed) < _armWindow) {
        live.show();
        return;
      }
    }
    _arm();
  }

  TextInputConnection? _liveConnection() {
    final connection = _connection;
    return connection != null && connection.attached ? connection : null;
  }

  /// Rebuilds the connection without asking the page for focus first.
  void rearm() {
    if (!widget.enabled || !widget.focusNode.hasFocus) return;
    _arm();
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

  void _onResume() => rearm();

  void _sync() {
    if (widget.enabled && widget.focusNode.hasFocus) {
      // Focus that just came back means another text field very likely held the
      // client in between, so the connection is rebuilt rather than reused.
      _arm();
    } else {
      _close(tearDown: false);
    }
  }

  /// Attaches a brand-new connection, which is what makes the platform build a
  /// new InputConnection and restart input. This is the whole fix.
  void _arm() {
    // The old connection is dropped rather than close()d. A re-attach replaces
    // the platform-side client on its own, and on Flutter versions where
    // `attached` still means "close() was never called" rather than "this is
    // the current connection", calling close() on a connection some other text
    // field has since taken over would clear that field's client instead.
    _connection = null;
    final connection = TextInput.attach(this, _configuration);
    _connection = connection;
    _value = _sentinel;
    _armedAt = DateTime.now();
    connection
      ..show()
      ..setEditingState(_sentinel);
  }

  void _close({required bool tearDown}) {
    final connection = _connection;
    _connection = null;
    _armedAt = null;
    if (composing) widget.onComposing(null);
    _value = _sentinel;
    // Same reasoning as _arm(): only the owner of the client may close it. We
    // still hold it when the page is disposed or the tab stops accepting input
    // (tearDown), because nothing else asked for it. We do not hold it when the
    // focus moved away, because whatever took the focus is using it now.
    if (tearDown && (connection?.attached ?? false)) connection!.close();
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
    if (text == _sentinel.text) {
      _followCaret(value.selection);
      return;
    }
    final base = _sentinel.text;
    var common = 0;
    while (common < text.length && common < base.length && text.codeUnitAt(common) == base.codeUnitAt(common)) {
      common++;
    }
    for (var i = common; i < base.length; i++) {
      widget.onBackspace();
    }
    final inserted = text.substring(common);
    if (inserted.isNotEmpty) _emit(inserted);
    _reset();
  }

  /// The IME moved its caret without editing text. The terminal has no caret to
  /// move -- the pty's cursor is what the arrows drive -- so the move becomes
  /// that many arrow keys, and the caret is put back where the diff expects it.
  void _followCaret(TextSelection selection) {
    if (!selection.isValid || !selection.isCollapsed) {
      _reset();
      return;
    }
    final delta = _sentinel.selection.baseOffset - selection.baseOffset;
    if (delta == 0) return;
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
    _armedAt = null;
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
    _inset = MediaQuery.viewInsetsOf(context).bottom;
    return widget.child;
  }
}
