package io.github.ccch1mneyyy.dsh_app.terminal

import android.content.Context
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * S2d 临时探针：把输入链路每一步写进 `filesDir/keyprobe.log`。
 *
 * 为什么走文件不走 logcat：logcat 要 adb 或 root shell 才取得出来，而
 * `/data/data/<pkg>/files/` 我在 MT MCP 这一侧直接读得到——装完按几下，
 * 证据自己落到盘上，不需要他手动跑任何命令。
 *
 * 入口只有一个：Termux 那边的 `TerminalView` 每条日志都走
 * [com.termux.view.TerminalViewClient.logInfo]，client 再转发到这里，
 * 所以被 vendored 的 Java 一行都不用碰。
 *
 * 定位完就把这个类和 client 里的转发一起删掉。
 */
internal object KeyProbe {

    private const val TAG = "DshKeyProbe"
    private const val FILE_NAME = "keyprobe.log"
    private const val MAX_BYTES = 256L * 1024

    private val stamp = SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.US)

    @Volatile
    private var file: File? = null

    fun init(context: Context) {
        if (file != null) return
        val dir = context.filesDir
        file = File(dir, FILE_NAME)
        runCatching {
            // 每次进程起来重来一份，避免旧日志把新现象埋了。
            file!!.writeText("")
        }
        write("probe start")
    }

    fun write(message: String) {
        Log.i(TAG, message)
        val f = file ?: return
        runCatching {
            if (f.length() > MAX_BYTES) f.writeText("")
            f.appendText(stamp.format(Date()) + " " + message + "\n")
        }
    }
}
