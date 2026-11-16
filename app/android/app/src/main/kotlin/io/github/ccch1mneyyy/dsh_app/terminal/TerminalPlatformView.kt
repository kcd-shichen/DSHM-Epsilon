package io.github.ccch1mneyyy.dsh_app.terminal

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
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

    private val appContext: Context = context.applicationContext

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
    /** 当前字号（dp），由 `style` 通道下发。 */
    private var fontDp = 14f

    /** 上一次下发的遮罩参数；没变就不重设（键盘动画期间这点很关键）。 */
    private var veilSolidPx = -1
    private var veilFeatherPx = -1

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
                // T17：外观三件套 + 顶部渐隐，一次到位。
                // 字号 / 调色板 / 字体族原来在原生分支全都不生效，值从 Dart 下发。
                "style" -> {
                    val args = call.arguments as? Map<*, *>
                    val fontSize = (args?.get("fontSize") as? Number)?.toFloat() ?: TEXT_SIZE_DIP.toFloat()
                    val bg = (args?.get("background") as? Number)?.toInt()
                    val fg = (args?.get("foreground") as? Number)?.toInt()
                    val cursor = (args?.get("cursor") as? Number)?.toInt()
                    veilSolidDp = (args?.get("veilSolid") as? Number)?.toFloat() ?: 0f
                    veilFeatherDp = (args?.get("veilFeather") as? Number)?.toFloat() ?: 0f
                    fontDp = fontSize
                    view.setTextSize(fontSize.toInt())
                    view.setTypeface(monoTypeface())
                    if (bg != null && fg != null) view.setPalette(bg, fg, cursor ?: fg)
                    applyVeil()
                    result.success(null)
                }
                // T22：顶部遮罩。参数是 dp；遮罩本身画在 TerminalView 的 onDraw 里。
                "veil" -> {
                    val args = call.arguments as? Map<*, *>
                    veilSolidDp = (args?.get("solid") as? Number)?.toFloat() ?: 0f
                    veilFeatherDp = (args?.get("feather") as? Number)?.toFloat() ?: 0f
                    applyVeil()
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

        // 布局回调是**热路径**：输入法升起的那 200–300ms 里每帧都会进来。
        // 这里只做两件便宜事——遮罩参数变了才重设，尺寸变化**防抖**后再生效。
        // 之前每帧 updateSize() + invalidate() 就是键盘动画掉帧的来源。
        var layoutTick = 0
        view.addOnLayoutChangeListener { v, left, top, right, bottom, _, _, _, _ ->
            if (right - left <= 0 || bottom - top <= 0) return@addOnLayoutChangeListener
            applyVeil()
            layoutTick++
            val myTick = layoutTick
            view.postDelayed({
                if (myTick != layoutTick) return@postDelayed   // 后面还有更新的布局，等它
                if (view.width <= 0 || view.height <= 0) return@postDelayed
                // 不指望 onSizeChanged 一定被调到；行列没变时 updateSize 自己会跳过。
                view.updateSize()
                // 模拟器建好之后把排队的字节倒进去。
                deliver(ByteArray(0))
                reportSize()
            }, LAYOUT_SETTLE_MS)
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

    /**
     * T22：`files/veil_on` 存在才真画遮罩。
     *
     * 一个包两个状态——建/删这个文件就能切换，不用为"到底是遮罩还是别的东西"
     * 再出一版。布局变化时也会重读，所以中途切换只要让页面重新布局一次。
     */
    private fun veilOn(): Boolean = !java.io.File(appContext.filesDir, "veil_off").exists()

    /** 只在参数真的变了才 setTopVeil——它内部会 invalidate，等于一次全屏重绘。 */
    private fun applyVeil() {
        val density = appContext.resources.displayMetrics.density
        val on = veilOn()
        val solid = if (on) (veilSolidDp * density).toInt() else 0
        val feather = if (on) (veilFeatherDp * density).toInt() else 0
        if (solid == veilSolidPx && feather == veilFeatherPx) return
        veilSolidPx = solid
        veilFeatherPx = feather
        view.setTopVeil(solid, feather)
    }

    /** 字体的 ttf 在 APK 的 flutter_assets 里（pubspec 的 JetBrainsMono），原生能直接加载。 */
    private fun monoTypeface(): Typeface = runCatching {
        Typeface.createFromAsset(appContext.assets, "flutter_assets/assets/fonts/JetBrainsMono-Regular.ttf")
    }.getOrElse { Typeface.MONOSPACE }

    companion object {
        const val VIEW_TYPE = "dsh/terminal"

        private const val TEXT_SIZE_DIP = 14

        /** 布局停稳多久之后才认尺寸（键盘动画期间会被反复刷到 0）。 */
        private const val LAYOUT_SETTLE_MS = 120L

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
