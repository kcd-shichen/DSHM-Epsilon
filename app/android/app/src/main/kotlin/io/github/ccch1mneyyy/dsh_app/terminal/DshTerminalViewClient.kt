package io.github.ccch1mneyyy.dsh_app.terminal

import android.content.Context
import android.util.Log
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.inputmethod.InputMethodManager
import com.termux.terminal.TerminalSession
import com.termux.view.TerminalView
import com.termux.view.TerminalViewClient

/**
 * [TerminalView] 的 client。
 *
 * 与上游 Termux 的差别只有一处：**点击时自己把输入法叫出来**。
 *
 * Termux 那边这一步在 `TerminalActivity` 里做（`showSoftInput`），`TerminalView` 自己
 * 只负责 `requestFocus()`。我们是平台视图，没有那个 Activity，所以必须在这里补上，
 * 否则输入法永远不会弹——这正是 S2 第一版的现象。
 *
 * 按键与手势语义仍全部放行：输入由这个 View 自己的 `InputConnection` 处理。
 */
internal class DshTerminalViewClient(
    private val session: TerminalSession,
    private val view: TerminalView,
) : TerminalViewClient {

    private val tag = "DshTerminalView"

    /**
     * S15：Ctrl / Alt 的粘滞状态由 Dart 那边的按键栏推送过来。
     *
     * 原生模式下输入法是唯一的字母来源，而 `TerminalView.inputCodePoint()` 只认
     * `mClient.readControlKey()`——它原来写死 false，所以 Ctrl-C 根本发不出去。
     */
    @Volatile
    private var ctrlDown = false

    @Volatile
    private var altDown = false

    fun setModifiers(ctrl: Boolean, alt: Boolean) {
        ctrlDown = ctrl
        altDown = alt
    }

    override fun onSingleTapUp(e: MotionEvent) {
        view.requestFocus()
        val imm = view.context.getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
        // 0 = 不挑来源，跟 Termux 里那句一致；SHOW_IMPLICIT 在某些 ROM 上会被忽略。
        // 失败只会安静返回 false，出问题时把返回值打出来即可。
        val shown = imm?.showSoftInput(view, 0) ?: false
        Log.i(tag, "showSoftInput -> $shown (focused=${view.isFocused()}, token=${view.windowToken != null})")
    }

    override fun onEmulatorSet() {
        val emulator = session.getEmulator() ?: return
        Log.i(tag, "emulator set: ${emulator.mColumns}x${emulator.mRows}")
    }

    override fun onScale(scale: Float): Float = scale

    override fun shouldBackButtonBeMappedToEscape(): Boolean = false

    override fun shouldEnforceCharBasedInput(): Boolean = false

    override fun shouldUseCtrlSpaceWorkaround(): Boolean = false

    override fun isTerminalViewSelected(): Boolean = true

    override fun copyModeChanged(copyMode: Boolean) = Unit

    override fun onKeyDown(keyCode: Int, e: KeyEvent, session: TerminalSession): Boolean = false

    override fun onKeyUp(keyCode: Int, e: KeyEvent): Boolean = false

    override fun onLongPress(event: MotionEvent): Boolean = false

    override fun readControlKey(): Boolean = ctrlDown

    override fun readAltKey(): Boolean = altDown

    override fun readShiftKey(): Boolean = false

    override fun readFnKey(): Boolean = false

    override fun onCodePoint(codePoint: Int, controlDown: Boolean, session: TerminalSession): Boolean = false

    override fun logError(tag: String, message: String) {
        Log.e(tag, message)
    }

    override fun logWarn(tag: String, message: String) {
        Log.w(tag, message)
    }

    override fun logInfo(tag: String, message: String) {
        Log.i(tag, message)
    }

    override fun logDebug(tag: String, message: String) {
        Log.d(tag, message)
    }

    override fun logVerbose(tag: String, message: String) {
        Log.v(tag, message)
    }

    override fun logStackTraceWithMessage(tag: String, message: String, e: Exception) {
        Log.e(tag, message, e)
    }

    override fun logStackTrace(tag: String, e: Exception) {
        Log.e(tag, null, e)
    }
}
