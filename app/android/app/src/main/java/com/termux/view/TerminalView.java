package com.termux.view;

import android.annotation.SuppressLint;
import android.annotation.TargetApi;
import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.text.Editable;
import android.text.InputType;
import android.text.Selection;
import android.text.SpannableStringBuilder;
import android.text.TextUtils;
import android.util.AttributeSet;
import android.view.HapticFeedbackConstants;
import android.view.InputDevice;
import android.view.KeyCharacterMap;
import android.view.ActionMode;
import android.view.KeyEvent;
import android.view.Menu;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.VelocityTracker;
import android.view.ViewTreeObserver;
import android.view.accessibility.AccessibilityManager;
import android.view.autofill.AutofillManager;
import android.view.autofill.AutofillValue;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputMethodManager;
import android.widget.Scroller;

import androidx.annotation.Nullable;
import androidx.annotation.RequiresApi;

import com.termux.terminal.KeyHandler;
import com.termux.terminal.TerminalEmulator;
import com.termux.terminal.TerminalSession;
import com.termux.terminal.TextStyle;

import java.util.Arrays;
import com.termux.view.textselection.TextSelectionCursorController;

/** View displaying and interacting with a {@link TerminalSession}. */
public final class TerminalView extends View {

    /** Log terminal view key and IME events. */
    private static boolean TERMINAL_VIEW_KEY_LOGGING_ENABLED = false;

    /** The currently displayed terminal session, whose emulator is {@link #mEmulator}. */
    public TerminalSession mTermSession;
    /** Our terminal emulator whose session is {@link #mTermSession}. */
    public TerminalEmulator mEmulator;

    /**
     * T22: 顶部遮罩。终端是 Flutter 平台视图，压在它上面的 Flutter 图层会把它整块盖掉
     * （#51：满屏黑、无字），所以遮罩只能画在视图内部——顶上 mVeilSolidPx 像素实心，
     * 再往下 mVeilFeatherPx 像素羽化到透明。颜色取终端自己的默认背景色，和底色同源。
     */
    private int mVeilSolidPx;
    private int mVeilFeatherPx;
    private final Paint mVeilPaint = new Paint();

    public void setTopVeil(int solidPx, int featherPx) {
        mVeilSolidPx = solidPx;
        mVeilFeatherPx = featherPx;
        invalidate();
    }

    /**
     * 文字两侧的留白（px）。终端本身仍然铺满整个宽度，只是**行**往里缩一点——
     * 不是把视图挤窄。updateSize 与 onDraw 都按这个偏移算。
     */
    private int mSideInsetPx;

    public void setSideInset(int px) {
        if (px == mSideInsetPx) return;
        mSideInsetPx = px;
        updateSize();
        invalidate();
    }

    /** T17: 终端调色板。终端是平台视图，Dart 侧的 TerminalPalette 走不到这里，只能下发。 */
    private boolean mHasPalette;
    private int mPaletteBg;
    private int mPaletteFg;
    private int mPaletteCursor;

    public void setPalette(int background, int foreground, int cursor) {
        mPaletteBg = background;
        mPaletteFg = foreground;
        mPaletteCursor = cursor;
        mHasPalette = true;
        applyPalette();
    }

    /** 调色板要在模拟器存在之后落到 mCurrentColors 上；布局时模拟器才建出来。 */
    private void applyPalette() {
        if (!mHasPalette) return;
        setBackgroundColor(mPaletteBg);
        if (mEmulator != null) {
            mEmulator.mColors.mCurrentColors[TextStyle.COLOR_INDEX_FOREGROUND] = mPaletteFg;
            mEmulator.mColors.mCurrentColors[TextStyle.COLOR_INDEX_BACKGROUND] = mPaletteBg;
            mEmulator.mColors.mCurrentColors[TextStyle.COLOR_INDEX_CURSOR] = mPaletteCursor;
        }
        invalidate();
    }

    /** T22 探针：宿主用它确认 onDraw 到底有没有被调到。定位完删。 */
    public Runnable mDrawProbe;

    public void setDrawProbe(Runnable probe) {
        mDrawProbe = probe;
    }

    public TerminalRenderer mRenderer;

    public TerminalViewClient mClient;

    private TextSelectionCursorController mTextSelectionCursorController;

    private Handler mTerminalCursorBlinkerHandler;
    private TerminalCursorBlinkerRunnable mTerminalCursorBlinkerRunnable;
    private int mTerminalCursorBlinkerRate;
    private boolean mCursorInvisibleIgnoreOnce;
    public static final int TERMINAL_CURSOR_BLINK_RATE_MIN = 100;
    public static final int TERMINAL_CURSOR_BLINK_RATE_MAX = 2000;

    /** The top row of text to display. Ranges from -activeTranscriptRows to 0. */
    int mTopRow;

    /**
     * 整行之间的像素零头（正 = 内容相对 mTopRow 又向上移了这么多像素）。
     *
     * <p>为什么要它：终端一屏只能按整行画，原来的滚动一次就是一行（≈49px），
     * 慢速拖动时看起来像整屏在行与行之间跳。这里把"不足一行"的那段留在像素上，
     * 绘制时整块平移，于是**运动中**是连续的；**停手后**（{@link #settleScrollPixels()}）
     * 一定缓回 0，静止状态仍然严格整行对齐——选择、点按、读屏走的还是老路径。
     */
    private int mScrollPixels;

    /** 备屏 / 鼠标跟踪下的像素累加器（那条路径没有"行间"，只借它凑整行）。 */
    private int mAltScrollAccum;

    /**
     * 惯性是否在跑。
     *
     * <p>为什么需要：{@link #settleScrollPixels()} 在每次抬手都会被调用，而它每帧把
     * {@link #mScrollPixels} 往 0 收。惯性循环又每帧在改同一个变量——两个写者互相吃，
     * 表现是"推进一点就被拽回行网格"，也就是 He 2026-11-20 报的"隔一段撞一下墙"。
     * 惯性期间必须让缓动闭嘴。
     */
    private boolean mFlinging;

    /** 最后一次滚动的方向：+1 = 往新内容（pos 增大），-1 = 往历史。收尾取整要用它。 */
    private int mScrollDir;
    int[] mDefaultSelectors = new int[]{-1,-1,-1,-1};

    float mScaleFactor = 1.f;
    final GestureAndScaleRecognizer mGestureRecognizer;

    /** Keep track of where mouse touch event started which we report as mouse scroll. */
    private int mMouseScrollStartX = -1, mMouseScrollStartY = -1;
    /** Keep track of the time when a touch event leading to sending mouse scroll events started. */
    private long mMouseStartDownTime = -1;

    final Scroller mScroller;

    private int mTouchSampleCount;
    private final float[] mTouchSampleY = new float[24];
    private final long[] mTouchSampleT = new long[24];
    /** 本次手势里原生 `onFling` 有没有真的跑过。跑过就绝不补，免得一次滑动走两步。 */
    private boolean mNativeFlingRan;

    /**
     * 自己的一份速度计（2026-11-19，第二轮）。
     *
     * <p>第一版取证量出一件事：`GestureDetector` 在 126 次抬手里有 92 次根本没调
     * `onFling`，而同一串事件里速度清清楚楚（3000–12000 px/s），它自己触发时算出的值
     * 也和这里几乎一致。既然"谁来点这一枪"不稳定，就把这一枪收回来自己点：
     * 速度从这个跟踪器取，两条路共用一个数。
     */
    private final VelocityTracker mReleaseTracker = VelocityTracker.obtain();

    /** 走手指拖动时，惯性速度 = (px/s ÷ 行高) × gain。gain 运行时由 `files/fling_gain` 调。 */
    private static final float DEFAULT_FLING_GAIN = 0.52f;
    /** 每帧（60fps 归一）速度乘这个数：0.94 ≈ 时间常数 0.26 秒。 */
    private static final double FLING_FRICTION = 0.93;
    /** 低于这个速度（行/秒）就收手，避免无限追下去。 */
    private static final double FLING_STOP_ROWS_PER_SEC = 0.8;
    /** 一次惯性最长多久（纳秒）。防止速度阈值不达标时一直追下去。 */
    private static final long FLING_MAX_NS = 1_500_000_000L;

    /** What was left in from scrolling movement. */
    float mScrollRemainder;

    /** If non-zero, this is the last unicode code point received if that was a combining character. */
    int mCombiningAccent;

    /**
     * DSH S2d：给输入法一块**可以真的移动光标**的编辑区（术语：锚点）。
     *
     * <p>为什么非它不可：{@code TYPE_NULL} 下多数输入法（中文输入法尤其）根本不为方向键
     * 产生任何回调——既不发 {@code KeyEvent}，也不调 {@code setSelection}，因为"光标"
     * 这个概念在它们眼里根本不存在。S2c 只接住了 {@code setSelection}，于是接不到东西。
     *
     * <p>结构是 {@code [PAD 空格][待发内容][PAD 空格]}，光标默认停在中间。方向键让 IME
     * 在这段空格里挪光标，位移翻译成 {@code ESC[D} / {@code ESC[C}；真正要送进终端的
     * 是中间那段，发完立刻重建，锚点回到正中，所以光标永远走不到边上。
     */
    /**
     * 锚点两侧各留多少格空格。**可用带宽就等于这个数**（见 syncImeSelection 的上下界）。
     *
     * <p>定这个数的依据是实测，不是抄谁：Gboard 滑动一次跨 53 格
     * （`ime_trace.txt`：start 133→186）。32 格必然中途撞墙（53 > 32，这就是当年的"卡住"）；
     * 96 格给到 1.8 倍余量，正常一次滑动碰不到边，只在连续长滑时才触发重建。
     */
    /**
     * DSH S2j：假编辑区两侧各留多少空格。
     *
     * <p>2026-11-18 的 trace 给了答案：输入法连上来就问 `getTextBeforeCursor(1024)`，
     * 我们只给得出 96（PAD 就是 96）。它整场只问 8 次、`cursorUpdates` 一次没调——
     * 也就是说它的视野在连接那一刻定死，之后不再刷新，我们喂多少它就用多少。
     * 所以这里不猜：**它要 1024，就给 1024**。两侧对称，光标从正中起算，
     * 两个方向各有 1024 格余地。
     *
     * <p>另外这是"假文本"，唯一会被当真内容是中间那段；边界必须纹丝不动，
     * 一旦漂了就会把 PAD 的空格当成用户输入灌进 pty（真机见过无故多一个空格）。
     */
    private static final int IME_ANCHOR_PAD = 96;

    private SpannableStringBuilder mImeAnchor;

    /**
     * 输入法自己那套光标坐标。不能拿锚点编辑区的 Selection 当基准——锚点每次都会回正中，
     * 而输入法的计数是自己在走的，两者一混就会把一次按键算成好几次。
     */
    private int mImeCursor = -1;

    /**
     * 按 keyCode 记"按下还没抬起"的键（值是按下时刻）。
     *
     * 早先只有一个槽位 + 800ms 时间窗：800ms 内见过同键 DOWN 就把 UP 当成有配对。那是
     * 用时间猜配对——某个同键 DOWN 一旦真的漏进来，后面 800ms 内所有真孤儿 UP 都会被
     * 误判成"有配对"丢掉，手感就是光标卡住不动、过一会儿自己又好了。改成按 key 记账，
     * 配对是事实而非猜测。[DOWN_STALE_MS] 兜住"DOWN 到了、UP 永远没来"的残局，
     * 否则那个键会一直算"按下中"，永久卡死。
     */
    private final android.util.SparseLongArray mDownAt = new android.util.SparseLongArray();
    private static final long DOWN_STALE_MS = 2000;

    SpannableStringBuilder imeAnchor() {
        if (mImeAnchor == null) resetImeAnchor();
        return mImeAnchor;
    }

    void resetImeAnchor() {
        char[] pad = new char[IME_ANCHOR_PAD * 2];
        Arrays.fill(pad, ' ');
        String blank = new String(pad);
        if (mImeAnchor == null) mImeAnchor = new SpannableStringBuilder(blank);
        else mImeAnchor.replace(0, mImeAnchor.length(), blank);
        Selection.setSelection(mImeAnchor, IME_ANCHOR_PAD, IME_ANCHOR_PAD);
    }

    /**
     * 编辑区里的删除只动中间那段负载，**不碰两侧的 PAD**。
     *
     * <p>走 `super.deleteSurroundingText` 会连 PAD 一起删：负载空的时候光标左边就是
     * 一个 PAD 空格，删掉之后编辑区少一格，而"负载"是按 [PAD, len-PAD] 切的——
     * 边界整体错位，于是之后敲的第一个字落进 PAD 里被当脚手架丢掉。现象就是
     * "空行上回退一次，接下来第一次打字没反应，要打两下才出来"（2026-11-17 报的 bug）。
     */
    void deleteImeAnchorText(int leftLength, int rightLength) {
        String payload = imeAnchorPayload();
        int cursor = Math.max(0, Math.min(payload.length(), imeAnchorSelection() - IME_ANCHOR_PAD));
        int from = Math.max(0, cursor - Math.max(0, leftLength));
        int to = Math.min(payload.length(), cursor + Math.max(0, rightLength));
        if (from > to) from = to;
        setImeAnchorPayload(payload.substring(0, from) + payload.substring(to), from);
    }

