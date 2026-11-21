package io.github.ccch1mneyyy.dsh_app.terminal

import android.util.Log
import com.termux.terminal.TerminalSession
import com.termux.terminal.TerminalSessionClient

/**
 * Termux 模拟器要求的 client。它原本负责把会话事件转给 TermuxService，我们这里
 * 大多数回调都不存在对应物，只把日志接进 Logcat。
 *
 * 注意名字里的 `TerminalSession` 是 **com.termux.terminal.TerminalSession**，
 * 那是我们改写过的无 pty 版本（见 `src-termux/.../TerminalSession.java`）。
 */
internal class DshTerminalSessionClient(
    /** DECTCEM（`\e[?25l` / `\e[?25h`）的开关要转给视图：关光标时要停掉闪烁。 */
    private val onCursorStateChange: ((Boolean) -> Unit)? = null,
) : TerminalSessionClient {

    override fun onTextChanged(changedSession: TerminalSession) = Unit

    override fun onTitleChanged(changedSession: TerminalSession) = Unit

    override fun onSessionFinished(finishedSession: TerminalSession) = Unit

    override fun onCopyTextToClipboard(session: TerminalSession, text: String) = Unit

    override fun onPasteTextFromClipboard(session: TerminalSession?) = Unit

    override fun onBell(session: TerminalSession) = Unit

    override fun onColorsChanged(session: TerminalSession) = Unit

    override fun onTerminalCursorStateChange(state: Boolean) {
        onCursorStateChange?.invoke(state)
    }

    override fun setTerminalShellPid(session: TerminalSession, pid: Int) = Unit

    /** null 表示用视图自己的默认光标样式。 */
    override fun getTerminalCursorStyle(): Int? = null

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
