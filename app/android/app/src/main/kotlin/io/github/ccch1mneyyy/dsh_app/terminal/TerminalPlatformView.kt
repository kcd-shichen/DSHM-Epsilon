package io.github.ccch1mneyyy.dsh_app.terminal

import android.content.Context
import android.graphics.Color
import android.view.View
import com.termux.terminal.TerminalSession
import com.termux.view.TerminalView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * S1 探针：把 Termux 的 [TerminalView] 直接挂成 Flutter 的 platform view。
 *
 * 这一版**不通 Dart**，没有任何 channel。视图第一次量好尺寸后灌一段固定的 ANSI 样例，
 * 用来看三件事：能不能编、能不能注册、能不能上屏（含 CJK 与颜色）。
 *
 * S2 才接 `MethodChannel` / 事件流，把 pty 的字节接进来。
 *
 * 两个来自上游的约束，别试图绕：
 * - `TerminalView` 是 `final class`，**不能继承**。所以"第一次布局"用
 *   [View.addOnLayoutChangeListener] 等，而不是重写 `onSizeChanged`。
 * - 必须等第一次非零布局之后才灌字节：在那之前 `TerminalView.updateSize()` 是空转，
 *   模拟器还没建；先灌会被 4 列的占位模拟器折碎。
 */
class TerminalPlatformView(
    context: Context,
    @Suppress("UNUSED_PARAMETER") messenger: BinaryMessenger?,
    @Suppress("UNUSED_PARAMETER") viewId: Int,
    @Suppress("UNUSED_PARAMETER") args: Any?,
) : PlatformView {

    private lateinit var view: TerminalView
    private val session: TerminalSession
    private var fed = false

    init {
        val sessionClient = DshTerminalSessionClient()
        // 输入方向：S1 没有 pty，按键直接丢弃；输出方向：交给视图重绘。
        val bridge = object : TerminalSession.Client {
            override fun onInput(data: ByteArray, offset: Int, count: Int) = Unit

            override fun onScreenUpdate() {
                if (::view.isInitialized) view.post { view.invalidate() }
            }

            override fun onTitleChanged(oldTitle: String?, newTitle: String?) = Unit

            override fun onBell() = Unit

            override fun onCopyTextToClipboard(text: String?) = Unit

            override fun onPasteTextFromClipboard() = Unit
        }

        session = TerminalSession(null, bridge, sessionClient)

        view = TerminalView(context, null)
        view.setTerminalViewClient(DshTerminalViewClient(session))
        view.attachSession(session)
        view.setTextSize(TEXT_SIZE_DIP)
        view.setBackgroundColor(Color.BLACK)

        view.addOnLayoutChangeListener { v, left, top, right, bottom, _, _, _, _ ->
            if (fed || right - left <= 0 || bottom - top <= 0) return@addOnLayoutChangeListener
            fed = true
            v.post { session.feed(SAMPLE) }
        }
    }

    override fun getView(): View = view

    override fun dispose() = Unit

    companion object {
        const val VIEW_TYPE = "dsh/terminal"

        private const val TEXT_SIZE_DIP = 14

        /**
         * 探针内容。故意混了四类东西：ANSI 颜色、真彩色、CJK 宽度、框线字符。
         * 只要这四样有一项错位，屏幕上一眼就能看出来。
         */
        private val SAMPLE = buildString {
            append("\u001b[2J\u001b[H")
            append("\u001b[1;32mDSH ε · native terminal probe\u001b[0m\r\n")
            append("\u001b[36mTermux TerminalView\u001b[0m \u001b[90m—\u001b[0m ")
            append("com.termux.terminal + com.termux.view\r\n")
            append("\r\n")
            append("\u001b[33mS1\u001b[0m 静态文字上屏: 字符 / 颜色 / 宽度 / 中文\r\n")
            append("\r\n")
            append("    列 0         1         2         3\r\n")
            append("    0123456789012345678901234567890123456789\r\n")
            append("    ┌─────────┬─────────┐\r\n")
            append("    │ 宽度测试 │ W i d t h │\r\n")
            append("    └─────────┴─────────┘\r\n")
            append("\r\n")
            append("    正常  \u001b[1m粗体\u001b[0m  \u001b[4m下划线\u001b[0m  ")
            append("\u001b[7m反显\u001b[0m  \u001b[38;2;255;136;0m真彩色\u001b[0m\r\n")
            append("\r\n")
            append("\u001b[42;30m 背景色块 \u001b[0m ")
            append("\u001b[41;97m 警告 \u001b[0m ")
            append("\u001b[44;97m 信息 \u001b[0m\r\n")
            append("\r\n")
            append("\u001b[90m这一行是灰色注释，用来对比对比度。\u001b[0m\r\n")
            append("\u001b[32m❯\u001b[0m 光标应该停在这里右边\r\n")
        }
    }
}

/**
 * 注册入口用的工厂。Flutter 侧 `AndroidView(viewType: 'dsh/terminal')` 会走到 `create`。
 */
class TerminalPlatformViewFactory(
    private val messenger: BinaryMessenger?,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context?, viewId: Int, args: Any?): PlatformView =
        TerminalPlatformView(context ?: error("platform view 需要非空 context"), messenger, viewId, args)
}