    /** 用 [payload] 重建锚点编辑区，光标落在 [cursor]（相对负载起点）。 */
    void setImeAnchorPayload(String payload, int cursor) {
        char[] padChars = new char[IME_ANCHOR_PAD];
        Arrays.fill(padChars, ' ');
        String pad = new String(padChars);
        String text = pad + payload + pad;
        if (mImeAnchor == null) mImeAnchor = new SpannableStringBuilder(text);
        else mImeAnchor.replace(0, mImeAnchor.length(), text);
        int pos = IME_ANCHOR_PAD + Math.max(0, Math.min(payload.length(), cursor));
        Selection.setSelection(mImeAnchor, pos, pos);
        mImeCursor = pos;
    }

    /** 中间那段：用户真正敲进去、还没送进终端的内容。 */
    String imeAnchorPayload() {
        String s = imeAnchor().toString();
        if (s.length() <= IME_ANCHOR_PAD * 2) return "";
        return s.substring(IME_ANCHOR_PAD, s.length() - IME_ANCHOR_PAD);
    }

    int imeAnchorSelection() {
        return Selection.getSelectionStart(imeAnchor());
    }

    /**
     * DSH S2h：把编辑区里的光标**真的**挪到输入法认为的位置。
     *
     * <p>S2g 及以前这里根本没动过编辑区的光标——它永远停在 {@link #IME_ANCHOR_PAD}，
     * 而输入法自己那套坐标一路走。走到 0 或 2*PAD 就被输入法判定为"文本到头"，
     * 滑动控制光标于是卡死（Gboard 滑几十格必撞，小米偶尔撞一次）。
     *
     * <p>现在：位置在两个 PAD 中间就跟上；靠边就把整块重建、光标回到正中，
     * 再用 {@code InputMethodManager.updateSelection} **告诉输入法坐标变了**，
     * 于是它下一次计算位移时以新坐标为准，不会撞墙。
     */
    void syncImeSelection(int start, int end) {
        int lo = IME_ANCHOR_PAD / 2;
        int hi = IME_ANCHOR_PAD * 2 - IME_ANCHOR_PAD / 2;
        if (start >= lo && start <= hi) {
            int s = Math.min(start, IME_ANCHOR_PAD * 2);
            int e = Math.min(Math.max(end, s), IME_ANCHOR_PAD * 2);
            Selection.setSelection(imeAnchor(), s, e);
            return;
        }
        resetImeAnchor();
        mImeCursor = IME_ANCHOR_PAD;
    }

    /**
     * DSH S2i：方向键走 KeyEvent 时，输入法**自己那套坐标**也在同步走。
     *
     * <p>它判断"能不能再往这个方向挪"看的是编辑区里的光标：走到 0 或 2*PAD 就被
     * 当成"文本到头"，那个方向从此不再出键。现象是——向左挪不动、向右还能挪；
     * 往末尾走一趟把光标推回去，又能挪一段，然后在新位置再撞一次。
     * 真机 2026-11-18 报的就是这个。
     *
     * <p>这条路径**不经过 setSelection**，所以 S2h 那个居中窗口从来没被触发过——
     * 它写在 setSelection 的处理器里，而对这款输入法来说那是个空电话。
     * 这里按方向补记一格，再走一次 {@link #syncImeSelection}：窗口内就把 Selection
     * 跟上，出窗口就整块重建、坐标回正中，并通知输入法。
     */
    private void trackImeCaretForKey(int keyCode) {
        final int step = keyCode == KeyEvent.KEYCODE_DPAD_LEFT ? -1
                       : keyCode == KeyEvent.KEYCODE_DPAD_RIGHT ? 1 : 0;
        if (step == 0) return;
        if (mImeCursor < 0) mImeCursor = imeAnchorSelection();
        mImeCursor += step;

        // 2026-11-18 对照实验决定了这一刀：同一个滑动区在**别的 App 的输入框里
        // 一路顺滑**，只有我们这儿会卡在第 N 格。差别只有一处——真编辑区每挪一格
        // 都会把新位置报给输入法（app 里 setSelection → IMM.updateSelection），
        // 而我们这块假编辑区从头到尾没报过：Selection 动了也只是本地字段变，
        // 输入法那边光标一直停在原处。它按"我发了 N 次、位置没变"判断到头，于是收手。
        //
        // 所以：每挪一格就真的把 Selection 移过去，并且 updateSelection 通知它。
        // 这不叫加东西——这是让假编辑区表现得跟真的一样。
        mImeCursor = Math.max(1, Math.min(IME_ANCHOR_PAD * 2 - 1, mImeCursor));
        Selection.setSelection(imeAnchor(), mImeCursor, mImeCursor);

        // 快到边上就整块重建、回到正中，别让它有机会走到 0 或 2*PAD。
        if (mImeCursor < IME_ANCHOR_PAD / 2 || mImeCursor > IME_ANCHOR_PAD * 2 - IME_ANCHOR_PAD / 2) {
            setImeAnchorPayload(imeAnchorPayload(), 0);
        }
    }

    /** 让输入法知道编辑区光标现在在哪，否则它的模型会和我们越走越远。 */
    /**
     * 运行时可开的轨迹（默认关，由 `files/ime_trace_on` 打开）。
     *
     * <p>为什么做成开关而不是一直记：滑动一次就是一串密事件，常态记录毫无必要；
     * 但"小米首次那一下"这种只出现一次的毛病，事后没有现场就只能猜。
     * 留一个能远程打开的记录器，复发时第一手数据直接落盘，不用再为取证出构建。
     */
    /**
     * 上一次通过组合输入送进终端的文本。
     *
     * <p>用来去重：有的输入法顺序是「结束组合 → 提交」，两处都会送到最终文本，
     * 不去重就会发两遍。payload 只可能来自基类 setComposingText 往编辑区里插的那段，
     * 所以它和 commitText 的文本可直接比对。
     */
    private String mLastSentComposing = "";



    /** 留最近 24 个采样点，够算 100ms 窗口内的速度。 */
    private void sampleTouch(MotionEvent event) {
        if (mTouchSampleCount == mTouchSampleY.length) {
            System.arraycopy(mTouchSampleY, 1, mTouchSampleY, 0, mTouchSampleY.length - 1);
            System.arraycopy(mTouchSampleT, 1, mTouchSampleT, 0, mTouchSampleT.length - 1);
            mTouchSampleCount--;
        }
        mTouchSampleY[mTouchSampleCount] = event.getY();
        mTouchSampleT[mTouchSampleCount] = event.getEventTime();
        mTouchSampleCount++;
    }

    /**
     * 用原生事件自己算纵向速度（px/ms）。
     *
     * <p>`GestureDetector` 的 `onFling` 依赖它内部的 VelocityTracker，而那套东西要靠
     * 完整的 DOWN…UP 序列喂出来。平台视图这一层的事件是 Flutter 转发下来的，
     * 时序未必是原样——所以这里独立取一份样本，不看手势识别的脸色。
     */
    private float sampleVelocityY() {
        if (mTouchSampleCount < 2) return 0f;
        final int last = mTouchSampleCount - 1;
        final long lastT = mTouchSampleT[last];
        int first = last;
        while (first > 0 && lastT - mTouchSampleT[first - 1] <= 100) first--;
        final long dt = lastT - mTouchSampleT[first];
        if (dt <= 0) return 0f;
        return (mTouchSampleY[last] - mTouchSampleY[first]) / (float) dt;
    }

    /**
     * 抬手时起一次惯性。这是**唯一**的起点：不管 `GestureDetector` 有没有调 `onFling`，
     * 速度都从这里出，两条路不会有两个手感。
     *
     * <p>判据用系统最小 fling 速度，慢慢拖到停下的手势不会触发。
     */
    private void maybeFlingFromRawSamples(MotionEvent event) {
        if (mEmulator == null) return;
        final float velocityY = releaseVelocityY(); // px/s
        final float minFling = ViewConfiguration.get(getContext()).getScaledMinimumFlingVelocity();
        final int transcript = mEmulator.getScreen().getActiveTranscriptRows();
        if (Math.abs(velocityY) < Math.max(minFling, 150f)) return;
        // 鼠标跟踪时 onFling 已经自己点过一次火了，这里不重复。
        if (mEmulator.isMouseTrackingActive()) return;
        startFling(event, velocityY);
    }

    /** 抬手瞬间的纵向速度，px/秒。跟踪器没给出可信值时退回 100ms 窗口均值。 */
    private float releaseVelocityY() {
        try {
            mReleaseTracker.computeCurrentVelocity(1000,
                ViewConfiguration.get(getContext()).getScaledMaximumFlingVelocity());
            final float v = mReleaseTracker.getYVelocity();
            if (!Float.isNaN(v) && v != 0f) return v;
        } catch (Throwable ignored) {
        }
        return sampleVelocityY() * 1000f;
    }



    /**
     * 起一次惯性滚动。入参速度是**手指的 px/秒**。
     *
     * <p>这里修掉了上游的一个量纲错误：`mScroller.fling` 的纵轴单位是"行"，上游却直接把
     * `velocityY * 0.25` 当成行速喂进去。按 2026-11-19 实测（行高 55.7px，手指 4000–9000px/s），
     * 那等于把手指自己的行速（72–162 行/秒）放大 **13.9 倍**（1000–2250 行/秒），
     * 换算成屏幕就是每秒 8–14 屏——"飞得太快"不是玄学，是这个乘法。
     *
     * <p>正确的换算只有一句话：行/秒 = (px/秒) ÷ 行高。再乘一个可调的 gain。
     */
    /**
     * 松手后的惯性。
     *
     * <p>2026-11-19 第四版：**不再用 Scroller 算手指这一条**。
     *
     * <p>前三版都栽在"单位/量级对不上"上：先是在行空间里喂像素速度（时长 0，不走），
     * 再是把像素速度和行边界混用（一冲到底立刻停）；而 He 又给了更准的观察——
     * **不管甩多大力，减速度都一样**，说明真正决定位移的是边界，不是初速度。
     *
     * <p>所以这里直接写物理：速度读作**行/秒**（甩得越快这个数越大），每帧乘一个
     * 衰减系数，位移 = v·dt 累加。初速决定走多远，衰减决定多快停——两者都随甩力变化。
     */
    void startFling(final MotionEvent e2, float velocityY) {
        if (mEmulator == null || e2 == null) return;
        // 这里**不**把像素零头并进整行：不足半行时那一并是往回退，
        // 叠上惯性就成了"先反向拖一下再正向发力"，净位移归零（He 2026-11-20 报的）。
        // 零头留在 mScrollPixels 上，整段惯性期间保持同一个偏移，收尾时再缓回。
        mScrollRemainder = 0f;
        mFlinging = true;
        final boolean mouseTrackingAtStartOfFling = mEmulator.isMouseTrackingActive();
        final float rowHeight = Math.max(1f, mRenderer.mFontLineSpacing);
        final float gain = DEFAULT_FLING_GAIN;
        // 负号不能丢：Termux 原版是 `-(int)(velocityY * SCALE)`。
        // 拖动时向下（y 增大、velocityY 为正）对应 top 减小（往旧内容走），
        // 所以行速度要取负才是同一个方向。丢了负号就会松手往反方向收回（弹簧感）。
        final float v0 = -(velocityY / rowHeight) * gain;   // 行/秒

        post(new Runnable() {
            private double v = v0;          // 行/秒
            private double acc = 0;         // 小数行，凑满一行才动
            private long lastNs = 0;
            private int mTicks = 0;
            private final int startTop = mTopRow;
            private final long flingStartNs = System.nanoTime();

            @Override
            public void run() {
                if (mouseTrackingAtStartOfFling != mEmulator.isMouseTrackingActive()) {
                    mFlinging = false;
                    return;
                }
                final long now = System.nanoTime();
                // 第一帧 lastNs 还是 0：这时 dt 按一个标称帧算，**绝对不能 return**——
                // 第一版就是 `if (dt <= 0) return;`，第一帧 dt 恰为 0，循环当场中止，
                // 表现是"离手即停、零惯性"（2026-11-19 He 报的）。
                double dt = lastNs == 0 ? 1.0 / 60.0 : (now - lastNs) / 1_000_000_000.0;
                lastNs = now;
                if (dt > 0.05) dt = 0.05;     // 掉帧时别一步跳太远
                if (dt <= 0) dt = 1.0 / 60.0;

                // 第 2 步：惯性也走像素路径。
                //
                // 原来是攒够整行调 doScroll，所以拖拽虽然连续了，松手之后仍在整行跳——
                // 而手机上大部分位移恰恰来自惯性，观感就等于"整行滚动"。
                // 这里只把"行"换算成"像素"再交给 scrollWithPixels：
                // 速度、摩擦、停止阈值全都沿用原来的行/秒模型，不重新调参。
                acc += v * dt;                                  // 小数行
                final int pixels = (int) (acc * rowHeight);     // 换成像素
                if (pixels != 0) {
                    acc -= pixels / rowHeight;                  // 余量留在行上，不丢
                    scrollWithPixels(e2, pixels);
                }

                // 每帧衰减（按 60fps 归一，掉帧时按 dt 补偿）
                v *= Math.pow(FLING_FRICTION, dt * 60.0);
                mTicks++;

                final boolean timeUp = (now - flingStartNs) > FLING_MAX_NS;
                if (Math.abs(v) > FLING_STOP_ROWS_PER_SEC && !timeUp) {
                    // postOnAnimation：挂在 Choreographer 上，屏幕 60/90/120Hz 就按多少帧走。
                    // 物理那边用 `pow(friction, dt*60)` 归一，所以衰减曲线与刷新率无关——
                    // 120Hz 只是把同一段运动画得更细，不会滑得更远。
                    // （不能用 post：它在消息队列里空转，150 次只要 5 毫秒，位移累加不到一行。）
                    postOnAnimation(this);
                } else {
                    // 惯性停下来了，这时才允许把不足一行的零头缓回 0（静止必须整行对齐）。
                    mFlinging = false;
                    settleScrollPixels();
                }
            }
        });
    }


