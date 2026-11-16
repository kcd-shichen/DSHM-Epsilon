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

    /**
     * T22 探针（临时）：把布局与投递的现场落到 `files/layout_probe.log`。
     *
     * 要回答的只有一个问题——**终端是"没内容"还是"被盖住了"**：
     * 尺寸、窗口令牌、模拟器有没有建出来、inbox 里堆了多少字节。
     * 定位完连同下面几处 probe() 一起删掉。
     */
    private val appContext: Context = context.applicationContext
    private var probeLines = 0

    private val id: String = (args as? Map<*, *>)?.get("id") as? String ?: ""
    private val channel = MethodChannel(messenger, "dsh/terminal/$id")

    private lateinit var view: TerminalView
    private lateinit var client: DshTerminalViewClient
    private val session: TerminalSession

    /** 布局之前到达的字节先攒在这里。 */
    private val inbox = ByteArrayOutputStream()

    private var lastCols = 0
    private var lastRows = 0

    /** T22：遮罩参数（dp），什么时候真画由 files/veil_on 决定。 */
    private var veilSolidDp = 0f
    private var veilFeatherDp = 0f
    private var screenUpdates = 0
    private var deliverLogs = 0

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
                if (::view.isInitialized) {
                    if (screenUpdates < 4) {
                        screenUpdates++
                        probe("onScreenUpdate #$screenUpdates")
                    }
                    view.post { view.invalidate() }
                }
            }

            override fun onTitleChanged(oldTitle: String?, newTitle: String?) {
                channel.invokeMethod("title", mapOf("title" to (newTitle ?: "")))
            }

            override fun onBell() = Unit

            // T16：选择模式里的「复制 / 粘贴」原来走这两个空回调，等于按了没反应。
            override fun onCopyTextToClipboard(text: String?) {
                channel.invokeMethod("copy", mapOf("text" to (text ?: "")))
            }

            override fun onPasteTextFromClipboard() {
                channel.invokeMethod("paste", null)
            }
        }

        view = TerminalView(context, null)
        // TerminalView 自己没有 setFocusable：它平时跑在 Termux 的 Activity 里，
        // 焦点由那边给。这里必须自己开，否则 requestFocus() 直接失败，输入法挂不上。
        view.isFocusable = true
        view.isFocusableInTouchMode = true
        // S2g 实验开关：files/ime_anchor_off 存在时关掉锚点编辑区（§7.18）。
        // 由我这边建/删这个文件来切换，不需要重新装包。
        // 轨迹默认关；要取证时我这边建一个 ime_trace_on 就打开（见 TerminalView.traceIme）。
        val traceOn = java.io.File(context.filesDir, "ime_trace_on").exists()
        view.setImeTraceEnabled(traceOn)
        if (traceOn) runCatching {
            java.io.File(context.filesDir, "ime_trace.txt").writeText("")
        }

        session = TerminalSession(null, bridge, sessionClient)
        client = DshTerminalViewClient(session, view)
        view.setTerminalViewClient(client)
        view.attachSession(session)
        view.setTextSize(TEXT_SIZE_DIP)
        view.setBackgroundColor(Color.BLACK)

        // 探针文件每个进程清一次，免得上一版的旧行混进来。
        if (!probeFresh) {
            probeFresh = true
            runCatching { java.io.File(context.filesDir, "layout_probe.log").writeText("") }
        }
        // 有内容到底有没有被画出来：onDraw 被调到 = 画了（那黑就是被 Flutter 盖住）。
        var draws = 0
        view.setDrawProbe {
            if (draws < 6) {
                draws++
                probe("onDraw #$draws ${view.width}x${view.height}")
            }
        }

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
                // T16b：粘贴走 Termux 自己的 emulator.paste()。
                // 它在写进 pty 之前会剥掉 ESC / C1 控制字符，把 \n 规整成 \r，
                // 并且在 DECSET 2004（bracketed paste）打开时套上 \e[200~ … \e[201~。
                // bash 5.1+ 默认就开着 2004，于是多行粘贴只进编辑缓冲区、不会逐行执行。
                "pasteText" -> {
                    val text = (call.arguments as? Map<*, *>)?.get("text") as? String
                    if (text == null || text.isEmpty()) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    val emulator = session.getEmulator()
                    if (emulator == null) {
                        // 还没布局出模拟器时没有 bracketed 语义可言，退化成直接写。
                        session.write(text)
                    } else {
                        emulator.paste(text)
                    }
                    result.success(null)
                }
                // T22：顶部遮罩。参数是 dp；遮罩本身画在 TerminalView 的 onDraw 里。
                "veil" -> {
                    val args = call.arguments as? Map<*, *>
                    veilSolidDp = (args?.get("solid") as? Number)?.toFloat() ?: 0f
                    veilFeatherDp = (args?.get("feather") as? Number)?.toFloat() ?: 0f
                    applyVeil()
                    probe("veil dp=$veilSolidDp/$veilFeatherDp on=${veilOn()}")
                    result.success(null)
                }
                // S15：按键栏的 Ctrl / Alt 粘滞状态，见 DshTerminalViewClient.setModifiers。
                "modifiers" -> {
                    val args = call.arguments as? Map<*, *>
                    client.setModifiers(
                        ctrl = args?.get("ctrl") as? Boolean ?: false,
                        alt = args?.get("alt") as? Boolean ?: false,
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        view.addOnLayoutChangeListener { v, left, top, right, bottom, _, _, _, _ ->
            probe(
                "layout ${right - left}x${bottom - top}@($left,$top) " +
                    "view=${view.width}x${view.height} attached=${view.isAttachedToWindow} " +
                    "token=${view.windowToken != null} emulator=${session.getEmulator() != null} " +
                    "inbox=${inbox.size()}",
            )
            if (right - left <= 0 || bottom - top <= 0) return@addOnLayoutChangeListener
            applyVeil()
            // T22：不指望 `onSizeChanged` 一定被调到。换成 Stack 之后它是没被调到的
            // （模拟器永远不建，输出全堆在 inbox 里 → 满屏黑、无字、打字有去无回）。
            // `updateSize()` 是 public 的，自己在布局回调里叫一次最稳：行列没变时它自己会跳过。
            view.updateSize()
            probe("afterUpdateSize emulator=${session.getEmulator() != null} inbox=${inbox.size()}")
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
            probe("deliver: emulator=null inbox=${inbox.size()}（+${bytes.size} 字节排队）")
            return
        }
        if (inbox.size() > 0) {
            val queued = inbox.toByteArray()
            inbox.reset()
            session.feed(queued, 0, queued.size)
        }
        if (bytes.isNotEmpty()) {
            if (deliverLogs < 5) {
                deliverLogs++
                probe("deliver ${bytes.size} bytes")
            }
            session.feed(bytes, 0, bytes.size)
        }
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

    /**
     * T22：`files/veil_on` 存在才真画遮罩。
     *
     * 一个包两个状态——建/删这个文件就能切换，不用为"到底是遮罩还是别的东西"
     * 再出一版。布局变化时也会重读，所以中途切换只要让页面重新布局一次。
     */
    private fun veilOn(): Boolean = java.io.File(appContext.filesDir, "veil_on").exists()

    private fun applyVeil() {
        val density = appContext.resources.displayMetrics.density
        val on = veilOn()
        view.setTopVeil(
            if (on) (veilSolidDp * density).toInt() else 0,
            if (on) (veilFeatherDp * density).toInt() else 0,
        )
    }

    private fun probe(message: String) {
        if (probeLines > 400) return
        probeLines++
        runCatching {
            java.io.File(appContext.filesDir, "layout_probe.log")
                .appendText("${System.currentTimeMillis()} $message\n")
        }
    }

    companion object {
        const val VIEW_TYPE = "dsh/terminal"

        private const val TEXT_SIZE_DIP = 14

        /** 探针文件是否已经在本进程里清过。 */
        private var probeFresh = false
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
