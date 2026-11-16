package io.github.ccch1mneyyy.dsh_app.terminal

import android.content.Context
import android.graphics.Color
import android.util.Base64
import android.util.Log
import android.view.View
import com.termux.terminal.TerminalSession
import com.termux.view.TerminalView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.ByteArrayOutputStream

/**
 * 把 Termux 的 [TerminalView] 挂成 Flutter 的 platform view，并接上字节通道。
 *
 * 一根管子两个方向，channel 名 `dsh/terminal/<tabId>`：
 *
 * ```
 * Dart → 原生   write   { data: base64(utf8) }   pty 输出，喂给模拟器
 * 原生 → Dart   input   { data: base64(utf8) }   用户按键，回给 pty
 * 原生 → Dart   resized { cols, rows }           视图量出的行列，宿主据此 resize pty
 * ```
 *
 * 四条硬约束，都是撞出来的：
 *
 * 1. `TerminalView` 是 `final class`，不能继承；"第一次布局"用
 *    [View.addOnLayoutChangeListener] 等。
 * 2. 布局之前 `updateSize()` 空转，模拟器还不存在。此时到达的字节必须**排队**，
 *    否则首次进终端只显示半屏。
 * 3. 行列由原生自己算（它知道自己的字号与像素宽高），算完要**回告**宿主，
 *    远端 pty 才会跟着 resize。
 * 4. 输入法由这个 View 自己的 `InputConnection` 承担，Flutter 侧不持有
 *    `TextInputClient` —— 这就是 ④ 那条 bug 的根治点。
 */
class TerminalPlatformView(
    context: Context,
    messenger: BinaryMessenger,
    @Suppress("UNUSED_PARAMETER") viewId: Int,
    args: Any?,
) : PlatformView {

    private val tag = "DshTerminal"

    private val id: String = (args as? Map<*, *>)?.get("id") as? String ?: ""
    private val channel = MethodChannel(messenger, "dsh/terminal/$id")

    private lateinit var view: TerminalView
    private val session: TerminalSession

    /** 布局之前到达的字节先攒在这里。 */
    private val inbox = ByteArrayOutputStream()

    private var lastCols = 0
    private var lastRows = 0

    init {
        val sessionClient = DshTerminalSessionClient()

        val bridge = object : TerminalSession.Client {
            override fun onInput(data: ByteArray, offset: Int, count: Int) {
                val slice = if (offset == 0 && count == data.size) {
                    data
                } else {
                    data.copyOfRange(offset, offset + count)
                }
                channel.invokeMethod("input", mapOf("data" to Base64.encodeToString(slice, Base64.NO_WRAP)))
            }

            override fun onScreenUpdate() {
                if (::view.isInitialized) view.post { view.invalidate() }
            }

            override fun onTitleChanged(oldTitle: String?, newTitle: String?) {
                channel.invokeMethod("title", mapOf("title" to (newTitle ?: "")))
            }

            override fun onBell() = Unit

            override fun onCopyTextToClipboard(text: String?) = Unit

            override fun onPasteTextFromClipboard() = Unit
        }

        view = TerminalView(context, null)
        // TerminalView 自己没有 setFocusable：它平时跑在 Termux 的 Activity 里，
        // 焦点由那边给。这里必须自己开，否则 requestFocus() 直接失败，输入法挂不上。
        view.isFocusable = true
        view.isFocusableInTouchMode = true

        session = TerminalSession(null, bridge, sessionClient)
        view.setTerminalViewClient(DshTerminalViewClient(session, view))
        view.attachSession(session)
        view.setTextSize(TEXT_SIZE_DIP)
        view.setBackgroundColor(Color.BLACK)

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "write" -> {
                    val encoded = (call.arguments as? Map<*, *>)?.get("data") as? String
                    if (encoded == null) {
                        result.error("bad_args", "write 缺少 data", null)
                        return@setMethodCallHandler
                    }
                    deliver(Base64.decode(encoded, Base64.DEFAULT))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        view.addOnLayoutChangeListener { v, left, top, right, bottom, _, _, _, _ ->
            if (right - left <= 0 || bottom - top <= 0) return@addOnLayoutChangeListener
            // 第一次拿到非零尺寸时把排队的字节倒进去（此时模拟器才存在）。
            deliver(ByteArray(0))
            reportSize()
        }
    }

    override fun getView(): View = view

    override fun dispose() {
        channel.setMethodCallHandler(null)
    }

    /** 模拟器还没建就排队，建好之后先倒完队再喂新的。 */
    private fun deliver(bytes: ByteArray) {
        if (session.getEmulator() == null) {
            inbox.write(bytes, 0, bytes.size)
            return
        }
        if (inbox.size() > 0) {
            val queued = inbox.toByteArray()
            inbox.reset()
            session.feed(queued, 0, queued.size)
        }
        if (bytes.isNotEmpty()) session.feed(bytes, 0, bytes.size)
    }

    /** 行列变了才回告，避免每次布局都发一遍。 */
    private fun reportSize() {
        val emulator = session.getEmulator() ?: return
        if (emulator.mColumns == lastCols && emulator.mRows == lastRows) return
        lastCols = emulator.mColumns
        lastRows = emulator.mRows
        Log.i(tag, "size ${lastCols}x$lastRows")
        channel.invokeMethod("resized", mapOf("cols" to lastCols, "rows" to lastRows))
    }

    companion object {
        const val VIEW_TYPE = "dsh/terminal"

        private const val TEXT_SIZE_DIP = 14
    }
}

/**
 * 注册入口用的工厂。Flutter 侧 `AndroidView(viewType: 'dsh/terminal')` 会走到 [create]，
 * `creationParams` 里的 `id` 决定 channel 名。
 */
class TerminalPlatformViewFactory(
    private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context?, viewId: Int, args: Any?): PlatformView =
        TerminalPlatformView(context ?: error("platform view 需要非空 context"), messenger, viewId, args)
}
