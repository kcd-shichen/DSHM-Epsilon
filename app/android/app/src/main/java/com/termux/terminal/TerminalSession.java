package com.termux.terminal;

import java.nio.charset.StandardCharsets;
import java.util.UUID;

/**
 * DSH 版 {@code TerminalSession} —— 只负责「终端视图 ↔ 字节」，不含进程。
 *
 * <p>上游同名类是 {@code final} 的，构造函数里直接 {@code JNI.createSubprocess()} 起 pty，
 * 并且 {@code JNI} 的静态块会 {@code System.loadLibrary("termux")}。dsh-go 的 pty 在
 * rootfs 那一侧（Dart 拿到 {@code attachment.frames}，写回用 {@code send(id, data)}），
 * 所以这一层在我们这里是多余的，把它整个拿掉，只留两根管子：
 *
 * <ul>
 *   <li><b>输出</b>：ss 端字节 → {@link #feed(byte[], int, int)} → {@link TerminalEmulator}</li>
 *   <li><b>输入</b>：视图按键 → {@link #write(byte[], int, int)} → {@link Client#onInput}</li>
 * </ul>
 *
 * <p>与上游保持同名同包，是为了让 {@code com.termux.view} 那半边<b>一个字都不用改</b>：
 * {@code TerminalView.mTermSession}、{@code attachSession()}、{@code TerminalViewClient}
 * 的签名全部照旧。裁剪面积因此只剩「删两个文件、加这一个」。
 */
public class TerminalSession extends TerminalOutput {

    /** 字节与视图事件的出口，由平台视图实现。 */
    public interface Client {

        /** 用户输入，需要送回 pty。 */
        void onInput(byte[] data, int offset, int count);

        /** 屏幕内容变了，宿主应当重绘。 */
        void onScreenUpdate();

        void onTitleChanged(String oldTitle, String newTitle);

        void onBell();

        void onCopyTextToClipboard(String text);

        void onPasteTextFromClipboard();
    }

    public final String mHandle = UUID.randomUUID().toString();

    private final Client mBridge;
    private final TerminalSessionClient mSessionClient;
    private final Integer mTranscriptRows;

    private TerminalEmulator mEmulator;
    private String mTitle = "";
    private int mShellPid;

    /**
     * @param transcriptRows 回滚行数，null 走 {@link TerminalEmulator} 的默认值
     * @param bridge         字节出口
     * @param sessionClient  上游那套 client（日志、光标样式、光标状态回调）
     */
    public TerminalSession(Integer transcriptRows, Client bridge, TerminalSessionClient sessionClient) {
        mTranscriptRows = transcriptRows;
        mBridge = bridge;
        mSessionClient = sessionClient;
    }

    public TerminalEmulator getEmulator() {
        return mEmulator;
    }

    /**
     * {@code TerminalView.updateSize()} 在每次布局时调用。上游在这里同时改 pty 窗口大小，
     * 我们只改模拟器；pty 的 resize 由 Dart 侧按同一组行列数单独发。
     */
    public void updateSize(int columns, int rows, int cellWidth, int cellHeight) {
        if (mEmulator == null) {
            mEmulator = new TerminalEmulator(this, columns, rows, cellWidth, cellHeight, mTranscriptRows, mSessionClient);
        } else if (columns != mEmulator.mColumns || rows != mEmulator.mRows) {
            mEmulator.resize(columns, rows, cellWidth, cellHeight);
        }
    }

    /** 服务端字节入口。模拟器还没建（视图未测量）时直接丢弃，历史上这些字节本来也没地方放。 */
    public void feed(byte[] data, int offset, int count) {
        if (mEmulator == null || data == null || count <= 0) return;
        if (offset == 0 && count == data.length) {
            mEmulator.append(data, count);
        } else {
            byte[] slice = new byte[count];
            System.arraycopy(data, offset, slice, 0, count);
            mEmulator.append(slice, count);
        }
        if (mSessionClient != null) mSessionClient.onTextChanged(this);
        mBridge.onScreenUpdate();
    }

    public void feed(String text) {
        if (text == null) return;
        byte[] bytes = text.getBytes(StandardCharsets.UTF_8);
        feed(bytes, 0, bytes.length);
    }

    // ---- 输入：视图 → pty ----

    @Override
    public void write(byte[] data, int offset, int count) {
        if (mBridge == null || data == null || count <= 0) return;
        mBridge.onInput(data, offset, count);
    }

    public void writeCodePoint(boolean prependEscape, int codePoint) {
        if (codePoint > 0x10FFFF) return;
        byte[] text = new String(Character.toChars(codePoint)).getBytes(StandardCharsets.UTF_8);
        byte[] out = new byte[text.length + (prependEscape ? 1 : 0)];
        if (prependEscape) out[0] = 0x1b;
        System.arraycopy(text, 0, out, prependEscape ? 1 : 0, text.length);
        write(out, 0, out.length);
    }

    // ---- TerminalOutput：模拟器 → 我们 ----

    @Override
    public void titleChanged(String oldTitle, String newTitle) {
        mTitle = newTitle == null ? "" : newTitle;
        if (mBridge != null) mBridge.onTitleChanged(oldTitle, mTitle);
    }

    @Override
    public void onCopyTextToClipboard(String text) {
        if (mBridge != null) mBridge.onCopyTextToClipboard(text);
    }

    @Override
    public void onPasteTextFromClipboard() {
        if (mBridge != null) mBridge.onPasteTextFromClipboard();
    }

    @Override
    public void onBell() {
        if (mBridge != null) mBridge.onBell();
    }

    @Override
    public void onColorsChanged() {
        // 上游在这里通知宿主重新取色。我们的主题由 Dart 侧给，不需要回调。
    }

    // ---- 视图会问的其余状态 ----

    public String getTitle() {
        return mTitle;
    }

    public boolean isRunning() {
        return true;
    }

    public void reset() {
        if (mEmulator != null) mEmulator.reset();
    }

    public void finishIfRunning() {
        // 没有子进程可杀。
    }

    public int getShellPid() {
        return mShellPid;
    }

    public void setShellPid(int pid) {
        mShellPid = pid;
    }
}
