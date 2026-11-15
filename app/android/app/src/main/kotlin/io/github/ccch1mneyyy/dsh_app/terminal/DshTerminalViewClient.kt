package io.github.ccch1mneyyy.dsh_app.terminal

import android.util.Log
import android.view.KeyEvent
import android.view.MotionEvent
import com.termux.terminal.TerminalSession
import com.termux.view.TerminalViewClient

/**
 * [com.termux.view.TerminalView] 的 client。
 *
 * S1 只做「静态文字上屏」，所以这里没有任何键盘/手势语义：按键全部放行，缩放直接
 * 返回原值，[onEmulatorSet] 只留一行日志。真正灌字节的时机由平台视图掌握
 * （必须等第一次 `onSizeChanged` 之后，否则模拟器只有 4 列，内容会被折碎）。
 *
 * S2 接真实字节之后，这类"灌一次"的逻辑会换成 Dart 侧的流，本文件基本可以不动。
 */
internal class DshTerminalViewClient(
    private val session: TerminalSession,
) : TerminalViewClient {

    private val tag = "DshTerminalView"

    /** [TerminalView] 每次重新绑模拟器都会回调这里。 */
    override fun onEmulatorSet() {
        val emulator = session.getEmulator() ?: return
        Log.i(tag, "emulator set: ${emulator.mColumns}x${emulator.mRows}")
    }

    override fun onScale(scale: Float): Float = scale

    override fun onSingleTapUp(e: MotionEvent) = Unit

    override fun shouldBackButtonBeMappedToEscape(): Boolean = false

    override fun shouldEnforceCharBasedInput(): Boolean = false

    override fun shouldUseCtrlSpaceWorkaround(): Boolean = false

    override fun isTerminalViewSelected(): Boolean = true

    override fun copyModeChanged(copyMode: Boolean) = Unit

    override fun onKeyDown(keyCode: Int, e: KeyEvent, session: TerminalSession): Boolean = false

    override fun onKeyUp(keyCode: Int, e: KeyEvent): Boolean = false

    override fun onLongPress(event: MotionEvent): Boolean = false

    override fun readControlKey(): Boolean = false

    override fun readAltKey(): Boolean = false

    override fun readShiftKey(): Boolean = false

    override fun readFnKey(): Boolean = false

    override fun onCodePoint(codePoint: Int, ctrlDown: Boolean, session: TerminalSession): Boolean = false

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