    /**
     * The current AutoFill type returned for {@link View#getAutofillType()} by {@link #getAutofillType()}.
     *
     * The default is {@link #AUTOFILL_TYPE_NONE} so that AutoFill UI, like toolbar above keyboard
     * is not shown automatically, like on Activity starts/View create. This value should be updated
     * to required value, like {@link #AUTOFILL_TYPE_TEXT} before calling
     * {@link AutofillManager#requestAutofill(View)} so that AutoFill UI shows. The updated value
     * set will automatically be restored to {@link #AUTOFILL_TYPE_NONE} in
     * {@link #autofill(AutofillValue)} so that AutoFill UI isn't shown anymore by calling
     * {@link #resetAutoFill()}.
     */
    @RequiresApi(api = Build.VERSION_CODES.O)
    private int mAutoFillType = AUTOFILL_TYPE_NONE;

    /**
     * The current AutoFill type returned for {@link View#getImportantForAutofill()} by
     * {@link #getImportantForAutofill()}.
     *
     * The default is {@link #IMPORTANT_FOR_AUTOFILL_NO} so that view is not considered important
     * for AutoFill. This value should be updated to required value, like
     * {@link #IMPORTANT_FOR_AUTOFILL_YES} before calling {@link AutofillManager#requestAutofill(View)}
     * so that Android and apps consider the view as important for AutoFill to process the request.
     * The updated value set will automatically be restored to {@link #IMPORTANT_FOR_AUTOFILL_NO} in
     * {@link #autofill(AutofillValue)} by calling {@link #resetAutoFill()}.
     */
    @RequiresApi(api = Build.VERSION_CODES.O)
    private int mAutoFillImportance = IMPORTANT_FOR_AUTOFILL_NO;

    /**
     * The current AutoFill hints returned for {@link View#getAutofillHints()} ()} by {@link #getAutofillHints()} ()}.
     *
     * The default is an empty `string[]`. This value should be updated to required value. The
     * updated value set will automatically be restored an empty `string[]` in
     * {@link #autofill(AutofillValue)} by calling {@link #resetAutoFill()}.
     */
    private String[] mAutoFillHints = new String[0];

    private final boolean mAccessibilityEnabled;

    /** The {@link KeyEvent} is generated from a virtual keyboard, like manually with the {@link KeyEvent#KeyEvent(int, int)} constructor. */
    public final static int KEY_EVENT_SOURCE_VIRTUAL_KEYBOARD = KeyCharacterMap.VIRTUAL_KEYBOARD; // -1

    /** The {@link KeyEvent} is generated from a non-physical device, like if 0 value is returned by {@link KeyEvent#getDeviceId()}. */
    public final static int KEY_EVENT_SOURCE_SOFT_KEYBOARD = 0;

    private static final String LOG_TAG = "TerminalView";

    public TerminalView(Context context, AttributeSet attributes) { // NO_UCD (unused code)
        super(context, attributes);
        mGestureRecognizer = new GestureAndScaleRecognizer(context, new GestureAndScaleRecognizer.Listener() {

            boolean scrolledWithFinger;

            @Override
            public boolean onUp(MotionEvent event) {
                mScrollRemainder = 0.0f;
                if (mEmulator != null && mEmulator.isMouseTrackingActive() && !event.isFromSource(InputDevice.SOURCE_MOUSE) && !isSelectingText() && !scrolledWithFinger) {
                    // Quick event processing when mouse tracking is active - do not wait for check of double tapping
                    // for zooming.
                    sendMouseEventCode(event, TerminalEmulator.MOUSE_LEFT_BUTTON, true);
                    sendMouseEventCode(event, TerminalEmulator.MOUSE_LEFT_BUTTON, false);
                    return true;
                }
                scrolledWithFinger = false;
                return false;
            }

            @Override
            public boolean onSingleTapUp(MotionEvent event) {
                if (mEmulator == null) return true;

                if (isSelectingText()) {
                    stopTextSelectionMode();
                    return true;
                }
                requestFocus();
                mClient.onSingleTapUp(event);
                return true;
            }

            @Override
            public boolean onScroll(MotionEvent e, float distanceX, float distanceY) {
                if (mEmulator == null) return true;
                if (mEmulator.isMouseTrackingActive() && e.isFromSource(InputDevice.SOURCE_MOUSE)) {
                    // If moving with mouse pointer while pressing button, report that instead of scroll.
                    // This means that we never report moving with button press-events for touch input,
                    // since we cannot just start sending these events without a starting press event,
                    // which we do not do for touch input, only mouse in onTouchEvent().
                    sendMouseEventCode(e, TerminalEmulator.MOUSE_LEFT_BUTTON_MOVED, true);
                } else if (isSelectingText()) {
                    // 长按进入选择模式后，手指还没离屏时继续上下移动**不该**触发滚动。
                    // 老版本靠"整行才动"的粗量子把这件事掩盖了（不足一行什么都不会发生），
                    // 换成像素量子之后一点位移就看得见，于是问题暴露（He 2026-11-20 报的）。
                    scrolledWithFinger = false;
                } else {
                    scrolledWithFinger = true;
                    // 量子从"整行"降到"整像素"。
                    //
                    // 符号：`distanceY > 0` 是手指往上走（Android onScroll 的方向），
                    // 旧代码 `doScroll(e, +deltaRows)` 就是在这个方向上加 mTopRow；
                    // `scrollWithPixels` 的 pixelsUp 正号也指向"更新的一行"，两者同向，
                    // 所以这里**不能取负**——上一版多写了一个减号，整个拖拽就反了。
                    distanceY += mScrollRemainder;
                    int deltaPixels = (int) distanceY;
                    mScrollRemainder = distanceY - deltaPixels;
                    scrollWithPixels(e, deltaPixels);
                }
                return true;
            }

            @Override
            public boolean onScale(float focusX, float focusY, float scale) {
                if (mEmulator == null || isSelectingText()) return true;
                mScaleFactor *= scale;
                mScaleFactor = mClient.onScale(mScaleFactor);
                return true;
            }

            @Override
            public boolean onFling(final MotionEvent e2, float velocityX, float velocityY) {
                if (mEmulator == null) return true;
                // 抬手那一下统一由 dispatchTouchEvent 收尾点火（速度只认一个来源）。
                // 只有鼠标跟踪还走上游这条老路：那不是手指拖动，没有抬手事件可用。
                if (!mEmulator.isMouseTrackingActive()) {
                    mNativeFlingRan = true;
                    return true;
                }
                if (!mScroller.isFinished()) {
                    return true;
                }
                mNativeFlingRan = true;
                startFling(e2, velocityY);
                return true;
            }

            @Override
            public boolean onDown(float x, float y) {
                // Why is true not returned here?
                // https://developer.android.com/training/gestures/detector.html#detect-a-subset-of-supported-gestures
                // Although setting this to true still does not solve the following errors when long pressing in terminal view text area
                // ViewDragHelper: Ignoring pointerId=0 because ACTION_DOWN was not received for this pointer before ACTION_MOVE
                // Commenting out the call to mGestureDetector.onTouchEvent(event) in GestureAndScaleRecognizer#onTouchEvent() removes
                // the error logging, so issue is related to GestureDetector
                return false;
            }

            @Override
            public boolean onDoubleTap(MotionEvent event) {
                // Do not treat is as a single confirmed tap - it may be followed by zoom.
                return false;
            }

            @Override
            public void onLongPress(MotionEvent event) {
                if (mGestureRecognizer.isInProgress()) return;
                if (mClient.onLongPress(event)) return;
                if (!isSelectingText()) {
                    performHapticFeedback(HapticFeedbackConstants.LONG_PRESS);
                    startTextSelectionMode(event);
                }
            }
        });
        mScroller = new Scroller(context);
        AccessibilityManager am = (AccessibilityManager) context.getSystemService(Context.ACCESSIBILITY_SERVICE);
        mAccessibilityEnabled = am.isEnabled();
    }



    /**
     * @param client The {@link TerminalViewClient} interface implementation to allow
     *                           for communication between {@link TerminalView} and its client.
     */
    public void setTerminalViewClient(TerminalViewClient client) {
        this.mClient = client;
    }

    /**
     * Sets whether terminal view key logging is enabled or not.
     *
     * @param value The boolean value that defines the state.
     */
    public void setIsTerminalViewKeyLoggingEnabled(boolean value) {
        TERMINAL_VIEW_KEY_LOGGING_ENABLED = value;
    }



    /**
     * Attach a {@link TerminalSession} to this view.
     *
     * @param session The {@link TerminalSession} this view will be displaying.
     */
    public boolean attachSession(TerminalSession session) {
        if (session == mTermSession) return false;

        mTermSession = session;
        mEmulator = null;
        mCombiningAccent = 0;

        // The emulator's cached value will be read in `updateSize()` when emulator is set.
        setTopRow(0, false);

        updateSize();

        // Wait with enabling the scrollbar until we have a terminal to get scroll position from.
        setVerticalScrollBarEnabled(true);

        return true;
    }

