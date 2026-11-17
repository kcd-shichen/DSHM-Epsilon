package io.github.ccch1mneyyy.dsh_app.terminal

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.util.Base64
import android.util.Log
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.widget.PopupWindow
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

    /** 文字两侧留白（dp）。终端仍然铺满，只是行往里缩。 */
    private var sideInset = 10f

    /** 终端视图外面那层：上面是 TerminalView，下面是原生键栏（Termux 那套做法）。 */
    private lateinit var container: android.widget.LinearLayout
    private var ctrlOn = false
    private var altOn = false

    /** 长按锁：锁住之后这个修饰键不再被下一次按键用掉（Termux 的 SpecialButtonState）。 */
    private var ctrlLocked = false
    private var altLocked = false
    private lateinit var ctrlKey: android.widget.TextView
    private lateinit var altKey: android.widget.TextView

    /** 长按重复 / 长按锁的调度器；同一时刻只允许一个（Termux 也是这么做的）。 */
    private val holdHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private var holdTask: Runnable? = null

    /** 这次按住已经触发过几次（重复键每发一次 +1）；>0 时抬手不再补发。 */
    private var holdCount = 0

    /** 上滑弹出的放大键（Termux 的 PopupWindow）。 */
    private var popupWindow: PopupWindow? = null

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
        // 粘滞键被一次按键"用掉"之后，键栏的字色要跟着回落。
        // Termux 是在 readSpecialButton 里清状态：这次读到的仍是"亮着"，下一次就是灭的。
        client.onModifiersConsumed = { ctrl, alt ->
            view.post {
                if (!ctrl) ctrlOn = false
                if (!alt) altOn = false
                if (::ctrlKey.isInitialized && ::altKey.isInitialized) paintModifiers()
            }
        }
        view.setTerminalViewClient(client)
        view.attachSession(session)
        // setTextSize 收的是**像素**，不是 dp：不乘 density 会小得离谱（28 看起来像 9dp）。
        val density0 = appContext.resources.displayMetrics.density
        view.setTextSize((TEXT_SIZE_DIP * density0).toInt())
        view.setBackgroundColor(Color.BLACK)

        container = android.widget.LinearLayout(appContext).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            addView(view, android.widget.LinearLayout.LayoutParams(android.view.ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        }
        container.addView(
            buildKeyRow(),
            android.widget.LinearLayout.LayoutParams(
                android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                android.view.ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )

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
                    sideInset = (args?.get("sideInset") as? Number)?.toFloat() ?: 10f
                    veilSolidDp = (args?.get("veilSolid") as? Number)?.toFloat() ?: 0f
                    veilFeatherDp = (args?.get("veilFeather") as? Number)?.toFloat() ?: 0f
                    fontDp = fontSize
                    val density = appContext.resources.displayMetrics.density
                    view.setTextSize((fontSize * density).toInt())
                    view.setTypeface(monoTypeface())
                    view.setSideInset((sideInset * density).toInt())
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

    override fun getView(): View = container

    override fun dispose() {
        channel.setMethodCallHandler(null)
    }

    private fun dp(v: Int): Int = (v * appContext.resources.displayMetrics.density).toInt()

    /**
     * 一格键。
     *
     * 三种来源：系统 keyCode（走 KeyHandler）、字面量（走 inputCodePoint）、
     * 修饰键（改 client 的粘滞状态）。[popup] 是上滑出来的候选键。
     */
    private class KeySpec(
        val label: String,
        val keyCode: Int = 0,
        val text: String? = null,
        val popup: KeySpec? = null,
        val modifier: Int = 0, // MOD_NONE
    )


    /**
     * 原生键栏（Termux 的做法）：放在平台视图内部，跟终端同一块 surface。
     *
     * 之前这条是 Flutter 画的 `ExtraKeysRow`，键盘升起时整条栏跟着重建、还要跨层
     * 同步给终端，一卡就卡在这儿。搬进来之后键栏高度固定，只有终端本身要重排。
     *
     * 键位、显示字符、按下反馈、长按重复、上滑候选、修饰键锁，全部照 Termux 的
     * `ExtraKeysView` 抄——那边是 TextView 网格 + 每次 ACTION_DOWN 换底色。
     */
    private fun buildKeyRow(): android.view.View {
        // Termux 默认布局（TermuxPropertyConstants.DEFAULT_IVALUE_EXTRA_KEYS）：
        //   ESC  /  ―  HOME  ↑  END  PGUP
        //   ↹    CTRL ALT  ←   ↓   →  PGDN
        // 「―」是 NICER_LOOKING_DISPLAY 里 `-` 的显示，上滑出「|」；TAB 显示成「↹」。
        val column = android.widget.LinearLayout(appContext).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            setBackgroundColor(0xFF0B0C0E.toInt())
        }
        column.addView(
            makeRow(
                listOf(
                    KeySpec("ESC", keyCode = android.view.KeyEvent.KEYCODE_ESCAPE),
                    KeySpec("/", text = "/"),
                    KeySpec("―", text = "-", popup = KeySpec("|", text = "|")),
                    KeySpec("HOME", keyCode = android.view.KeyEvent.KEYCODE_MOVE_HOME),
                    KeySpec("↑", keyCode = android.view.KeyEvent.KEYCODE_DPAD_UP),
                    KeySpec("END", keyCode = android.view.KeyEvent.KEYCODE_MOVE_END),
                    KeySpec("PGUP", keyCode = android.view.KeyEvent.KEYCODE_PAGE_UP),
                ),
            ),
        )
        column.addView(
            makeRow(
                listOf(
                    KeySpec("↹", keyCode = android.view.KeyEvent.KEYCODE_TAB),
                    KeySpec("CTRL", modifier = MOD_CTRL),
                    KeySpec("ALT", modifier = MOD_ALT),
                    KeySpec("←", keyCode = android.view.KeyEvent.KEYCODE_DPAD_LEFT),
                    KeySpec("↓", keyCode = android.view.KeyEvent.KEYCODE_DPAD_DOWN),
                    KeySpec("→", keyCode = android.view.KeyEvent.KEYCODE_DPAD_RIGHT),
                    KeySpec("PGDN", keyCode = android.view.KeyEvent.KEYCODE_PAGE_DOWN),
                ),
            ),
        )
        return column
    }

    /** 一行键：等分宽度、字居中，只有底色和字色会变——跟 Termux 的 MaterialButton 同观感。 */
    @SuppressLint("ClickableViewAccessibility")
    private fun makeRow(keys: List<KeySpec>): android.view.View {
        val row = android.widget.LinearLayout(appContext).apply {
            orientation = android.widget.LinearLayout.HORIZONTAL
            layoutParams = android.widget.LinearLayout.LayoutParams(
                android.view.ViewGroup.LayoutParams.MATCH_PARENT, dp(38),
            )
        }
        for (spec in keys) {
            val cell = android.widget.TextView(appContext).apply {
                text = spec.label
                textSize = 14f
                typeface = Typeface.DEFAULT
                includeFontPadding = false
                gravity = android.view.Gravity.CENTER
                letterSpacing = 0.08f
                setTextColor(KEY_IDLE)
                isClickable = true
                isFocusable = false
                layoutParams = android.widget.LinearLayout.LayoutParams(0, dp(38), 1f)
            }
            when (spec.modifier) {
                MOD_CTRL -> ctrlKey = cell
                MOD_ALT -> altKey = cell
            }
            cell.setOnTouchListener { v, e -> onKeyTouch(v as android.widget.TextView, spec, e) }
            row.addView(cell)
        }
        return row
    }

    /**
     * 按下 / 拖动 / 抬起：逐条对着 `ExtraKeysView` 的 OnTouchListener 来。
     *
     * 按下就把整格染成 active 底色，抬起抹掉——Termux 的"按钮反馈"就是这一下，
     * 没有水波纹、没有圆角、没有缩放。
     */
    private fun onKeyTouch(cell: android.widget.TextView, spec: KeySpec, e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                cell.setBackgroundColor(KEY_PRESSED)
                startHold(cell, spec)
            }
            MotionEvent.ACTION_MOVE -> {
                val popup = spec.popup
                if (popup != null) {
                    // 手指上滑出格（y < 0）→ 弹出候选键；滑回来就收掉。
                    if (popupWindow == null && e.y < 0) {
                        stopHold()
                        cell.setBackgroundColor(Color.TRANSPARENT)
                        showPopup(cell, popup)
                    } else if (popupWindow != null && e.y > 0) {
                        cell.setBackgroundColor(KEY_PRESSED)
                        dismissPopup()
                    }
                }
            }
            MotionEvent.ACTION_CANCEL -> {
                cell.setBackgroundColor(Color.TRANSPARENT)
                stopHold()
            }
            MotionEvent.ACTION_UP -> {
                cell.setBackgroundColor(Color.TRANSPARENT)
                stopHold()
                // 重复键已经发过的不补发；滑进候选键的按候选键算。
                if (holdCount == 0 || popupWindow != null) {
                    if (popupWindow != null) {
                        dismissPopup()
                        spec.popup?.let { fire(cell, it) }
                    } else {
                        fire(cell, spec)
                    }
                }
            }
        }
        return true
    }

    /**
     * 发一个键。
     *
     * keyCode 走 `TerminalView.onKeyDown`（方向键的 application cursor mode、HOME/END
     * 该发 `\e[H` 还是 `\e[1~`、Ctrl/Alt 的修饰序列，全由 Termux 的 KeyHandler 算），
     * 字面量走 `inputCodePoint`。修饰键的状态由 client 在读取时自己消费。
     */
    private fun fire(cell: View, spec: KeySpec) {
        // Termux 的触感反馈：KEYBOARD_TAP，每发一次响一次——长按重复也是一直响。
        cell.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
        when {
            spec.modifier == MOD_CTRL -> toggleModifier(ctrl = true)
            spec.modifier == MOD_ALT -> toggleModifier(ctrl = false)
            spec.keyCode != 0 -> {
                val event = android.view.KeyEvent(0, 0, android.view.KeyEvent.ACTION_UP, spec.keyCode, 0, 0)
                view.onKeyDown(spec.keyCode, event)
            }
            else -> {
                val text = spec.text ?: return
                var i = 0
                while (i < text.length) {
                    val codePoint = text.codePointAt(i)
                    view.inputCodePoint(TerminalView.KEY_EVENT_SOURCE_VIRTUAL_KEYBOARD, codePoint, false, false)
                    i += Character.charCount(codePoint)
                }
            }
        }
    }

    /**
     * 按住之后干两件事之一：重复键每 [REPEAT_MS] 发一次；修饰键到点就锁住。
     *
     * 起点都是系统的长按时长（ViewConfiguration，一般 400ms），跟 Termux 一致。
     */
    private fun startHold(cell: View, spec: KeySpec) {
        stopHold()
        holdCount = 0
        val timeout = ViewConfiguration.getLongPressTimeout().toLong()
        when {
            spec.keyCode in REPEATABLE_KEYS -> {
                val task = object : Runnable {
                    override fun run() {
                        holdCount++
                        // Termux 长按方向键是"一直震"的：每发一次都带一下 KEYBOARD_TAP。
                        fire(cell, spec)
                        holdHandler.postDelayed(this, REPEAT_MS)
                    }
                }
                holdTask = task
                holdHandler.postDelayed(task, timeout)
            }
            spec.modifier != MOD_NONE -> {
                val task = Runnable {
                    holdCount++
                    lockModifier(spec.modifier)
                }
                holdTask = task
                holdHandler.postDelayed(task, timeout)
            }
        }
    }

    private fun stopHold() {
        holdTask?.let { holdHandler.removeCallbacks(it) }
        holdTask = null
    }

    /** 上滑候选：一个和键同尺寸的浮窗，盖在键上方两格高的地方（Termux 的 showAsDropDown(-2h)）。 */
    private fun showPopup(anchor: View, spec: KeySpec) {
        val cell = android.widget.TextView(appContext).apply {
            text = spec.label
            textSize = 14f
            typeface = Typeface.DEFAULT
            includeFontPadding = false
            gravity = android.view.Gravity.CENTER
            letterSpacing = 0.08f
            setTextColor(KEY_IDLE)
            setBackgroundColor(KEY_PRESSED)
        }
        val popup = PopupWindow(cell, anchor.width, anchor.height, false).apply {
            isOutsideTouchable = true
            isFocusable = false
        }
        popupWindow = popup
        popup.showAsDropDown(anchor, 0, -2 * anchor.height)
    }

    private fun dismissPopup() {
        popupWindow?.dismiss()
        popupWindow = null
    }

    /** 点一下 = 开/关；锁定在长按里做。 */
    private fun toggleModifier(ctrl: Boolean) {
        if (ctrl) {
            ctrlOn = !ctrlOn
            ctrlLocked = false
        } else {
            altOn = !altOn
            altLocked = false
        }
        pushModifiers()
    }

    /** 长按：还没开就开了并锁住；已经开了就关掉并解锁（Termux 的 SpecialButtonsLongHoldRunnable）。 */
    private fun lockModifier(modifier: Int) {
        if (modifier == MOD_CTRL) {
            ctrlLocked = !ctrlOn
            ctrlOn = !ctrlOn
        } else {
            altLocked = !altOn
            altOn = !altOn
        }
        pushModifiers()
    }

    private fun pushModifiers() {
        client.setModifiers(ctrl = ctrlOn, alt = altOn, lockedCtrl = ctrlLocked, lockedAlt = altLocked)
        paintModifiers()
    }

    /** 修饰键开着的时候字是 Termux 的青色（DEFAULT_BUTTON_ACTIVE_TEXT_COLOR）。 */
    private fun paintModifiers() {
        ctrlKey.setTextColor(if (ctrlOn) KEY_ACTIVE else KEY_IDLE)
        altKey.setTextColor(if (altOn) KEY_ACTIVE else KEY_IDLE)
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

        /** 修饰键编号。 */
        private const val MOD_NONE = 0
        private const val MOD_CTRL = 1
        private const val MOD_ALT = 2

        /** 长按之后重复键的间隔（Termux 的 DEFAULT_LONG_PRESS_REPEAT_DELAY）。 */
        private const val REPEAT_MS = 80L

        /**
         * Termux 的默认键色（ExtraKeysView 里那三个 DEFAULT_*）。
         *
         * **必须是 const**：`init` 里就会建键栏，实例字段按声明顺序初始化，
         * 放在 init 后面的 `val` 那时还是 0——键栏的字会全是透明的（上一版就栽在这）。
         */
        private const val KEY_IDLE = -1            // 0xFFFFFFFF
        private const val KEY_ACTIVE = -8331542    // 0xFF80DEEA
        private const val KEY_PRESSED = -8421505   // 0xFF7F7F7F

        /** Termux 的 PRIMARY_REPETITIVE_KEYS 里我们键栏上有的那几个。 */
        private val REPEATABLE_KEYS = setOf(
            android.view.KeyEvent.KEYCODE_DPAD_UP,
            android.view.KeyEvent.KEYCODE_DPAD_DOWN,
            android.view.KeyEvent.KEYCODE_DPAD_LEFT,
            android.view.KeyEvent.KEYCODE_DPAD_RIGHT,
            android.view.KeyEvent.KEYCODE_PAGE_UP,
            android.view.KeyEvent.KEYCODE_PAGE_DOWN,
        )
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
