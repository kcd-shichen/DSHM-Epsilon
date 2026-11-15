// Fork-side replacement for `ui/terminal/terminal_keyboard.dart`.
//
// Why this exists
// ---------------
// Upstream's bridge keeps one TextInputConnection for the whole life of the
// terminal page and, when asked to bring the keyboard back, calls `show()` on
// it. Two things are wrong with that, and they are separate bugs.
//
// 1. The keyboard does not come back.
//
// `show()` asks the platform to raise the IME. Android will not raise an IME for
// a view whose input session it has already torn down -- it ignores the request
// with no error and no callback. Hiding the keyboard from the IME's own button
// ends the session (`onFinishInput`, `requestHideSelf`), and nothing changes on
// the Dart side, so the bridge keeps a connection object that looks usable and
// taps do nothing, forever.
//
// A logcat capture of a real device (Sogou IME, MIUI, 2026-11-15) showed the
// platform accepting a `showCurrentInputLocked` sometimes and ignoring it other
// times, with a `startInputUncheckedLocked` (a fresh input session) landing
// several hundred milliseconds *after* the ignored request. So rebuilding the
// connection is necessary but not sufficient: the `show()` that rides on it can
// still arrive before the platform has a live session. This version therefore
// retries the show a few times, at increasing delays, and stops as soon as the
// IME height reports itself non-zero.
//
// 2. The IME's right-arrow key did nothing.
//
// Upstream returns early whenever the IME reports unchanged text, so a caret
// move produces no event at all. Worse, the sentinel it keeps is two spaces with
// the caret at offset 2 -- the end of the text. A caret cannot move right from
// the end, so the IME's `→` was clamped back to 2 and produced no event even in
// principle. `←` worked only because there was one slot to its left, which is
// why the two directions behaved differently.
//
// Here the sentinel is three spaces with the caret at 2: one slot left, one
// slot right, both directions reachable. A caret move of N places becomes N
// arrow keys -- which is what left/right mean on a real terminal, since the pty
// cursor is the only cursor there is -- and the caret is put back so the next
// diff still means what it says.
//
// Because the caret is no longer pinned to the end, the text diff is measured
// from both ends, not just the common prefix. See `_diffAgainstSentinel`.

import 'dart:async';

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

  /// Delays before re-asking the platform to show the IME after a rebuild. The
  /// first request usually lands before the new input session exists; the later
  /// ones catch it once it does. Any attempt stops the chain as soon as the IME
  /// has height.
  static const List<Duration> _showRetries = <Duration>[
    Duration(milliseconds: 120),
    Duration(milliseconds: 350),
    Duration(milliseconds: 800),
  ];

  TextInputConnection? _connection;
  TextEditingValue _value = _sentinel;
  Timer? _showTimer;
  int _showAttempt = 0;

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
    // Coming back from the background is another way the platform drops the
    // session without telling us, and focus never changes, so _sync stays
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
    _cancelShowRetries();
    _lifecycle.dispose();
    widget.focusNode.removeListener(_sync);
    _close(tearDown: true);
    super.dispose();
  }

  /// Brings the keyboard back (a tap on the screen after it was dismissed).
  void show() {
    if (!widget.enabled) {
      debugPrint('$_tag show: ignored, disabled');
      return;
    }
    if (!widget.focusNode.hasFocus) {
      // _sync arms the connection once focus actually arrives, so arming here
      // too would attach twice.
      debugPrint('$_tag show: no focus, requesting');
      widget.focusNode.requestFocus();
      return;
    }
    final live = _liveConnection();
    debugPrint('$_tag show: live=${live != null} composing=$composing inset=$_inset');
    if (live != null && (composing || _keyboardOnScreen)) {
      live.show();
      return;
    }
    _arm('show');
  }

  TextInputConnection? _liveConnection() {
    final connection = _connection;
    return connection != null && connection.attached ? connection : null;
  }

  /// Rebuilds the connection without asking the page for focus first.
  void rearm() {
    if (!widget.enabled || !widget.focusNode.hasFocus) return;
    _arm('rearm');
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

  void _onResume() {
    debugPrint('$_tag lifecycle resume');
    rearm();
  }

  void _sync() {
    if (widget.enabled && widget.focusNode.hasFocus) {
      // Focus that just came back means another text field very likely held the
      // client in between, so the connection is rebuilt rather than reused.
      _arm('focus');
    } else {
      _close(tearDown: false);
    }
  }

  /// Attaches a brand-new connection, which is what makes the platform build a
  /// new input session. Then asks for the keyboard, and keeps asking until the
  /// IME reports height.
  void _arm(String why) {
    _cancelShowRetries();
    // The old connection is dropped rather than close()d. A re-attach replaces
    // the platform-side client on its own, and on Flutter versions where
    // `attached` still means "close() was never called" rather than "this is the
    // current connection", calling close() on a connection some other text field
    // has since taken over would clear that field's client instead.
    _connection = null;
    final connection = TextInput.attach(this, _configuration);
    _connection = connection;
    _value = _sentinel;
    connection.setEditingState(_sentinel);
    // First attempt right away: when the session is still healthy this is all
    // it takes.
    connection.show();
    _showAttempt = 0;
    debugPrint('$_tag arm($why): attached, inset=$_inset');
    _scheduleShowRetry();
  }

  void _scheduleShowRetry() {
    if (_showAttempt >= _showRetries.length) return;
    final delay = _showRetries[_showAttempt++];
    _showTimer?.cancel();
    _showTimer = Timer(delay, () {
      if (!mounted) return;
      final connection = _liveConnection();
      if (connection == null) {
        debugPrint('$_tag retry$_showAttempt: no live connection, stop');
        return;
      }
      if (_inset > 0) {
        debugPrint('$_tag retry$_showAttempt: keyboard is up, stop');
        return;
      }
      debugPrint('$_tag retry$_showAttempt: show again');
      connection.show();
      _scheduleShowRetry();
    });
  }

  void _cancelShowRetries() {
    _showTimer?.cancel();
    _showTimer = null;
    _showAttempt = 0;
  }

  void _close({required bool tearDown}) {
    _cancelShowRetries();
    final connection = _connection;
    _connection = null;
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
    _cancelShowRetries();
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