    @Override
    public InputConnection onCreateInputConnection(EditorInfo outAttrs) {
        // 新连接 = 新的光标坐标系，旧计数作废。
        mImeCursor = -1;
        // Ensure that inputType is only set if TerminalView is selected view with the keyboard and
        // an alternate view is not selected, like an EditText. This is necessary if an activity is
        // initially started with the alternate view or if activity is returned to from another app
        // and the alternate view was the one selected the last time.
        if (mClient.isTerminalViewSelected()) {
            // DSH S2d：这里原本是 InputType.TYPE_NULL。它确实"最正确"，代价是输入法不认为
            // 这里有光标——方向键既不发 KeyEvent 也不调 setSelection，S2c 的兜底因此空转。
            // 改成"字符型文本 + 无联想"（Termux 为三星键盘准备的那一档），再让锚点编辑区
            // （imeAnchor()）给出可移动的光标空间。IME 回退开关见 shouldEnforceCharBasedInput()。
            outAttrs.inputType = InputType.TYPE_CLASS_TEXT
                | InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
                | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS;
            outAttrs.initialSelStart = imeAnchorSelection();
            outAttrs.initialSelEnd = imeAnchorSelection();
            // 连上之后立刻把光标位置再报一次：initialSel 只是提示，有的输入法
            // 要等 updateSelection 才认账（2026-11-18 的预算是从 0 起算的，
            // 说明它压根没读到 initialSel=1024）。
        } else {
            // Corresponds to android:inputType="text"
            outAttrs.inputType =  InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_NORMAL;
        }

        // Note that IME_ACTION_NONE cannot be used as that makes it impossible to input newlines using the on-screen
        // keyboard on Android TV (see https://github.com/termux/termux-app/issues/221).
        outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_FULLSCREEN;

        return new BaseInputConnection(this, true) {

            @Override
            public boolean finishComposingText() {
                if (TERMINAL_VIEW_KEY_LOGGING_ENABLED) mClient.logInfo(LOG_TAG, "IME: finishComposingText()");
                super.finishComposingText();

                if (mEmulator != null) flushAnchorPayload();
                return true;
            }

            @Override
            public boolean commitText(CharSequence text, int newCursorPosition) {
                if (TERMINAL_VIEW_KEY_LOGGING_ENABLED) {
                    mClient.logInfo(LOG_TAG, "IME: commitText(\"" + text + "\", " + newCursorPosition + ")");
                }
                if (mEmulator == null) return true;

                // 2026-11-18 He 的规律把这条路指出来了：长按符号键，第一次打出一个空格、
                // 第二次才是符号，移动光标后计数重置。那是**落点偏进左边 PAD 一格**：
                // 插入把整串文本推后一位，而负载仍按固定偏移 [PAD, len-PAD] 取景，
                // 于是右边边界多吞进一个 PAD 末尾的空格，发出去就是那个空格。
                //
                // 根子在于"按偏移切窗口"这个设计本身。所以不再让编辑区累积任何用户文本：
                // 输入法交给我们什么，就直接送进终端，然后整块重建回干净状态。
                // 编辑区长度恒定 ⇒ 边界永远不漂 ⇒ 这类错位从根上没有了。
                final String committed = text == null ? "" : text.toString();
                final boolean alreadySent = !committed.isEmpty() && committed.equals(mLastSentComposing);
                if (!committed.isEmpty() && !alreadySent) sendTextToTerminal(committed);
                mLastSentComposing = "";
                resetImeAnchor();
                mImeCursor = -1;
                return true;
            }

            @Override
            public boolean deleteSurroundingText(int leftLength, int rightLength) {
                if (TERMINAL_VIEW_KEY_LOGGING_ENABLED) {
                    mClient.logInfo(LOG_TAG, "IME: deleteSurroundingText(" + leftLength + ", " + rightLength + ")");
                }
                // The stock Samsung keyboard with 'Auto check spelling' enabled sends leftLength > 1.
                KeyEvent deleteKey = new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DEL);
                for (int i = 0; i < leftLength; i++) sendKeyEvent(deleteKey);
                // 终端那边收到 DEL 就够了；编辑区这里只删负载，PAD 一格都不许动。
                deleteImeAnchorText(leftLength, rightLength);
                return true;
            }

            void sendTextToTerminal(CharSequence text) {
                stopTextSelectionMode();
                final int textLengthInChars = text.length();
                for (int i = 0; i < textLengthInChars; i++) {
                    char firstChar = text.charAt(i);
                    int codePoint;
                    if (Character.isHighSurrogate(firstChar)) {
                        if (++i < textLengthInChars) {
                            codePoint = Character.toCodePoint(firstChar, text.charAt(i));
                        } else {
                            // At end of string, with no low surrogate following the high:
                            codePoint = TerminalEmulator.UNICODE_REPLACEMENT_CHAR;
                        }
                    } else {
                        codePoint = firstChar;
                    }

                    // Check onKeyDown() for details.
                    if (mClient.readShiftKey())
                        codePoint = Character.toUpperCase(codePoint);

                    boolean ctrlHeld = false;
                    if (codePoint <= 31 && codePoint != 27) {
                        if (codePoint == '\n') {
                            // The AOSP keyboard and descendants seems to send \n as text when the enter key is pressed,
                            // instead of a key event like most other keyboard apps. A terminal expects \r for the enter
                            // key (although when icrnl is enabled this doesn't make a difference - run 'stty -icrnl' to
                            // check the behaviour).
                            codePoint = '\r';
                        }

                        // E.g. penti keyboard for ctrl input.
                        ctrlHeld = true;
                        switch (codePoint) {
                            case 31:
                                codePoint = '_';
                                break;
                            case 30:
                                codePoint = '^';
                                break;
                            case 29:
                                codePoint = ']';
                                break;
                            case 28:
                                codePoint = '\\';
                                break;
                            default:
                                codePoint += 96;
                                break;
                        }
                    }

                    inputCodePoint(KEY_EVENT_SOURCE_SOFT_KEYBOARD, codePoint, ctrlHeld, false);
                }
            }

            /**
             * DSH S2d：交给输入法一块带空格的锚点编辑区，它才有地方挪光标。
             * 以前这里返回 null（普通 View 的默认行为），输入法认定"没有文本"，
             * 方向键于是连回调都不发。
             */
            @Override
            public Editable getEditable() {
                return imeAnchor();
            }

            /**
             * 取证：输入法到底在问什么。
             *
             * <p>2026-11-18 的墙在地 18 格：caret 从 96 走到 78 就再也不动，而
             * `updateSelection` 把它推回去也不管用。要么它只认"取过的这段文本"，
             * 要么它压根不再问我们要文本。把这几条问句记下来就能判死——
             * 撞墙前最后一次 before/after 请求就是它的视野边界。
             */
            @Override
            public CharSequence getTextBeforeCursor(int n, int flags) {
                CharSequence r = super.getTextBeforeCursor(n, flags);
                return r;
            }

            @Override
            public CharSequence getTextAfterCursor(int n, int flags) {
                CharSequence r = super.getTextAfterCursor(n, flags);
                return r;
            }

            /**
             * 真编辑区都有这个，我们一直没有。
             *
             * <p>`ExtractedText` 是输入法拿"整块文本 + 光标在哪"的正规通道；
             * 没实现时 `BaseInputConnection` 只能给出半拉子信息，输入法退回到
             * 自己的缺省假设——**光标在 0**。2026-11-18 的预算表（81 次向左，
             * 没有一次不是先靠向右攒出来）就是"位置从 0 起算"的直接证据。
             */
            @Override
            public android.view.inputmethod.ExtractedText getExtractedText(
                    android.view.inputmethod.ExtractedTextRequest request, int flags) {
                android.view.inputmethod.ExtractedText et = new android.view.inputmethod.ExtractedText();
                et.text = imeAnchor();
                et.startOffset = 0;
                et.selectionStart = imeAnchorSelection();
                et.selectionEnd = et.selectionStart;
                et.partialStartOffset = -1;
                et.partialEndOffset = -1;
                return et;
            }

            @Override
            public boolean requestCursorUpdates(int cursorUpdateMode) {
                return super.requestCursorUpdates(cursorUpdateMode);
            }

            /** 把锚点中间那段送进终端，然后把锚点重建回正中、光标计数作废。 */
            private void flushAnchorPayload() {
                String payload = imeAnchorPayload();
                // 空格泄漏闸：负载只可能来自 commitText。没有提交过内容时，
                // 中间那段出现的任何东西都是 PAD 边界漂移带进来的假货（真机
                // 2026-11-18 见过"没按空格却多一个空格"），一律丢弃。
                // 负载只可能来自组合输入（commitText 那条路已经不往编辑区里写了）。
                // 全是空白的负载判为 PAD 边界漂移，丢弃——真机上见过"没按空格却多一个空格"。
                if (!payload.isEmpty() && !payload.trim().isEmpty()) {
                    sendTextToTerminal(payload);
                    mLastSentComposing = payload;
                }
                resetImeAnchor();
                mImeCursor = -1;
            }

            /**
             * 光标位置通道。**Gboard 的滑动控制光标就走这里**——实测 300 条事件全是
             * `sel`、零条 `keyup`。小米系统输入法则相反，全走 KeyEvent（见 onKeyUp 的孤儿处理）。
             * 两家输入法两条路，两条都得通。
             */
            @Override
            public boolean setSelection(int start, int end) {
                if (mEmulator == null) return true;
                int prev = mImeCursor;
                mImeCursor = start;
                int delta = (prev < 0) ? 0 : start - prev;
                if (TERMINAL_VIEW_KEY_LOGGING_ENABLED)
                    mClient.logInfo(LOG_TAG, "IME: setSelection(" + start + ", " + end + ") prev=" + prev + " delta=" + delta);
                if (start == end && delta != 0 && Math.abs(delta) <= IME_ANCHOR_PAD) {
                    int keyCode = delta < 0 ? KeyEvent.KEYCODE_DPAD_LEFT : KeyEvent.KEYCODE_DPAD_RIGHT;
                    for (int i = 0; i < Math.abs(delta); i++) handleKeyCode(keyCode, 0);
                }
                syncImeSelection(start, end);
                return true;
            }

        };
    }

    @Override
    protected int computeVerticalScrollRange() {
        return mEmulator == null ? 1 : mEmulator.getScreen().getActiveRows();
    }

    @Override
    protected int computeVerticalScrollExtent() {
        return mEmulator == null ? 1 : mEmulator.mRows;
    }

    @Override
    protected int computeVerticalScrollOffset() {
        return mEmulator == null ? 1 : mEmulator.getScreen().getActiveRows() + mTopRow - mEmulator.mRows;
    }

    public void onScreenUpdated() {
        onScreenUpdated(false);
    }

    public void onScreenUpdated(boolean skipScrolling) {
        if (mEmulator == null) return;

        int rowsInHistory = mEmulator.getScreen().getActiveTranscriptRows();
        if (mTopRow < -rowsInHistory) setTopRow(-rowsInHistory);

        if (isSelectingText() || mEmulator.isAutoScrollDisabled()) {
            // Do not scroll when selecting text.
            int rowShift = mEmulator.getScrollCounter();
            if (-mTopRow + rowShift > rowsInHistory) {
                // .. unless we're hitting the end of history transcript, in which
                // case we abort text selection and scroll to end.
                if (isSelectingText())
                    stopTextSelectionMode();

                if (mEmulator.isAutoScrollDisabled()) {
                    setTopRow(-rowsInHistory);
                    skipScrolling = true;
                }
            } else {
                skipScrolling = true;
                setTopRow(mTopRow - rowShift);
                decrementYTextSelectionCursors(rowShift);
            }
        }

        if (!skipScrolling && mTopRow != 0) {
            // Scroll down if not already there.
            if (mTopRow < -3) {
                // Awaken scroll bars only if scrolling a noticeable amount
                // - we do not want visible scroll bars during normal typing
                // of one row at a time.
                awakenScrollBars();
            }
            setTopRow(0);
        }

        mEmulator.clearScrollCounter();

        invalidate();
        if (mAccessibilityEnabled) setContentDescription(getText());
    }

    /** This must be called by the hosting activity in {@link Activity#onContextMenuClosed(Menu)}
     * when context menu for the {@link TerminalView} is started by
     * {@link TextSelectionCursorController#ACTION_MORE} is closed. */
    public void onContextMenuClosed(Menu menu) {
        // Unset the stored text since it shouldn't be used anymore and should be cleared from memory
        unsetStoredSelectedText();
    }

    /**
     * Sets the text size, which in turn sets the number of rows and columns.
     *
     * @param textSize the new font size, in density-independent pixels.
     */
    public void setTextSize(int textSize) {
        mRenderer = new TerminalRenderer(textSize, mRenderer == null ? Typeface.MONOSPACE : mRenderer.mTypeface);
        // 行高变了，旧的像素零头没有意义（单位都不一样了），直接归零。
        mScrollPixels = 0;
        mAltScrollAccum = 0;
        updateSize();
    }

    public void setTypeface(Typeface newTypeface) {
        mRenderer = new TerminalRenderer(mRenderer.mTextSize, newTypeface);
        mScrollPixels = 0;
        mAltScrollAccum = 0;
        updateSize();
        invalidate();
    }

    @Override
    public boolean onCheckIsTextEditor() {
        return true;
    }

    @Override
    public boolean isOpaque() {
        return true;
    }

    /**
     * Get the zero indexed column and row of the terminal view for the
     * position of the event.
     *
     * @param event The event with the position to get the column and row for.
     * @param relativeToScroll If true the column number will take the scroll
     * position into account. E.g. if scrolled 3 lines up and the event
     * position is in the top left, column will be -3 if relativeToScroll is
     * true and 0 if relativeToScroll is false.
     * @return Array with the column and row.
     */
    public int[] getColumnAndRow(MotionEvent event, boolean relativeToScroll) {
        int column = (int) (event.getX() / mRenderer.mFontWidth);
        int row = (int) ((event.getY() - mRenderer.mFontLineSpacingAndAscent) / mRenderer.mFontLineSpacing);
        if (relativeToScroll) {
            row += mTopRow;
        }
        return new int[] { column, row };
    }

    /** Send a single mouse event code to the terminal. */
    void sendMouseEventCode(MotionEvent e, int button, boolean pressed) {
        int[] columnAndRow = getColumnAndRow(e, false);
        int x = columnAndRow[0] + 1;
        int y = columnAndRow[1] + 1;
        if (pressed && (button == TerminalEmulator.MOUSE_WHEELDOWN_BUTTON || button == TerminalEmulator.MOUSE_WHEELUP_BUTTON)) {
            if (mMouseStartDownTime == e.getDownTime()) {
                x = mMouseScrollStartX;
                y = mMouseScrollStartY;
            } else {
                mMouseStartDownTime = e.getDownTime();
                mMouseScrollStartX = x;
                mMouseScrollStartY = y;
            }
        }
        mEmulator.sendMouseEvent(button, x, y, pressed);
    }

    /**
     * 像素级滚动：把零头攒够一行再折成 {@link #mTopRow}，边界处把零头吃掉。
     *
     * <p>备屏（vim / less / htop）和鼠标跟踪没有"行间"可言——那两种场景靠
     * {@link #doScroll} 发方向键或滚轮事件，所以原样交回整行逻辑，不掺像素。
     */
    private void scrollWithPixels(MotionEvent event, int pixelsUp) {
        if (mEmulator == null || mRenderer == null) return;
        final int spacing = mRenderer.mFontLineSpacing;
        if (spacing <= 0) return;
        if (mEmulator.isAlternateBufferActive() || mEmulator.isMouseTrackingActive()) {
            // 这两种模式不掺像素：清掉残留偏移，否则整屏会一直歪着（vim 里很明显）。
            mScrollPixels = 0;
            mAltScrollAccum += pixelsUp;
            final int rows = mAltScrollAccum / spacing;
            if (rows != 0) {
                mAltScrollAccum -= rows * spacing;
                if (event != null) {
                    doScroll(event, rows);
                } else {
                    setTopRow(Math.min(0, Math.max(-mEmulator.getScreen().getActiveTranscriptRows(), mTopRow + rows)));
                }
            }
            return;
        }
        // 位置统一用像素表示：pos > 0 = 内容向上。边界直接夹在 pos 上，
        // 于是拖到底/顶之后再怎么推都不产生偏移——不会"攒满一行再被弹回"
        // （那看起来就是整行抽一下，He 2026-11-20 报的第二条）。
        if (pixelsUp > 0) mScrollDir = 1;
        else if (pixelsUp < 0) mScrollDir = -1;
        final int rowsInHistory = mEmulator.getScreen().getActiveTranscriptRows();
        final int maxDown = -rowsInHistory * spacing;
        int pos = mTopRow * spacing + mScrollPixels + pixelsUp;
        if (pos > 0) pos = 0;
        else if (pos < maxDown) pos = maxDown;

        final int newTop = pos / spacing;
        mScrollPixels = pos - newTop * spacing;
        if (newTop != mTopRow) {
            setTopRow(newTop);
            if (newTop < -3) awakenScrollBars();
        }
        invalidate();
    }

    /** 停手之后把零头缓回 0：静止状态必须严格整行。 */
    private void settleScrollPixels() {
        if (mScrollPixels == 0 || mRenderer == null) return;
        // 惯性期间不许掺和：两个写者抢 mScrollPixels，就是"隔一段撞墙"的来源。
        if (mFlinging) return;
        // 朝**运动方向**取整，绝不回退（He 2026-11-20 提的）：
        //   往新内容走（pos 增大）→ 取 ceil，把那一点零头走完；
        //   往历史走（pos 减小）  → 取 floor。
        // 早先"一律缓动回 0"在某个方向上就是往回退，主观上像撞了一下墙。
        final int spacing = mRenderer.mFontLineSpacing;
        if (spacing <= 0) {
            mScrollPixels = 0;
            invalidate();
            return;
        }
        final int pos = mTopRow * spacing + mScrollPixels;
        if (pos % spacing == 0) {
            mScrollPixels = 0;
            return;
        }
        final int rows = mScrollDir >= 0 ? -Math.floorDiv(-pos, spacing) : Math.floorDiv(pos, spacing);
        final int rowsInHistory = mEmulator == null ? 0 : mEmulator.getScreen().getActiveTranscriptRows();
        final int clamped = Math.min(0, Math.max(-rowsInHistory, rows));
        mScrollPixels = 0;
        if (clamped != mTopRow) setTopRow(clamped);
        invalidate();
    }

    /** Perform a scroll, either from dragging the screen or by scrolling a mouse wheel. */
    void doScroll(MotionEvent event, int rowsDown) {
        boolean up = rowsDown < 0;
        int amount = Math.abs(rowsDown);
        for (int i = 0; i < amount; i++) {
            if (mEmulator.isMouseTrackingActive()) {
                sendMouseEventCode(event, up ? TerminalEmulator.MOUSE_WHEELUP_BUTTON : TerminalEmulator.MOUSE_WHEELDOWN_BUTTON, true);
            } else if (mEmulator.isAlternateBufferActive()) {
                // Send up and down key events for scrolling, which is what some terminals do to make scroll work in
                // e.g. less, which shifts to the alt screen without mouse handling.
                handleKeyCode(up ? KeyEvent.KEYCODE_DPAD_UP : KeyEvent.KEYCODE_DPAD_DOWN, 0);
            } else {
                final int wanted = mTopRow + (up ? -1 : 1);
                final int clamped = Math.min(0, Math.max(-(mEmulator.getScreen().getActiveTranscriptRows()), wanted));
                // 已经到头：像素零头一起归零，否则惯性会把画面顶出历史之外露白。
                if (clamped == mTopRow) mScrollPixels = 0;
                setTopRow(clamped);
                if (!awakenScrollBars()) invalidate();
            }
        }
    }

    /** Overriding {@link View#onGenericMotionEvent(MotionEvent)}. */
    @Override
    public boolean onGenericMotionEvent(MotionEvent event) {
        if (mEmulator != null && event.isFromSource(InputDevice.SOURCE_MOUSE) && event.getAction() == MotionEvent.ACTION_SCROLL) {
            // Handle mouse wheel scrolling.
            boolean up = event.getAxisValue(MotionEvent.AXIS_VSCROLL) > 0.0f;
            doScroll(event, up ? -3 : 3);
            return true;
        }
        return false;
    }

    /**
     * 触摸链最外层的取证点（2026-11-19 滚动粘滞）。
     *
     * <p>这一层看到的是 Flutter 转发下来的**原样**事件：是 UP 还是 CANCEL、时间戳有没有
     * 退化、MOVE 之间隔多久。`onFling` 收不到的原因只可能在这条链上，往上再猜没有意义。
     * 顺带做两件正事：DOWN 时清采样、停掉上一次惯性；抬手（UP 或 CANCEL）时若原生
     * fling 一次都没跑过，就用手上的样本自己补一次。
     */
    @Override
    public boolean dispatchTouchEvent(MotionEvent event) {
        final int action = event.getActionMasked();
        if (action == MotionEvent.ACTION_DOWN) {
            mTouchSampleCount = 0;
            mNativeFlingRan = false;
            mScroller.forceFinished(true);
            mFlinging = false;
            mReleaseTracker.clear();
        }
        sampleTouch(event);
        try {
            mReleaseTracker.addMovement(event);
        } catch (Throwable ignored) {
        }
        final boolean handled = super.dispatchTouchEvent(event);
        if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
            // 选择模式下抬手同样不点火：那一段手指移动属于选择，不是滚动。
            if (!isSelectingText()) maybeFlingFromRawSamples(event);
            // 上面若点了惯性，startFling 已经把零头并进整行，这里等于空转；
            // 没点惯性就是"停手了"，把不足一行的部分缓回 0，静止状态严格整行。
            settleScrollPixels();
            mTouchSampleCount = 0;
        }
        return handled;
    }

    @SuppressLint("ClickableViewAccessibility")
    @Override
    @TargetApi(23)
    public boolean onTouchEvent(MotionEvent event) {
        if (mEmulator == null) return true;
        final int action = event.getAction();

        if (isSelectingText()) {
            updateFloatingToolbarVisibility(event);
            mGestureRecognizer.onTouchEvent(event);
            return true;
        } else if (event.isFromSource(InputDevice.SOURCE_MOUSE)) {
            if (event.isButtonPressed(MotionEvent.BUTTON_SECONDARY)) {
                if (action == MotionEvent.ACTION_DOWN) showContextMenu();
                return true;
            } else if (event.isButtonPressed(MotionEvent.BUTTON_TERTIARY)) {
                ClipboardManager clipboardManager = (ClipboardManager) getContext().getSystemService(Context.CLIPBOARD_SERVICE);
                ClipData clipData = clipboardManager.getPrimaryClip();
                if (clipData != null) {
                    ClipData.Item clipItem = clipData.getItemAt(0);
                    if (clipItem != null) {
                        CharSequence text = clipItem.coerceToText(getContext());
                        if (!TextUtils.isEmpty(text)) mEmulator.paste(text.toString());
                    }
                }
            } else if (mEmulator.isMouseTrackingActive()) { // BUTTON_PRIMARY.
                switch (event.getAction()) {
                    case MotionEvent.ACTION_DOWN:
                    case MotionEvent.ACTION_UP:
                        sendMouseEventCode(event, TerminalEmulator.MOUSE_LEFT_BUTTON, event.getAction() == MotionEvent.ACTION_DOWN);
                        break;
                    case MotionEvent.ACTION_MOVE:
                        sendMouseEventCode(event, TerminalEmulator.MOUSE_LEFT_BUTTON_MOVED, true);
                        break;
                }
            }
        }

        mGestureRecognizer.onTouchEvent(event);
        return true;
    }

    @Override
    public boolean onKeyPreIme(int keyCode, KeyEvent event) {
        if (TERMINAL_VIEW_KEY_LOGGING_ENABLED)
            mClient.logInfo(LOG_TAG, "onKeyPreIme(keyCode=" + keyCode + ", event=" + event + ")");
        if (keyCode == KeyEvent.KEYCODE_BACK) {
            cancelRequestAutoFill();
            if (isSelectingText()) {
                stopTextSelectionMode();
                return true;
            } else if (mClient.shouldBackButtonBeMappedToEscape()) {
                // Intercept back button to treat it as escape:
                switch (event.getAction()) {
                    case KeyEvent.ACTION_DOWN:
                        return onKeyDown(keyCode, event);
                    case KeyEvent.ACTION_UP:
                        return onKeyUp(keyCode, event);
                }
            }
        } else if (mClient.shouldUseCtrlSpaceWorkaround() &&
                   keyCode == KeyEvent.KEYCODE_SPACE && event.isCtrlPressed()) {
            /* ctrl+space does not work on some ROMs without this workaround.
               However, this breaks it on devices where it works out of the box. */
            return onKeyDown(keyCode, event);
        }
        return super.onKeyPreIme(keyCode, event);
    }

    /**
     * Key presses in software keyboards will generally NOT trigger this listener, although some
     * may elect to do so in some situations. Do not rely on this to catch software key presses.
     * Gboard calls this when shouldEnforceCharBasedInput() is disabled (InputType.TYPE_NULL) instead
     * of calling commitText(), with deviceId=-1. However, Hacker's Keyboard, OpenBoard, LG Keyboard
     * call commitText().
     *
     * This function may also be called directly without android calling it, like by
     * `TerminalExtraKeys` which generates a KeyEvent manually which uses {@link KeyCharacterMap#VIRTUAL_KEYBOARD}
     * as the device (deviceId=-1), as does Gboard. That would normally use mappings defined in
     * `/system/usr/keychars/Virtual.kcm`. You can run `dumpsys input` to find the `KeyCharacterMapFile`
     * used by virtual keyboard or hardware keyboard. Note that virtual keyboard device is not the
     * same as software keyboard, like Gboard, etc. Its a fake device used for generating events and
     * for testing.
     *
     * We handle shift key in `commitText()` to convert codepoint to uppercase case there with a
     * call to {@link Character#toUpperCase(int)}, but here we instead rely on getUnicodeChar() for
     * conversion of keyCode, for both hardware keyboard shift key (via effectiveMetaState) and
     * `mClient.readShiftKey()`, based on value in kcm files.
     * This may result in different behaviour depending on keyboard and android kcm files set for the
     * InputDevice for the event passed to this function. This will likely be an issue for non-english
     * languages since `Virtual.kcm` in english only by default or at least in AOSP. For both hardware
     * shift key (via effectiveMetaState) and `mClient.readShiftKey()`, `getUnicodeChar()` is used
     * for shift specific behaviour which usually is to uppercase.
     *
     * For fn key on hardware keyboard, android checks kcm files for hardware keyboards, which is
     * `Generic.kcm` by default, unless a vendor specific one is defined. The event passed will have
     * {@link KeyEvent#META_FUNCTION_ON} set. If the kcm file only defines a single character or unicode
     * code point `\\uxxxx`, then only one event is passed with that value. However, if kcm defines
     * a `fallback` key for fn or others, like `key DPAD_UP { ... fn: fallback PAGE_UP }`, then
     * android will first pass an event with original key `DPAD_UP` and {@link KeyEvent#META_FUNCTION_ON}
     * set. But this function will not consume it and android will pass another event with `PAGE_UP`
     * and {@link KeyEvent#META_FUNCTION_ON} not set, which will be consumed.
     *
     * Now there are some other issues as well, firstly ctrl and alt flags are not passed to
     * `getUnicodeChar()`, so modified key values in kcm are not used. Secondly, if the kcm file
     * for other modifiers like shift or fn define a non-alphabet, like { fn: '\u0015' } to act as
     * DPAD_LEFT, the `getUnicodeChar()` will correctly return `21` as the code point but action will
     * not happen because the `handleKeyCode()` function that transforms DPAD_LEFT to `\033[D`
     * escape sequence for the terminal to perform the left action would not be called since its
     * called before `getUnicodeChar()` and terminal will instead get `21 0x15 Negative Acknowledgement`.
     * The solution to such issues is calling `getUnicodeChar()` before the call to `handleKeyCode()`
     * if user has defined a custom kcm file, like done in POC mentioned in #2237. Note that
     * Hacker's Keyboard calls `commitText()` so don't test fn/shift with it for this function.
     * https://github.com/termux/termux-app/pull/2237
     * https://github.com/agnostic-apollo/termux-app/blob/terminal-code-point-custom-mapping/terminal-view/src/main/java/com/termux/view/TerminalView.java
     *
     * Key Character Map (kcm) and Key Layout (kl) files info:
     * https://source.android.com/devices/input/key-character-map-files
     * https://source.android.com/devices/input/key-layout-files
     * https://source.android.com/devices/input/keyboard-devices
     * AOSP kcm and kl files:
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/base/data/keyboards
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/base/packages/InputDevices/res/raw
     *
     * KeyCodes:
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/base/core/java/android/view/KeyEvent.java
     * https://cs.android.com/android/platform/superproject/+/master:frameworks/native/include/android/keycodes.h
     *
     * `dumpsys input`:
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/native/services/inputflinger/reader/EventHub.cpp;l=1917
     *
     * Loading of keymap:
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/native/services/inputflinger/reader/EventHub.cpp;l=1644
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/native/libs/input/Keyboard.cpp;l=41
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/native/libs/input/InputDevice.cpp
     * OVERLAY keymaps for hardware keyboards may be combined as well:
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/native/libs/input/KeyCharacterMap.cpp;l=165
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/native/libs/input/KeyCharacterMap.cpp;l=831
     *
     * Parse kcm file:
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/native/libs/input/KeyCharacterMap.cpp;l=727
     * Parse key value:
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/native/libs/input/KeyCharacterMap.cpp;l=981
     *
     * `KeyEvent.getUnicodeChar()`
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/base/core/java/android/view/KeyEvent.java;l=2716
     * https://cs.android.com/android/platform/superproject/+/master:frameworks/base/core/java/android/view/KeyCharacterMap.java;l=368
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/base/core/jni/android_view_KeyCharacterMap.cpp;l=117
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/native/libs/input/KeyCharacterMap.cpp;l=231
     *
     * Keyboard layouts advertised by applications, like for hardware keyboards via #ACTION_QUERY_KEYBOARD_LAYOUTS
     * Config is stored in `/data/system/input-manager-state.xml`
     * https://github.com/ris58h/custom-keyboard-layout
     * Loading from apps:
     * https://cs.android.com/android/platform/superproject/+/master:frameworks/base/services/core/java/com/android/server/input/InputManagerService.java;l=1221
     * Set:
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/base/core/java/android/hardware/input/InputManager.java;l=89
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/base/core/java/android/hardware/input/InputManager.java;l=543
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:packages/apps/Settings/src/com/android/settings/inputmethod/KeyboardLayoutDialogFragment.java;l=167
     * https://cs.android.com/android/platform/superproject/+/master:frameworks/base/services/core/java/com/android/server/input/InputManagerService.java;l=1385
     * https://cs.android.com/android/platform/superproject/+/master:frameworks/base/services/core/java/com/android/server/input/PersistentDataStore.java
     * Get overlay keyboard layout
     * https://cs.android.com/android/platform/superproject/+/master:frameworks/base/services/core/java/com/android/server/input/InputManagerService.java;l=2158
     * https://cs.android.com/android/platform/superproject/+/android-11.0.0_r40:frameworks/base/services/core/jni/com_android_server_input_InputManagerService.cpp;l=616
     */
    /**
     * DSH: 按键到底有没有进到这个视图 —— 这一行是「事件没到 / 被吃掉 / 焦点被抢」三个假设的分水岭。
     * 只在日志开关打开时才打。
     */
    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        if (TERMINAL_VIEW_KEY_LOGGING_ENABLED && mClient != null && mEmulator != null)
            mClient.logInfo(LOG_TAG, "dispatchKeyEvent(" + event + ")");
        if (event.getAction() == KeyEvent.ACTION_DOWN) {
            mDownAt.put(event.getKeyCode(), SystemClock.uptimeMillis());
        }
        return super.dispatchKeyEvent(event);
    }

    /**
     * 抬起时这个键是不是"没有配对的孤儿"——DOWN 被上层吃掉了。
     *
     * 判据是记账不是时间窗：这个 keyCode 名下有未超时的 DOWN 记录才算有配对，查到即销账
     * （一次 DOWN 只抵一次 UP）。注意这个过程**有副作用**，一次抬起只能问一次。
     */
    private boolean isOrphanKeyUp(int keyCode) {
        long at = mDownAt.get(keyCode, -1L);
        if (at < 0) return true;
        mDownAt.delete(keyCode);
        return SystemClock.uptimeMillis() - at > DOWN_STALE_MS;
    }

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (TERMINAL_VIEW_KEY_LOGGING_ENABLED)
            mClient.logInfo(LOG_TAG, "onKeyDown(keyCode=" + keyCode + ", isSystem()=" + event.isSystem() + ", event=" + event + ")");
        if (mEmulator == null) return true;
        if (isSelectingText()) {
            stopTextSelectionMode();
        }

        if (mClient.onKeyDown(keyCode, event, mTermSession)) {
            invalidate();
            return true;
        } else if (event.isSystem() && (!mClient.shouldBackButtonBeMappedToEscape() || keyCode != KeyEvent.KEYCODE_BACK)) {
            return super.onKeyDown(keyCode, event);
        } else if (event.getAction() == KeyEvent.ACTION_MULTIPLE && keyCode == KeyEvent.KEYCODE_UNKNOWN) {
            mTermSession.write(event.getCharacters());
            return true;
        } else if (keyCode == KeyEvent.KEYCODE_LANGUAGE_SWITCH) {
            return super.onKeyDown(keyCode, event);
        }

        final int metaState = event.getMetaState();
        final boolean controlDown = event.isCtrlPressed() || mClient.readControlKey();
        final boolean leftAltDown = (metaState & KeyEvent.META_ALT_LEFT_ON) != 0 || mClient.readAltKey();
        final boolean shiftDown = event.isShiftPressed() || mClient.readShiftKey();
        final boolean rightAltDownFromEvent = (metaState & KeyEvent.META_ALT_RIGHT_ON) != 0;

        int keyMod = 0;
        if (controlDown) keyMod |= KeyHandler.KEYMOD_CTRL;
        if (event.isAltPressed() || leftAltDown) keyMod |= KeyHandler.KEYMOD_ALT;
        if (shiftDown) keyMod |= KeyHandler.KEYMOD_SHIFT;
        if (event.isNumLockOn()) keyMod |= KeyHandler.KEYMOD_NUM_LOCK;
        // https://github.com/termux/termux-app/issues/731
        if (!event.isFunctionPressed() && handleKeyCode(keyCode, keyMod)) {
            trackImeCaretForKey(keyCode);
            if (TERMINAL_VIEW_KEY_LOGGING_ENABLED) mClient.logInfo(LOG_TAG, "handleKeyCode() took key event");
            return true;
        }

        // Clear Ctrl since we handle that ourselves:
        int bitsToClear = KeyEvent.META_CTRL_MASK;
        if (rightAltDownFromEvent) {
            // Let right Alt/Alt Gr be used to compose characters.
        } else {
            // Use left alt to send to terminal (e.g. Left Alt+B to jump back a word), so remove:
            bitsToClear |= KeyEvent.META_ALT_ON | KeyEvent.META_ALT_LEFT_ON;
        }
        int effectiveMetaState = event.getMetaState() & ~bitsToClear;

        if (shiftDown) effectiveMetaState |= KeyEvent.META_SHIFT_ON | KeyEvent.META_SHIFT_LEFT_ON;
        if (mClient.readFnKey()) effectiveMetaState |= KeyEvent.META_FUNCTION_ON;

        int result = event.getUnicodeChar(effectiveMetaState);
        if (TERMINAL_VIEW_KEY_LOGGING_ENABLED)
            mClient.logInfo(LOG_TAG, "KeyEvent#getUnicodeChar(" + effectiveMetaState + ") returned: " + result);
        if (result == 0) {
            return false;
        }

        int oldCombiningAccent = mCombiningAccent;
        if ((result & KeyCharacterMap.COMBINING_ACCENT) != 0) {
            // If entered combining accent previously, write it out:
            if (mCombiningAccent != 0)
                inputCodePoint(event.getDeviceId(), mCombiningAccent, controlDown, leftAltDown);
            mCombiningAccent = result & KeyCharacterMap.COMBINING_ACCENT_MASK;
        } else {
            if (mCombiningAccent != 0) {
                int combinedChar = KeyCharacterMap.getDeadChar(mCombiningAccent, result);
                if (combinedChar > 0) result = combinedChar;
                mCombiningAccent = 0;
            }
            inputCodePoint(event.getDeviceId(), result, controlDown, leftAltDown);
        }

        if (mCombiningAccent != oldCombiningAccent) invalidate();

        return true;
    }

    public void inputCodePoint(int eventSource, int codePoint, boolean controlDownFromEvent, boolean leftAltDownFromEvent) {
        if (TERMINAL_VIEW_KEY_LOGGING_ENABLED) {
            mClient.logInfo(LOG_TAG, "inputCodePoint(eventSource=" + eventSource + ", codePoint=" + codePoint + ", controlDownFromEvent=" + controlDownFromEvent + ", leftAltDownFromEvent="
                + leftAltDownFromEvent + ")");
        }

        if (mTermSession == null) return;

        // Ensure cursor is shown when a key is pressed down like long hold on (arrow) keys
        if (mEmulator != null)
            mEmulator.setCursorBlinkState(true);

        final boolean controlDown = controlDownFromEvent || mClient.readControlKey();
        final boolean altDown = leftAltDownFromEvent || mClient.readAltKey();

        if (mClient.onCodePoint(codePoint, controlDown, mTermSession)) return;

        if (controlDown) {
            if (codePoint >= 'a' && codePoint <= 'z') {
                codePoint = codePoint - 'a' + 1;
            } else if (codePoint >= 'A' && codePoint <= 'Z') {
                codePoint = codePoint - 'A' + 1;
            } else if (codePoint == ' ' || codePoint == '2') {
                codePoint = 0;
            } else if (codePoint == '[' || codePoint == '3') {
                codePoint = 27; // ^[ (Esc)
            } else if (codePoint == '\\' || codePoint == '4') {
                codePoint = 28;
            } else if (codePoint == ']' || codePoint == '5') {
                codePoint = 29;
            } else if (codePoint == '^' || codePoint == '6') {
                codePoint = 30; // control-^
            } else if (codePoint == '_' || codePoint == '7' || codePoint == '/') {
                // "Ctrl-/ sends 0x1f which is equivalent of Ctrl-_ since the days of VT102"
                // - http://apple.stackexchange.com/questions/24261/how-do-i-send-c-that-is-control-slash-to-the-terminal
                codePoint = 31;
            } else if (codePoint == '8') {
                codePoint = 127; // DEL
            }
        }

        if (codePoint > -1) {
            // If not virtual or soft keyboard.
            if (eventSource > KEY_EVENT_SOURCE_SOFT_KEYBOARD) {
                // Work around bluetooth keyboards sending funny unicode characters instead
                // of the more normal ones from ASCII that terminal programs expect - the
                // desire to input the original characters should be low.
                switch (codePoint) {
                    case 0x02DC: // SMALL TILDE.
                        codePoint = 0x007E; // TILDE (~).
                        break;
                    case 0x02CB: // MODIFIER LETTER GRAVE ACCENT.
                        codePoint = 0x0060; // GRAVE ACCENT (`).
                        break;
                    case 0x02C6: // MODIFIER LETTER CIRCUMFLEX ACCENT.
                        codePoint = 0x005E; // CIRCUMFLEX ACCENT (^).
                        break;
                }
            }

            // If left alt, send escape before the code point to make e.g. Alt+B and Alt+F work in readline:
            mTermSession.writeCodePoint(altDown, codePoint);
        }
    }

    /** Input the specified keyCode if applicable and return if the input was consumed. */
    public boolean handleKeyCode(int keyCode, int keyMod) {
        // Ensure cursor is shown when a key is pressed down like long hold on (arrow) keys
        if (mEmulator != null)
            mEmulator.setCursorBlinkState(true);

        if (handleKeyCodeAction(keyCode, keyMod))
            return true;

        TerminalEmulator term = mTermSession.getEmulator();
        String code = KeyHandler.getCode(keyCode, keyMod, term.isCursorKeysApplicationMode(), term.isKeypadApplicationMode());
        if (code == null) return false;
        mTermSession.write(code);
        return true;
    }

    public boolean handleKeyCodeAction(int keyCode, int keyMod) {
        boolean shiftDown = (keyMod & KeyHandler.KEYMOD_SHIFT) != 0;

        switch (keyCode) {
            case KeyEvent.KEYCODE_PAGE_UP:
            case KeyEvent.KEYCODE_PAGE_DOWN:
                // shift+page_up and shift+page_down should scroll scrollback history instead of
                // scrolling command history or changing pages
                if (shiftDown) {
                    long time = SystemClock.uptimeMillis();
                    MotionEvent motionEvent = MotionEvent.obtain(time, time, MotionEvent.ACTION_DOWN, 0, 0, 0);
                    doScroll(motionEvent, keyCode == KeyEvent.KEYCODE_PAGE_UP ? -mEmulator.mRows : mEmulator.mRows);
                    motionEvent.recycle();
                    return true;
                }
        }

       return false;
    }

    /**
     * Called when a key is released in the view.
     *
     * @param keyCode The keycode of the key which was released.
     * @param event   A {@link KeyEvent} describing the event.
     * @return Whether the event was handled.
     */
    @Override
    public boolean onKeyUp(int keyCode, KeyEvent event) {
        if (TERMINAL_VIEW_KEY_LOGGING_ENABLED)
            mClient.logInfo(LOG_TAG, "onKeyUp(keyCode=" + keyCode + ", event=" + event + ")");

        // DSH S2e：在这个平台视图里，方向键的 ACTION_DOWN 会被 Flutter 的 Dart 侧先吃掉
        // （FlutterView.dispatchKeyEvent 先问 Dart，方向键是那套焦点遍历的快捷键），
        // 只有 ACTION_UP 漏下来 —— 所以 onKeyDown 一次都没被调用过。孤儿 UP 在这里补一次。
        final boolean orphan = isOrphanKeyUp(keyCode);   // 有副作用，一次抬起只问一次
        if (mEmulator != null && mClient != null && orphan) {
            int keyMod = 0;
            if (event.isCtrlPressed() || mClient.readControlKey()) keyMod |= KeyHandler.KEYMOD_CTRL;
            if (event.isShiftPressed() || mClient.readShiftKey()) keyMod |= KeyHandler.KEYMOD_SHIFT;
            final boolean handled = handleKeyCode(keyCode, keyMod);
            if (handled) {
                trackImeCaretForKey(keyCode);
                if (TERMINAL_VIEW_KEY_LOGGING_ENABLED)
                    mClient.logInfo(LOG_TAG, "orphan UP handled, keyCode=" + keyCode);
                invalidate();
                return true;
            }
        }

        // Do not return for KEYCODE_BACK and send it to the client since user may be trying
        // to exit the activity.
        if (mEmulator == null && keyCode != KeyEvent.KEYCODE_BACK) return true;

        if (mClient.onKeyUp(keyCode, event)) {
            invalidate();
            return true;
        } else if (event.isSystem()) {
            // Let system key events through.
            return super.onKeyUp(keyCode, event);
        }

        return true;
    }

    /**
     * DSH 取证用：焦点是"光标卡住"的头号嫌疑。
     *
     * 平台视图一旦丢焦点，方向键的 DOWN 会被 Dart 的焦点遍历吃掉、UP 也不再派发到这里，
     * 手势期间的事件整段消失——手感就是拖动没反应、过一会儿自己恢复。这两行把那个瞬间
     * 钉在时间轴上，跟 keyup 的间隙对齐就能判死。
     */
    @Override
    protected void onFocusChanged(boolean gainFocus, int direction, android.graphics.Rect previouslyFocusedRect) {
        super.onFocusChanged(gainFocus, direction, previouslyFocusedRect);
    }

    @Override
    public void onWindowFocusChanged(boolean hasWindowFocus) {
        super.onWindowFocusChanged(hasWindowFocus);
    }

    /**
     * This is called during layout when the size of this view has changed. If you were just added to the view
     * hierarchy, you're called with the old values of 0.
     */
    @Override
    protected void onSizeChanged(int w, int h, int oldw, int oldh) {
        updateSize();
    }

    /** Check if the terminal size in rows and columns should be updated. */
    public void updateSize() {
        int viewWidth = getWidth() - 2 * mSideInsetPx;
        int viewHeight = getHeight();
        if (viewWidth == 0 || viewHeight == 0 || mTermSession == null) return;

        // Set to 80 and 24 if you want to enable vttest.
        int newColumns = Math.max(4, (int) (viewWidth / mRenderer.mFontWidth));
        int newRows = Math.max(4, (viewHeight - mRenderer.mFontLineSpacingAndAscent) / mRenderer.mFontLineSpacing);

        if (mEmulator == null || (newColumns != mEmulator.mColumns || newRows != mEmulator.mRows)) {
            mTermSession.updateSize(newColumns, newRows, (int) mRenderer.getFontWidth(), mRenderer.getFontLineSpacing());
            mEmulator = mTermSession.getEmulator();
            applyPalette();
            mClient.onEmulatorSet();

            // Update mTerminalCursorBlinkerRunnable inner class mEmulator on session change
            if (mTerminalCursorBlinkerRunnable != null)
                mTerminalCursorBlinkerRunnable.setEmulator(mEmulator);

            // Restore cached top row value if session/emulator was switched back from a
            // different session or after activity restart. The top row value also needs to be
            // maintained after opening/closing soft keyboard.
            int topRow = 0;
            if (mEmulator != null) {
                int rowsInHistory = mEmulator.getScreen().getActiveTranscriptRows();
                int cachedTopRow = mEmulator.getTopRow();
                if (cachedTopRow >= -rowsInHistory) {
                    topRow = cachedTopRow;
                }
            }
            setTopRow(topRow);

            scrollTo(0, 0);
            invalidate();
        }
    }

    @Override
    protected void onDraw(Canvas canvas) {
        Runnable drawProbe = mDrawProbe;
        if (drawProbe != null) drawProbe.run();
        if (mEmulator == null) {
            canvas.drawColor(0XFF000000);
        } else {
            // render the terminal view and highlight any selected text
            int[] sel = mDefaultSelectors;
            if (mTextSelectionCursorController != null) {
                mTextSelectionCursorController.getSelectors(sel);
            }

            final int inset = mSideInsetPx;
            if (inset > 0) canvas.translate(inset, 0);
            // sub-row：整块内容按像素平移；底部那条空白多画一行补上。
            final int pixelShift = mScrollPixels;
            if (pixelShift != 0) canvas.translate(0, -pixelShift);
            mRenderer.render(mEmulator, canvas, mTopRow, sel[0], sel[1], sel[2], sel[3],
                pixelShift != 0 ? 1 : 0);
            // 复原后再画选择手柄和顶部羽化：羽化要钉在屏幕顶上，不能跟着内容走。
            if (pixelShift != 0) canvas.translate(0, pixelShift);

            // render the text selection handles
            renderTextSelection();
            if (inset > 0) canvas.translate(-inset, 0);

            drawTopVeil(canvas);
        }
    }

    /** T22: 用终端默认背景色把顶部一条带子盖住，末段羽化，效果等同页面里的 TopFade。 */
    private void drawTopVeil(Canvas canvas) {
        final int total = mVeilSolidPx + mVeilFeatherPx;
        if (total <= 0 || mEmulator == null) return;
        // 颜色优先用宿主下发的调色板：模拟器的色表要等它建出来才写进去，
        // 而宿主给的值一定在。没下发过才退回模拟器当前背景色。
        final int bg = mHasPalette
                ? mPaletteBg
                : mEmulator.mColors.mCurrentColors[TextStyle.COLOR_INDEX_BACKGROUND];
        final int clear = bg & 0x00FFFFFF;
        // 纯羽化（solid = 0）给两个色标就够。三个色标里前两个位置相同是退化情形，
        // 某些实现会把它画成"什么都没画"——那看起来就是"没淡出"。
        if (mVeilSolidPx <= 0) {
            mVeilPaint.setShader(new LinearGradient(0, 0, 0, total,
                    new int[]{bg, clear}, new float[]{0f, 1f}, Shader.TileMode.CLAMP));
        } else {
            mVeilPaint.setShader(new LinearGradient(0, 0, 0, total,
                    new int[]{bg, bg, clear},
                    new float[]{0f, (float) mVeilSolidPx / total, 1f},
                    Shader.TileMode.CLAMP));
        }
        canvas.drawRect(0, 0, getWidth(), total, mVeilPaint);
        mVeilPaint.setShader(null);
    }

    public TerminalSession getCurrentSession() {
        return mTermSession;
    }

    private CharSequence getText() {
        return mEmulator.getScreen().getSelectedText(0, mTopRow, mEmulator.mColumns, mTopRow + mEmulator.mRows);
    }

    public int getCursorX(float x) {
        return (int) (x / mRenderer.mFontWidth);
    }

    public int getCursorY(float y) {
        // + mScrollPixels：内容向上平移了这么多，屏幕上的 y 要加回去才是内容坐标。
        return (int) (((y + mScrollPixels - 40) / mRenderer.mFontLineSpacing) + mTopRow);
    }

    /**
     * 列 → 像素。**含侧边留白。**
     *
     * <p>2026-11-18：手柄错位的根在这儿。文字在 onDraw 里是
     * `canvas.translate(mSideInsetPx, 0)` 之后画的——也就是每行从 inset 开始；
     * 而这里原来只算 `col × 字宽`，没加 inset。于是手柄整体比文字左移了 inset 那么多，
     * 越靠右差得越多，看起来就是"手柄和选中区域对不上"。
     *
     * <p>这个方法只有选择手柄在用（`TextSelectionHandleView.positionAtCursor`），
     * 所以在这里补 inset 不会影响别的绘制。
     */
    public int getPointX(int cx) {
        if (cx > mEmulator.mColumns) {
            cx = mEmulator.mColumns;
        }
        return Math.round(cx * mRenderer.mFontWidth) + mSideInsetPx;
    }

    public int getPointY(int cy) {
        return Math.round((cy - mTopRow) * mRenderer.mFontLineSpacing) - mScrollPixels;
    }

    public int getTopRow() {
        return mTopRow;
    }

    public void setTopRow(int topRow) {
        setTopRow(topRow, true);
    }

    public void setTopRow(int topRow, boolean updateEmulator) {
        mTopRow = topRow;
        if (updateEmulator && mEmulator != null) {
            mEmulator.setTopRow(mTopRow);
        }
    }



    /**
     * Define functions required for AutoFill API
     */
    @RequiresApi(api = Build.VERSION_CODES.O)
    @Override
    public void autofill(AutofillValue value) {
        if (value.isText()) {
            mTermSession.write(value.getTextValue().toString());
        }

        resetAutoFill();
    }

    @RequiresApi(api = Build.VERSION_CODES.O)
    @Override
    public int getAutofillType() {
        return mAutoFillType;
    }

    @RequiresApi(api = Build.VERSION_CODES.O)
    @Override
    public String[] getAutofillHints() {
        return mAutoFillHints;
    }

    @RequiresApi(api = Build.VERSION_CODES.O)
    @Override
    public AutofillValue getAutofillValue() {
        return AutofillValue.forText("");
    }

    @RequiresApi(api = Build.VERSION_CODES.O)
    @Override
    public int getImportantForAutofill() {
        return mAutoFillImportance;
    }

    @RequiresApi(api = Build.VERSION_CODES.O)
    private synchronized void resetAutoFill() {
        // Restore none type so that AutoFill UI isn't shown anymore.
        mAutoFillType = AUTOFILL_TYPE_NONE;
        mAutoFillImportance = IMPORTANT_FOR_AUTOFILL_NO;
        mAutoFillHints = new String[0];
    }

    public AutofillManager getAutoFillManagerService() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null;

        try {
            Context context = getContext();
            if (context == null) return null;
            return context.getSystemService(AutofillManager.class);
        } catch (Exception e) {
            mClient.logStackTraceWithMessage(LOG_TAG, "Failed to get AutofillManager service", e);
            return null;
        }
    }

    public boolean isAutoFillEnabled() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false;

        try {
            AutofillManager autofillManager = getAutoFillManagerService();
            return autofillManager != null && autofillManager.isEnabled();
        } catch (Exception e) {
            mClient.logStackTraceWithMessage(LOG_TAG, "Failed to check if Autofill is enabled", e);
            return false;
        }
    }

    public synchronized void requestAutoFillUsername() {
        requestAutoFill(
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O ? new String[]{View.AUTOFILL_HINT_USERNAME} :
                null);
    }

    public synchronized void requestAutoFillPassword() {
        requestAutoFill(
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O ? new String[]{View.AUTOFILL_HINT_PASSWORD} :
            null);
    }

    public synchronized void requestAutoFill(String[] autoFillHints) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return;
        if (autoFillHints == null || autoFillHints.length < 1) return;

        try {
            AutofillManager autofillManager = getAutoFillManagerService();
            if (autofillManager != null && autofillManager.isEnabled()) {
                // Update type that will be returned by `getAutofillType()` so that AutoFill UI is shown.
                mAutoFillType = AUTOFILL_TYPE_TEXT;
                // Update importance that will be returned by `getImportantForAutofill()` so that
                // AutoFill considers the view as important.
                mAutoFillImportance = IMPORTANT_FOR_AUTOFILL_YES;
                // Update hints that will be returned by `getAutofillHints()` for which to show AutoFill UI.
                mAutoFillHints = autoFillHints;
                autofillManager.requestAutofill(this);
            }
        } catch (Exception e) {
            mClient.logStackTraceWithMessage(LOG_TAG, "Failed to request Autofill", e);
        }
    }

    public synchronized void cancelRequestAutoFill() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return;
        if (mAutoFillType == AUTOFILL_TYPE_NONE) return;

        try {
            AutofillManager autofillManager = getAutoFillManagerService();
            if (autofillManager != null && autofillManager.isEnabled()) {
                resetAutoFill();
                autofillManager.cancel();
            }
        } catch (Exception e) {
            mClient.logStackTraceWithMessage(LOG_TAG, "Failed to cancel Autofill request", e);
        }
    }





    /**
     * Set terminal cursor blinker rate. It must be between {@link #TERMINAL_CURSOR_BLINK_RATE_MIN}
     * and {@link #TERMINAL_CURSOR_BLINK_RATE_MAX}, otherwise it will be disabled.
     *
     * The {@link #setTerminalCursorBlinkerState(boolean, boolean)} must be called after this
     * for changes to take effect if not disabling.
     *
     * @param blinkRate The value to set.
     * @return Returns {@code true} if setting blinker rate was successfully set, otherwise [@code false}.
     */
    public synchronized boolean setTerminalCursorBlinkerRate(int blinkRate) {
        boolean result;

        // If cursor blinking rate is not valid
        if (blinkRate != 0 && (blinkRate < TERMINAL_CURSOR_BLINK_RATE_MIN || blinkRate > TERMINAL_CURSOR_BLINK_RATE_MAX)) {
            mClient.logError(LOG_TAG, "The cursor blink rate must be in between " + TERMINAL_CURSOR_BLINK_RATE_MIN + "-" + TERMINAL_CURSOR_BLINK_RATE_MAX + ": " + blinkRate);
            mTerminalCursorBlinkerRate = 0;
            result = false;
        } else {
            mClient.logVerbose(LOG_TAG, "Setting cursor blinker rate to " + blinkRate);
            mTerminalCursorBlinkerRate = blinkRate;
            result = true;
        }

        if (mTerminalCursorBlinkerRate == 0) {
            mClient.logVerbose(LOG_TAG, "Cursor blinker disabled");
            stopTerminalCursorBlinker();
        }

        return result;
    }

    /**
     * Sets whether cursor blinker should be started or stopped. Cursor blinker will only be
     * started if {@link #mTerminalCursorBlinkerRate} does not equal 0 and is between
     * {@link #TERMINAL_CURSOR_BLINK_RATE_MIN} and {@link #TERMINAL_CURSOR_BLINK_RATE_MAX}.
     *
     * This should be called when the view holding this activity is resumed or stopped so that
     * cursor blinker does not run when activity is not visible. If you call this on onResume()
     * to start cursor blinking, then ensure that {@link #mEmulator} is set, otherwise wait for the
     * {@link TerminalViewClient#onEmulatorSet()} event after calling {@link #attachSession(TerminalSession)}
     * for the first session added in the activity since blinking will not start if {@link #mEmulator}
     * is not set, like if activity is started again after exiting it with double back press. Do not
     * call this directly after {@link #attachSession(TerminalSession)} since {@link #updateSize()}
     * may return without setting {@link #mEmulator} since width/height may be 0. Its called again in
     * {@link #onSizeChanged(int, int, int, int)}. Calling on onResume() if emulator is already set
     * is necessary, since onEmulatorSet() may not be called after activity is started after device
     * display timeout with double tap and not power button.
     *
     * It should also be called on the
     * {@link com.termux.terminal.TerminalSessionClient#onTerminalCursorStateChange(boolean)}
     * callback when cursor is enabled or disabled so that blinker is disabled if cursor is not
     * to be shown. It should also be checked if activity is visible if blinker is to be started
     * before calling this.
     *
     * It should also be called after terminal is reset with {@link TerminalSession#reset()} in case
     * cursor blinker was disabled before reset due to call to
     * {@link com.termux.terminal.TerminalSessionClient#onTerminalCursorStateChange(boolean)}.
     *
     * How cursor blinker starting works is by registering a {@link Runnable} with the looper of
     * the main thread of the app which when run, toggles the cursor blinking state and re-registers
     * itself to be called with the delay set by {@link #mTerminalCursorBlinkerRate}. When cursor
     * blinking needs to be disabled, we just cancel any callbacks registered. We don't run our own
     * "thread" and let the thread for the main looper do the work for us, whose usage is also
     * required to update the UI, since it also handles other calls to update the UI as well based
     * on a queue.
     *
     * Note that when moving cursor in text editors like nano, the cursor state is quickly
     * toggled `-> off -> on`, which would call this very quickly sequentially. So that if cursor
     * is moved 2 or more times quickly, like long hold on arrow keys, it would trigger
     * `-> off -> on -> off -> on -> ...`, and the "on" callback at index 2 is automatically
     * cancelled by next "off" callback at index 3 before getting a chance to be run. For this case
     * we log only if {@link #TERMINAL_VIEW_KEY_LOGGING_ENABLED} is enabled, otherwise would clutter
     * the log. We don't start the blinking with a delay to immediately show cursor in case it was
     * previously not visible.
     *
     * @param start If cursor blinker should be started or stopped.
     * @param startOnlyIfCursorEnabled If set to {@code true}, then it will also be checked if the
     *                                 cursor is even enabled by {@link TerminalEmulator} before
     *                                 starting the cursor blinker.
     */
    public synchronized void setTerminalCursorBlinkerState(boolean start, boolean startOnlyIfCursorEnabled) {
        // Stop any existing cursor blinker callbacks
        stopTerminalCursorBlinker();

        if (mEmulator == null) return;

        mEmulator.setCursorBlinkingEnabled(false);

        if (start) {
            // If cursor blinker is not enabled or is not valid
            if (mTerminalCursorBlinkerRate < TERMINAL_CURSOR_BLINK_RATE_MIN || mTerminalCursorBlinkerRate > TERMINAL_CURSOR_BLINK_RATE_MAX)
                return;
            // If cursor blinder is to be started only if cursor is enabled
            else if (startOnlyIfCursorEnabled && ! mEmulator.isCursorEnabled()) {
                if (TERMINAL_VIEW_KEY_LOGGING_ENABLED)
                    mClient.logVerbose(LOG_TAG, "Ignoring call to start cursor blinker since cursor is not enabled");
                return;
            }

            // Start cursor blinker runnable
            if (TERMINAL_VIEW_KEY_LOGGING_ENABLED)
                mClient.logVerbose(LOG_TAG, "Starting cursor blinker with the blink rate " + mTerminalCursorBlinkerRate);
            if (mTerminalCursorBlinkerHandler == null)
                mTerminalCursorBlinkerHandler = new Handler(Looper.getMainLooper());
            mTerminalCursorBlinkerRunnable = new TerminalCursorBlinkerRunnable(mEmulator, mTerminalCursorBlinkerRate);
            mEmulator.setCursorBlinkingEnabled(true);
            mTerminalCursorBlinkerRunnable.run();
        }
    }

    /**
     * Cancel the terminal cursor blinker callbacks
     */
    private void stopTerminalCursorBlinker() {
        if (mTerminalCursorBlinkerHandler != null && mTerminalCursorBlinkerRunnable != null) {
            if (TERMINAL_VIEW_KEY_LOGGING_ENABLED)
                mClient.logVerbose(LOG_TAG, "Stopping cursor blinker");
            mTerminalCursorBlinkerHandler.removeCallbacks(mTerminalCursorBlinkerRunnable);
        }
    }

    private class TerminalCursorBlinkerRunnable implements Runnable {

        private TerminalEmulator mEmulator;
        private final int mBlinkRate;

        // Initialize with false so that initial blink state is visible after toggling
        boolean mCursorVisible = false;

        public TerminalCursorBlinkerRunnable(TerminalEmulator emulator, int blinkRate) {
            mEmulator = emulator;
            mBlinkRate = blinkRate;
        }

        public void setEmulator(TerminalEmulator emulator) {
            mEmulator = emulator;
        }

        public void run() {
            try {
                if (mEmulator != null) {
                    // Toggle the blink state and then invalidate() the view so
                    // that onDraw() is called, which then calls TerminalRenderer.render()
                    // which checks with TerminalEmulator.shouldCursorBeVisible() to decide whether
                    // to draw the cursor or not
                    mCursorVisible = !mCursorVisible;
                    //mClient.logVerbose(LOG_TAG, "Toggling cursor blink state to " + mCursorVisible);
                    mEmulator.setCursorBlinkState(mCursorVisible);
                    invalidate();
                }
            } finally {
                // Recall the Runnable after mBlinkRate milliseconds to toggle the blink state
                mTerminalCursorBlinkerHandler.postDelayed(this, mBlinkRate);
            }
        }
    }



    /**
     * Define functions required for text selection and its handles.
     */
    TextSelectionCursorController getTextSelectionCursorController() {
        if (mTextSelectionCursorController == null) {
            mTextSelectionCursorController = new TextSelectionCursorController(this);

            final ViewTreeObserver observer = getViewTreeObserver();
            if (observer != null) {
                observer.addOnTouchModeChangeListener(mTextSelectionCursorController);
            }
        }

        return mTextSelectionCursorController;
    }

    private void showTextSelectionCursors(MotionEvent event) {
        getTextSelectionCursorController().show(event);
    }

    private boolean hideTextSelectionCursors() {
        return getTextSelectionCursorController().hide();
    }

    private void renderTextSelection() {
        if (mTextSelectionCursorController != null)
            mTextSelectionCursorController.render();
    }

    public boolean isSelectingText() {
        if (mTextSelectionCursorController != null) {
            return mTextSelectionCursorController.isActive();
        } else {
            return false;
        }
    }

    /** Get the currently selected text if selecting. */
    public String getSelectedText() {
        if (isSelectingText() && mTextSelectionCursorController != null)
            return mTextSelectionCursorController.getSelectedText();
        else
            return null;
    }

    /** Get the selected text stored before "MORE" button was pressed on the context menu. */
    @Nullable
    public String getStoredSelectedText() {
        return mTextSelectionCursorController != null ? mTextSelectionCursorController.getStoredSelectedText() : null;
    }

    /** Unset the selected text stored before "MORE" button was pressed on the context menu. */
    public void unsetStoredSelectedText() {
        if (mTextSelectionCursorController != null) mTextSelectionCursorController.unsetStoredSelectedText();
    }

    private ActionMode getTextSelectionActionMode() {
        if (mTextSelectionCursorController != null) {
            return mTextSelectionCursorController.getActionMode();
        } else {
            return null;
        }
    }

    public void startTextSelectionMode(MotionEvent event) {
        if (!requestFocus()) {
            return;
        }

        showTextSelectionCursors(event);
        mClient.copyModeChanged(isSelectingText());

        invalidate();
    }

    public void stopTextSelectionMode() {
        if (hideTextSelectionCursors()) {
            mClient.copyModeChanged(isSelectingText());
            invalidate();
        }
    }

    private void decrementYTextSelectionCursors(int decrement) {
        if (mTextSelectionCursorController != null) {
            mTextSelectionCursorController.decrementYTextSelectionCursors(decrement);
        }
    }

    @Override
    protected void onAttachedToWindow() {
        super.onAttachedToWindow();

        if (mTextSelectionCursorController != null) {
            getViewTreeObserver().addOnTouchModeChangeListener(mTextSelectionCursorController);
        }
    }

    @Override
    protected void onDetachedFromWindow() {
        super.onDetachedFromWindow();

        if (mTextSelectionCursorController != null) {
            // Might solve the following exception
            // android.view.WindowLeaked: Activity com.termux.app.TermuxActivity has leaked window android.widget.PopupWindow
            stopTextSelectionMode();

            getViewTreeObserver().removeOnTouchModeChangeListener(mTextSelectionCursorController);
            mTextSelectionCursorController.onDetached();
        }
    }



    /**
     * Define functions required for long hold toolbar.
     */
    private final Runnable mShowFloatingToolbar = new Runnable() {
        @RequiresApi(api = Build.VERSION_CODES.M)
        @Override
        public void run() {
            if (getTextSelectionActionMode() != null) {
                getTextSelectionActionMode().hide(0);  // hide off.
            }
        }
    };

    @RequiresApi(api = Build.VERSION_CODES.M)
    private void showFloatingToolbar() {
        if (getTextSelectionActionMode() != null) {
            int delay = ViewConfiguration.getDoubleTapTimeout();
            postDelayed(mShowFloatingToolbar, delay);
        }
    }

    @RequiresApi(api = Build.VERSION_CODES.M)
    void hideFloatingToolbar() {
        if (getTextSelectionActionMode() != null) {
            removeCallbacks(mShowFloatingToolbar);
            getTextSelectionActionMode().hide(-1);
        }
    }

    public void updateFloatingToolbarVisibility(MotionEvent event) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && getTextSelectionActionMode() != null) {
            switch (event.getActionMasked()) {
                case MotionEvent.ACTION_MOVE:
                    hideFloatingToolbar();
                    break;
                case MotionEvent.ACTION_UP:  // fall through
                case MotionEvent.ACTION_CANCEL:
                    showFloatingToolbar();
            }
        }
    }

}
