package com.bynux.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.graphics.drawable.Icon
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import android.util.Rational
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {
    private var attachedEngine: FlutterEngine? = null
    private var system: BayanSystem? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        attachedEngine = flutterEngine
        val bridge = BayanPythonBridge.get(applicationContext)
        bridge.attach(flutterEngine)
        bridge.bindActivity(this)
        system = BayanSystem(applicationContext).also { it.attach(flutterEngine) }
    }

    override fun onResume() {
        super.onResume()
        val bridge = BayanPythonBridge.get(applicationContext)
        bridge.bindActivity(this)
        bridge.syncPipState(this)
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        BayanPythonBridge.get(applicationContext).onUserLeave(this)
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        BayanPythonBridge.get(applicationContext).onPipModeChanged(this, isInPictureInPictureMode)
    }

    // الواجهة وحدها تنفصل هنا. السكربتات الشغّالة لا تتوقف: الجسر يعيش مع العملية
    // وBayanScriptService يبقيها حيّة (إشعار دائم + WakeLock).
    override fun onDestroy() {
        val bridge = BayanPythonBridge.get(applicationContext)
        bridge.unbindActivity(this)
        attachedEngine?.let { bridge.detach(it) }
        system?.detach()
        attachedEngine = null
        system = null
        super.onDestroy()
    }
}

/** مخزن دائري لأحداث تشغيل واحد، يُعاد للواجهة عندما تتصل من جديد. يُلمس من الخيط الرئيسي فقط. */
class EventRing(private val maxEvents: Int = 2000, private val maxChars: Int = 512 * 1024) {
    private val items = java.util.ArrayDeque<Map<String, Any?>>()
    private var chars = 0

    /** صحيح إذا أُسقطت أحداث أقدم بسبب الحد (الواجهة تعرض تنبيه «قُطع الأقدم»). */
    var truncated = false
        private set

    private fun weight(event: Map<String, Any?>): Int =
        64 + ((event["text"] as? String)?.length ?: 0)

    fun add(event: Map<String, Any?>) {
        items.addLast(event)
        chars += weight(event)
        while (items.size > 1 && (items.size > maxEvents || chars > maxChars)) {
            val dropped = items.pollFirst() ?: break
            truncated = true
            chars -= weight(dropped)
        }
    }

    fun snapshot(): List<Map<String, Any?>> = ArrayList(items)
}

/**
 * سجل الإخراج الدائم على القرص (2.5D1). ملف JSONL لكل سكربت داخل filesDir/logs.
 *
 * التنسيق (لا يتغير في 2.5D2):
 *   بداية:  {"run":"<runId>","start":<ms>,"auto":false}
 *   حدث:    {"t":<ms>,"k":"o|e|i|s","s":"<نص>"}   o إخراج، e أخطاء، i إدخال (الطلب ثم ما كتبه المستخدم)، s ملاحظة نظام
 *   نهاية:  {"end":"<runId>","t":<ms>,"code":<int>}
 * الكتابة بالإضافة فقط، ونصوص الدفعات تُحفظ كما وصلت (دون تحويلها إلى أسطر).
 *
 * الخيوط: الاستقبال (startRun / addEvent / endRun) يضيف إلى مخزن صغير في الذاكرة ويعود فورًا،
 * وكل عمل الملفات (الكتابة والقص والقراءة والنقل والحذف) يجري على خيط واحد خلفي
 * "Bayan-LogWriter"، فلا يُمسّ القرص من الخيط الرئيسي ولا يتداخل عمل ملف مع آخر.
 */
class LogStore(private val dir: File) {
    companion object {
        private const val TAG = "BayanLogStore"

        /** سقف الملف الواحد، وعند تجاوزه يُقصّ إلى TARGET_BYTES (لتجنب القص عند كل كتابة). */
        const val MAX_BYTES = 20L * 1024 * 1024
        const val TARGET_BYTES = 16L * 1024 * 1024

        /** التفريغ: كل ثانية، أو عند 32KB، أو عند نهاية التشغيل. */
        const val FLUSH_BYTES = 32 * 1024
        const val FLUSH_DELAY_MS = 1000L

        /** دفعة أكبر من هذا تُحفظ على عدة أحداث متتالية (المحتوى والترتيب كما هما) كي يبقى حجم السطر محدودًا. */
        const val MAX_EVENT_CHARS = 64 * 1024

        const val PAGE_DEFAULT_BYTES = 256 * 1024
        const val PAGE_MIN_BYTES = 4 * 1024
        const val PAGE_MAX_BYTES = 1024 * 1024
        private const val LINE_SCAN_LIMIT = 8L * 1024 * 1024

        const val TRIM_NOTE = "… حُذف الأقدم"
        const val FILE_EXT = ".jsonl"
        const val TRASH_EXT = ".trash"
        const val TEMP_EXT = ".tmp"
        private const val MAX_NAME_BYTES = 235
        private const val START_PREFIX = "{\"run\":"

        private const val ITEM_EVENT = 0
        private const val ITEM_START = 1
        private const val ITEM_END = 2

        /**
         * مفتاح السكربت: اسم الملف بحروف صغيرة. هو نفسه مفتاح التثبيت و«آخر تشغيل» في store.dart
         * (`_base(path).toLowerCase()`)، فتتبع السجلات السكربت عند إعادة التسمية.
         */
        fun keyOf(scriptPath: String): String = scriptPath.substringAfterLast('/').lowercase()

        /** اسم ملف آمن من المفتاح (يقصّر الأسماء الطويلة جدًا بصورة ثابتة). */
        fun fileNameOf(key: String): String {
            var safe = key.replace('/', '_').replace('\u0000', '_')
            if (safe.isEmpty() || safe == "." || safe == "..") safe = "_$safe"
            if (safe.toByteArray(Charsets.UTF_8).size > MAX_NAME_BYTES) {
                var cut = minOf(safe.length, 60)
                if (cut > 0 && Character.isHighSurrogate(safe[cut - 1])) cut--
                safe = safe.substring(0, cut) + "~" + (key.hashCode().toLong() and 0xFFFFFFFFL).toString(16)
            }
            return safe + FILE_EXT
        }

        private val HEX = "0123456789abcdef".toCharArray()

        /** يهرّب النص لـ JSON. الأحرف النائبة (surrogates) غير المزدوجة تُكتب \\uXXXX كي لا تضيع عند الترميز. */
        fun escapeJson(text: String, out: StringBuilder) {
            var i = 0
            val n = text.length
            while (i < n) {
                val c = text[i]
                when {
                    c == '"' -> out.append("\\\"")
                    c == '\\' -> out.append("\\\\")
                    c == '\n' -> out.append("\\n")
                    c == '\r' -> out.append("\\r")
                    c == '\t' -> out.append("\\t")
                    c == '\b' -> out.append("\\b")
                    c == '\u000C' -> out.append("\\f")
                    c < ' ' || c == '\u2028' || c == '\u2029' -> appendUnicodeEscape(out, c)
                    Character.isHighSurrogate(c) -> {
                        if (i + 1 < n && Character.isLowSurrogate(text[i + 1])) {
                            out.append(c).append(text[i + 1])
                            i++
                        } else {
                            appendUnicodeEscape(out, c)
                        }
                    }
                    Character.isLowSurrogate(c) -> appendUnicodeEscape(out, c)
                    else -> out.append(c)
                }
                i++
            }
        }

        private fun appendUnicodeEscape(out: StringBuilder, c: Char) {
            val v = c.code
            out.append("\\u")
                .append(HEX[(v shr 12) and 0xF])
                .append(HEX[(v shr 8) and 0xF])
                .append(HEX[(v shr 4) and 0xF])
                .append(HEX[v and 0xF])
        }

        fun startLine(runId: String, startedAt: Long, auto: Boolean): String {
            val sb = StringBuilder(64)
            sb.append(START_PREFIX).append('"')
            escapeJson(runId, sb)
            sb.append("\",\"start\":").append(startedAt)
                .append(",\"auto\":").append(if (auto) "true" else "false")
                .append("}\n")
            return sb.toString()
        }

        fun eventLine(t: Long, kind: String, text: String): String {
            val sb = StringBuilder(text.length + 40)
            sb.append("{\"t\":").append(t)
                .append(",\"k\":\"").append(kind)
                .append("\",\"s\":\"")
            escapeJson(text, sb)
            sb.append("\"}\n")
            return sb.toString()
        }

        fun endLine(runId: String, t: Long, code: Int): String {
            val sb = StringBuilder(64)
            sb.append("{\"end\":\"")
            escapeJson(runId, sb)
            sb.append("\",\"t\":").append(t)
                .append(",\"code\":").append(code)
                .append("}\n")
            return sb.toString()
        }
    }

    private class Item(val key: String, val type: Int, val runId: String?, val bytes: ByteArray)

    /** تشغيل جارٍ لسكربت: سطر بدايته وعدد البايتات من أول سطر البداية إلى نهاية الملف. يُلمس من خيط الكتابة فقط. */
    private class ActiveRun(val runId: String, val startLine: ByteArray, var since: Long)

    private val worker: ScheduledExecutorService =
        Executors.newSingleThreadScheduledExecutor { runnable ->
            Thread(runnable, "Bayan-LogWriter").apply { isDaemon = true }
        }

    private val lock = Any()
    private var pending = ArrayList<Item>()
    private var pendingBytes = 0
    private var timerArmed = false
    private var thresholdQueued = false

    // الأعضاء التالية تُلمس من خيط الكتابة فقط
    private val active = HashMap<String, ActiveRun>()
    private val checkedKeys = HashSet<String>()
    private val epochs = HashMap<String, Long>()

    // ───── الاستقبال (من أي خيط، بلا أي عمل على القرص) ─────

    /** عند التهيئة: يحذف بقايا ".trash" (حذف لم يُتراجع عنه) وملفات القص المؤقتة ".tmp". السجلات العادية لا تُمسّ. */
    fun start() {
        worker.execute {
            try {
                dir.mkdirs()
                dir.listFiles()?.forEach { file ->
                    val name = file.name
                    if (name.endsWith(TRASH_EXT) || name.endsWith(TEMP_EXT)) {
                        try {
                            if (!file.delete()) Log.w(TAG, "could not delete leftover ${file.name}")
                        } catch (t: Throwable) {
                            Log.w(TAG, "leftover cleanup failed for ${file.name}: ${t.message}")
                        }
                    }
                }
            } catch (t: Throwable) {
                Log.w(TAG, "startup cleanup failed: ${t.message}")
            }
        }
    }

    fun startRun(scriptPath: String, runId: String, startedAt: Long, auto: Boolean) {
        enqueue(Item(keyOf(scriptPath), ITEM_START, runId, startLine(runId, startedAt, auto).toByteArray(Charsets.UTF_8)))
    }

    /** kind: o | e | i | s. النص يُحفظ كما وصل (الدفعة الضخمة جدًا فقط تُقسَّم دون تغيير محتواها). */
    fun addEvent(scriptPath: String, t: Long, kind: String, text: String) {
        if (text.isEmpty() && kind != "i") return
        val key = keyOf(scriptPath)
        var from = 0
        do {
            var to = minOf(text.length, from + MAX_EVENT_CHARS)
            if (to < text.length && to > from && Character.isHighSurrogate(text[to - 1])) to--
            enqueue(Item(key, ITEM_EVENT, null, eventLine(t, kind, text.substring(from, to)).toByteArray(Charsets.UTF_8)))
            from = to
        } while (from < text.length)
    }

    /** يربط حدث الجسر بسطر السجل. start/exit يصنعان سطري البداية والنهاية، والباقي أحداث o/e/i. */
    fun record(scriptPath: String, runId: String, startedAt: Long, type: String, text: String, exitCode: Int, t: Long) {
        when (type) {
            "started" -> startRun(scriptPath, runId, startedAt, false)
            "stdout" -> addEvent(scriptPath, t, "o", text)
            "stderr", "error" -> addEvent(scriptPath, t, "e", text)
            "input" -> addEvent(scriptPath, t, "i", text)
            "exit" -> endRun(scriptPath, runId, t, exitCode)
        }
    }

    /** يُكتب مرة واحدة لكل تشغيل (النداء المكرر يُتجاهل عند الكتابة) ويُفرَّغ فورًا. */
    fun endRun(scriptPath: String, runId: String, t: Long, code: Int) {
        enqueue(Item(keyOf(scriptPath), ITEM_END, runId, endLine(runId, t, code).toByteArray(Charsets.UTF_8)))
        worker.execute { flushPending() }
    }

    private fun enqueue(item: Item) {
        var flushNow = false
        var arm = false
        synchronized(lock) {
            pending.add(item)
            pendingBytes += item.bytes.size
            if (pendingBytes >= FLUSH_BYTES && !thresholdQueued) {
                thresholdQueued = true
                flushNow = true
            }
            if (!timerArmed) {
                timerArmed = true
                arm = true
            }
        }
        if (flushNow) worker.execute { flushPending() }
        if (arm) {
            worker.schedule(
                Runnable {
                    synchronized(lock) { timerArmed = false }
                    flushPending()
                },
                FLUSH_DELAY_MS,
                TimeUnit.MILLISECONDS,
            )
        }
    }

    // ───── طرق القناة (كلها غير متزامنة: تعمل على خيط الكتابة وتعيد النتيجة بنداء) ─────

    fun size(scriptPath: String, ok: (Long) -> Unit, err: (Throwable) -> Unit) =
        io(ok, err) { sizeNow(keyOf(scriptPath)) }

    fun page(
        scriptPath: String,
        before: Long?,
        maxBytes: Int,
        epoch: Long?,
        ok: (Map<String, Any?>) -> Unit,
        err: (Throwable) -> Unit,
    ) = io(ok, err) { pageNow(keyOf(scriptPath), before, maxBytes, epoch) }

    fun clear(scriptPath: String, ok: (Boolean) -> Unit, err: (Throwable) -> Unit) =
        io(ok, err) { clearNow(keyOf(scriptPath)) }

    fun move(fromPath: String, toPath: String, ok: (Boolean) -> Unit, err: (Throwable) -> Unit) =
        io(ok, err) { moveNow(keyOf(fromPath), keyOf(toPath)) }

    fun trash(scriptPath: String, ok: (Boolean) -> Unit, err: (Throwable) -> Unit) =
        io(ok, err) { trashNow(keyOf(scriptPath)) }

    fun untrash(
        scriptPath: String,
        restoreAs: String?,
        ok: (Boolean) -> Unit,
        err: (Throwable) -> Unit,
    ) = io(ok, err) { untrashNow(keyOf(scriptPath), keyOf(restoreAs ?: scriptPath)) }

    fun purge(scriptPath: String, ok: (Boolean) -> Unit, err: (Throwable) -> Unit) =
        io(ok, err) { purgeNow(keyOf(scriptPath)) }

    /** يفرّغ المخزن أولًا (فيرى القارئ آخر ما سُجّل) ثم ينفّذ المهمة، كل ذلك على خيط الكتابة. */
    private fun <T> io(ok: (T) -> Unit, err: (Throwable) -> Unit, task: () -> T) {
        worker.execute {
            val value = try {
                flushPending()
                task()
            } catch (t: Throwable) {
                Log.w(TAG, "log operation failed: ${t.message}")
                err(t)
                return@execute
            }
            ok(value)
        }
    }

    // ───── من هنا فصاعدًا: خيط الكتابة فقط ─────

    private fun fileFor(key: String): File = File(dir, fileNameOf(key))
    private fun trashFor(key: String): File = File(dir, fileNameOf(key) + TRASH_EXT)
    private fun tempFor(key: String): File = File(dir, fileNameOf(key) + TEMP_EXT)
    private fun epochOf(key: String): Long = epochs[key] ?: 0L
    private fun bumpEpoch(key: String) {
        epochs[key] = epochOf(key) + 1
    }

    private fun flushPending() {
        val batch = synchronized(lock) {
            val taken = pending
            pending = ArrayList()
            pendingBytes = 0
            thresholdQueued = false
            taken
        }
        if (batch.isEmpty()) return

        // تجميع الدفعة لكل ملف مع حفظ الترتيب داخل الملف، وتحديث حالة التشغيل الجاري
        val groups = LinkedHashMap<String, ByteArrayOutputStream>()
        val syncKeys = HashSet<String>()
        for (item in batch) {
            when (item.type) {
                ITEM_START -> active[item.key] = ActiveRun(item.runId ?: "", item.bytes, item.bytes.size.toLong())
                ITEM_END -> {
                    val current = active[item.key]
                    // نهاية مكررة (مسار آخر للحدث نفسه) أو لتشغيل غير الجاري: تُتجاهل
                    if (current == null || current.runId != item.runId) continue
                    active.remove(item.key)
                    syncKeys.add(item.key)
                }
                else -> active[item.key]?.let { it.since += item.bytes.size }
            }
            groups.getOrPut(item.key) { ByteArrayOutputStream() }.write(item.bytes)
        }
        for ((key, buffer) in groups) {
            try {
                appendToFile(key, buffer.toByteArray(), key in syncKeys)
            } catch (t: Throwable) {
                // فشل كتابة ملف واحد (قرص ممتلئ مثلًا) لا يوقف بقية السجلات ولا السكربت
                Log.w(TAG, "append failed for $key: ${t.message}")
            }
        }
    }

    private fun appendToFile(key: String, bytes: ByteArray, sync: Boolean) {
        dir.mkdirs()
        val file = fileFor(key)
        ensureTerminated(key, file)
        FileOutputStream(file, true).use { out ->
            out.write(bytes)
            out.flush()
            if (sync) out.fd.sync()
        }
        val size = file.length()
        if (size > MAX_BYTES) trimNow(key, file, size)
    }

    /** إن انقطعت الكتابة في منتصف سطر (قتل التطبيق) نُنهي ذلك السطر قبل الإضافة فلا يلتصق به سطر جديد. */
    private fun ensureTerminated(key: String, file: File) {
        if (!checkedKeys.add(key)) return
        if (!file.exists() || file.length() == 0L) return
        RandomAccessFile(file, "rw").use { raf ->
            raf.seek(raf.length() - 1)
            if (raf.read() != '\n'.code) raf.write('\n'.code)
        }
    }

    /**
     * يقصّ الأقدم عند تجاوز MAX_BYTES إلى نحو TARGET_BYTES، عند حد سطر كامل.
     * إن وقع القص داخل تشغيل: تُضاف في أول الملف ملاحظة «… حُذف الأقدم»، ومعها سطر بداية التشغيل
     * الجاري إن كان سطره قد حُذف، فلا يُحذف التشغيل الجاري ولا تختل بنية الملف.
     */
    private fun trimNow(key: String, file: File, size: Long) {
        val cutFrom = size - TARGET_BYTES
        if (cutFrom <= 0L) return
        val temp = tempFor(key)
        RandomAccessFile(file, "r").use { raf ->
            // أول بداية سطر عند الموضع cutFrom أو بعده
            var keepFrom = -1L
            var pos = cutFrom - 1
            val block = ByteArray(8192)
            raf.seek(pos)
            while (keepFrom < 0 && pos < size) {
                val n = raf.read(block)
                if (n <= 0) break
                for (i in 0 until n) {
                    if (block[i] == '\n'.code.toByte()) {
                        keepFrom = pos + i + 1
                        break
                    }
                }
                pos += n
            }
            if (keepFrom < 0L || keepFrom >= size) {
                Log.w(TAG, "trim skipped for $key: no line boundary found")
                return
            }
            val retained = size - keepFrom

            val head = ByteArray(START_PREFIX.length)
            raf.seek(keepFrom)
            val got = raf.read(head)
            val startsAtRun = got == head.size && String(head, Charsets.UTF_8) == START_PREFIX

            val act = active[key]
            val startDropped = act != null && act.since > retained
            val prefix = ByteArrayOutputStream()
            if (!startsAtRun) {
                if (startDropped && act != null) prefix.write(act.startLine)
                prefix.write(eventLine(System.currentTimeMillis(), "s", TRIM_NOTE).toByteArray(Charsets.UTF_8))
            }

            FileOutputStream(temp, false).use { out ->
                out.write(prefix.toByteArray())
                raf.seek(keepFrom)
                var left = retained
                val copy = ByteArray(64 * 1024)
                while (left > 0) {
                    val n = raf.read(copy, 0, minOf(copy.size.toLong(), left).toInt())
                    if (n <= 0) throw IOException("unexpected end of $key while trimming")
                    out.write(copy, 0, n)
                    left -= n
                }
                out.flush()
                out.fd.sync()
            }
            if (!startsAtRun && startDropped && act != null) {
                act.since = prefix.size().toLong() + retained
            }
        }
        if (!temp.renameTo(file)) {
            file.delete()
            if (!temp.renameTo(file)) {
                temp.delete()
                throw IOException("could not replace $key after trimming")
            }
        }
        bumpEpoch(key)
    }

    private fun sizeNow(key: String): Long {
        val file = fileFor(key)
        return if (file.exists()) file.length() else 0L
    }

    /**
     * يقرأ قطعة من أسطر كاملة تنتهي عند الموضع before (null = نهاية الملف) وتمتد للخلف نحو maxBytes.
     * لا يحمّل الملف كاملًا. المواضع بالبايت من أول الملف وتتغير عند القص أو المسح، لذلك يعاد epoch؛
     * إن مرّر العميل epoch قديمًا يعود الرد بـ stale=true ليبدأ من النهاية من جديد.
     */
    private fun pageNow(key: String, before: Long?, maxBytes: Int, epoch: Long?): Map<String, Any?> {
        val file = fileFor(key)
        val current = epochOf(key)
        val size = if (file.exists()) file.length() else 0L

        fun reply(text: String, start: Long, end: Long, stale: Boolean): Map<String, Any?> = mapOf(
            "text" to text,
            "start" to start,
            "end" to end,
            "size" to size,
            "hasMore" to (start > 0L && !stale),
            "epoch" to current,
            "stale" to stale,
        )

        if (epoch != null && epoch != current) return reply("", size, size, true)
        val end = (before ?: size).coerceIn(0L, size)
        if (size == 0L || end == 0L) return reply("", 0L, 0L, false)

        val limit = maxBytes.coerceIn(PAGE_MIN_BYTES, PAGE_MAX_BYTES).toLong()
        return RandomAccessFile(file, "r").use { raf ->
            // end يجب أن يكون بداية سطر (أو نهاية الملف)
            if (end < size) {
                raf.seek(end - 1)
                if (raf.read() != '\n'.code) return@use reply("", end, end, true)
            }
            var window = limit
            var result: Map<String, Any?>? = null
            while (result == null) {
                val from = maxOf(0L, end - window)
                // نقرأ بايتًا إضافيًا قبل النافذة لنعرف إن كانت تبدأ عند حد سطر
                val readFrom = if (from > 0L) from - 1 else 0L
                val bytes = ByteArray((end - readFrom).toInt())
                raf.seek(readFrom)
                raf.readFully(bytes)
                if (from == 0L) {
                    result = reply(String(bytes, Charsets.UTF_8), 0L, end, false)
                } else {
                    // أول نهاية سطر قبل البايت الأخير (الأخير هو نهاية آخر سطر): بعدها سطر كامل واحد على الأقل
                    var newline = -1
                    for (i in 0 until bytes.size - 1) {
                        if (bytes[i] == '\n'.code.toByte()) {
                            newline = i
                            break
                        }
                    }
                    if (newline >= 0) {
                        val text = String(bytes, newline + 1, bytes.size - newline - 1, Charsets.UTF_8)
                        result = reply(text, readFrom + newline + 1, end, false)
                    } else if (window >= LINE_SCAN_LIMIT) {
                        result = reply(String(bytes, Charsets.UTF_8), readFrom, end, false)
                    } else {
                        window *= 2
                    }
                }
            }
            result ?: reply("", 0L, 0L, false)
        }
    }

    /** يمسح السجل. إن كان للسكربت تشغيل جارٍ يبقى سطر بدايته، ويستمر التسجيل بعد المسح. */
    private fun clearNow(key: String): Boolean {
        val file = fileFor(key)
        val act = active[key]
        if (file.exists() && !file.delete()) {
            FileOutputStream(file, false).use { }
        }
        if (act != null) {
            dir.mkdirs()
            FileOutputStream(file, false).use { out ->
                out.write(act.startLine)
                out.flush()
            }
            act.since = act.startLine.size.toLong()
        }
        checkedKeys.remove(key)
        bumpEpoch(key)
        return true
    }

    /** ينقل سجل from إلى to عند إعادة التسمية. لا سجل للمصدر: لا شيء ليُنقل (صحيح). يحلّ السجل المنقول محل سجل قديم بالاسم الجديد. */
    private fun moveNow(from: String, to: String): Boolean {
        if (from == to) return true
        val source = fileFor(from)
        val target = fileFor(to)
        checkedKeys.remove(from)
        checkedKeys.remove(to)
        bumpEpoch(from)
        bumpEpoch(to)
        active.remove(from)?.let { active[to] = it }
        if (!source.exists()) return true
        if (target.exists() && !target.delete()) return false
        return source.renameTo(target)
    }

    /** يحجز السجل باسم ".trash" ليمكن التراجع. false إن لم يوجد سجل. */
    private fun trashNow(key: String): Boolean {
        val file = fileFor(key)
        if (!file.exists()) return false
        val held = trashFor(key)
        if (held.exists() && !held.delete()) return false
        val moved = file.renameTo(held)
        if (moved) {
            active.remove(key)
            checkedKeys.remove(key)
            bumpEpoch(key)
        }
        return moved
    }

    /** يعيد السجل المحجوز. false إن لم يوجد، أو وُجد سجل جديد بالاسم نفسه (لا نكتب فوقه). */
    private fun untrashNow(key: String, restoreKey: String): Boolean {
        val held = trashFor(key)
        val file = fileFor(restoreKey)
        if (!held.exists() || file.exists()) return false
        val moved = held.renameTo(file)
        if (moved) {
            checkedKeys.remove(key)
            checkedKeys.remove(restoreKey)
            bumpEpoch(key)
            bumpEpoch(restoreKey)
        }
        return moved
    }

    /** يحذف السجل المحجوز نهائيًا. صحيح إن لم يبقَ شيء محجوز. */
    private fun purgeNow(key: String): Boolean {
        val held = trashFor(key)
        if (held.exists()) held.delete()
        return !held.exists()
    }
}

class BayanPythonBridge private constructor(private val context: Context) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        @Volatile private var instance: BayanPythonBridge? = null

        /** كائن واحد يعيش مع العملية (وليس مع MainActivity). */
        fun get(context: Context): BayanPythonBridge =
            instance ?: synchronized(this) {
                instance ?: BayanPythonBridge(context.applicationContext).also { instance = it }
            }

        fun peek(): BayanPythonBridge? = instance

        /** عدد الجلسات المنتهية المحتفظ بها (الأقدم تُحذف جلستها كاملة). */
        const val MAX_FINISHED_RUNS = 10

        const val BUSY_MESSAGE =
            "هناك سكربت يعمل الآن، وقد يكون في الخلفية. أوقفه من إشعار «مشغّل بايثون» (زر «إيقاف الكل») ثم أعد المحاولة"
    }

    data class RunInfo(val runId: String, val name: String, val startedAt: Long)

    private val main = Handler(Looper.getMainLooper())
    private val pythonExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "Bayan-Python").apply { isDaemon = true }
    }
    private val controlExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "Bayan-Python-Control").apply { isDaemon = true }
    }
    // المفتاح: مسار السكربت. لكل سكربت جلسة واحدة (الأخيرة)، وتشغيل جديد لنفس السكربت يستبدلها.
    private val sessions = mutableMapOf<String, RunSession>()
    private val sessionsLock = Any()
    private var environmentReady = false

    // حالة موافقة المستخدم ووضع النافذة المصغّرة (Picture-in-Picture)
    @Volatile var consentGranted = false
    @Volatile var inPipMode = false
    @Volatile private var hostActivity: MainActivity? = null

    // سجل الإخراج الدائم (2.5D1): يعيش مع الجسر، فيستمر التسجيل والواجهة مغلقة. كل عمل الملفات على خيطه الخلفي.
    private val logs = LogStore(File(context.filesDir, "logs")).also { it.start() }

    // الأعضاء التالية تُلمس من الخيط الرئيسي فقط
    private var eventSink: EventChannel.EventSink? = null
    private var attachedEngine: FlutterEngine? = null
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null

    fun attach(engine: FlutterEngine) {
        releaseChannels()
        attachedEngine = engine
        val messenger = engine.dartExecutor.binaryMessenger
        methodChannel = MethodChannel(messenger, "bayan/python").also { it.setMethodCallHandler(this) }
        eventChannel = EventChannel(messenger, "bayan/python/events").also { it.setStreamHandler(this) }
    }

    /** يفصل الواجهة فقط. لا يوقف أي سكربت ولا يغلق المنفّذات. */
    fun detach(engine: FlutterEngine) {
        if (attachedEngine !== engine) return
        releaseChannels()
        attachedEngine = null
    }

    fun bindActivity(activity: MainActivity) {
        hostActivity = activity
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            inPipMode = activity.isInPictureInPictureMode
        }
        refreshPipParams()
    }

    fun unbindActivity(activity: MainActivity) {
        if (hostActivity === activity) {
            hostActivity = null
            inPipMode = false
        }
    }

    private fun canEnterPip(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            consentGranted &&
            activeRuns().isNotEmpty()

    private fun buildPipParams(activity: MainActivity): PictureInPictureParams? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null
        if (!activity.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) {
            return null
        }
        val runs = activeRuns()
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(16, 10))
        if (runs.size > 1) {
            val iconId = activity.resources.getIdentifier("ic_bayan_notify", "drawable", activity.packageName)
            val icon = Icon.createWithResource(
                activity,
                if (iconId != 0) iconId else android.R.drawable.ic_popup_sync,
            )
            val nextIntent = Intent(activity, BayanScriptService::class.java)
                .setAction(BayanScriptService.ACTION_PIP_NEXT)
            val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            val pending = PendingIntent.getService(activity, 2, nextIntent, flags)
            val action = RemoteAction(icon, "تبديل السكربت", "تبديل السكربت المعروض", pending)
            builder.setActions(listOf(action))
        } else {
            builder.setActions(emptyList())
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(consentGranted && runs.isNotEmpty())
            builder.setSeamlessResizeEnabled(false)
        }
        return builder.build()
    }

    fun refreshPipParams() {
        main.post {
            val act = hostActivity ?: return@post
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return@post
            try {
                val params = buildPipParams(act)
                if (params != null) {
                    act.setPictureInPictureParams(params)
                }
                if (act.isInPictureInPictureMode && !canEnterPip()) {
                    // توقفت جميع السكربتات (أو ألغيت الموافقة) والتطبيق في وضع النافذة المصغّرة: نخفي النافذة فوراً.
                    act.moveTaskToBack(true)
                }
            } catch (t: Throwable) {
                Log.w("BayanPip", "refreshPipParams failed: ${t.message}")
            }
        }
    }

    fun onUserLeave(activity: MainActivity) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (!canEnterPip() || activity.isInPictureInPictureMode) return
        try {
            val params = buildPipParams(activity) ?: return
            val entered = activity.enterPictureInPictureMode(params)
            if (entered) {
                onPipModeChanged(activity, true)
            }
        } catch (t: Throwable) {
            Log.w("BayanPip", "enterPictureInPictureMode failed: ${t.message}")
        }
    }

    fun onPipModeChanged(activity: MainActivity, active: Boolean) {
        inPipMode = active
        emit(
            mapOf(
                "channel" to "pip",
                "type" to "mode",
                "text" to if (active) "1" else "0",
            )
        )
        if (active && !canEnterPip()) {
            try {
                activity.moveTaskToBack(true)
            } catch (_: Throwable) {}
        }
        refreshPipParams()
    }

    fun syncPipState(activity: MainActivity) {
        val active = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && activity.isInPictureInPictureMode
        if (inPipMode != active) {
            inPipMode = active
            emit(
                mapOf(
                    "channel" to "pip",
                    "type" to "mode",
                    "text" to if (active) "1" else "0",
                )
            )
        }
        refreshPipParams()
    }

    fun requestPipNextScript() {
        emit(
            mapOf(
                "channel" to "pip",
                "type" to "next",
                "text" to "",
            )
        )
    }

    fun expandFromPip(): Boolean {
        return try {
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?: Intent(context, MainActivity::class.java)
            launch.addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
            context.startActivity(launch)
            true
        } catch (t: Throwable) {
            false
        }
    }

    private fun releaseChannels() {
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        methodChannel = null
        eventChannel = null
        eventSink = null
    }

    // لا إعادة بث تلقائية: الواجهة تجلب أحداث الجلسة بنفسها عبر runs.attach
    // وترقيم الأحداث (seq) يمنع تكرار حدث أو ضياعه بين الجلب والبث الحي.
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun emit(values: Map<String, Any?>) {
        val now = System.currentTimeMillis()
        // الترقيم والتخزين والتسليم على الخيط الرئيسي معًا، فيتطابق ما في المخزن مع ما بُثّ حيًا
        main.post {
            var out = values
            if (values["channel"] == "run") {
                val id = values["runId"] as? String
                val session = if (id != null) sessionByRunId(id) else null
                if (session != null) {
                    session.seq += 1
                    out = values + ("seq" to session.seq)
                    session.ring.add(out)
                    // مسار واحد للتسجيل الدائم: هنا فقط، مرة لكل حدث، سواء كانت الواجهة متصلة أم لا
                    logs.record(
                        session.scriptPath,
                        session.runId,
                        session.startedAt,
                        values["type"] as? String ?: "",
                        values["text"] as? String ?: "",
                        (values["exitCode"] as? Number)?.toInt() ?: session.exitCode,
                        now,
                    )
                }
            }
            eventSink?.success(out)
        }
    }

    private fun sessionByRunId(runId: String): RunSession? = synchronized(sessionsLock) {
        sessions.values.firstOrNull { it.runId == runId }
    }

    // يُستدعى داخل sessionsLock. يبقي آخر MAX_FINISHED_RUNS جلسة منتهية فقط.
    private fun pruneFinishedLocked() {
        val done = sessions.values.filter { it.finished }.sortedBy { it.endedAt }
        var extra = done.size - MAX_FINISHED_RUNS
        for (old in done) {
            if (extra <= 0) break
            sessions.remove(old.scriptPath)
            extra--
        }
    }

    private fun emitError(runId: String?, message: String) {
        val map = mutableMapOf<String, Any?>(
            "channel" to "run",
            "type" to "error",
            "text" to message,
        )
        if (runId != null) map["runId"] = runId
        emit(map)
    }

    private fun complete(result: MethodChannel.Result, value: Any?) {
        main.post { result.success(value) }
    }

    private fun fail(result: MethodChannel.Result, code: String, message: String) {
        main.post { result.error(code, message, null) }
    }

    /** السكربتات الجارية الآن (للخدمة والإشعار). */
    fun activeRuns(): List<RunInfo> = synchronized(sessionsLock) {
        sessions.values.filter { !it.finished }.map { RunInfo(it.runId, it.displayName, it.startedAt) }
    }

    /** زر «إيقاف الكل» في الإشعار. */
    fun stopAll() {
        synchronized(sessionsLock) {
            sessions.values.filter { !it.finished }.forEach {
                it.stopped = true
                it.waiting = false
                it.input.offer("")
            }
        }
    }

    private fun ensurePython(): Python {
        synchronized(this) {
            if (!Python.isStarted()) {
                Python.start(AndroidPlatform(context))
            }
            val py = Python.getInstance()
            if (!environmentReady) {
                val envRoot = context.filesDir.resolve("bayan_env")
                envRoot.mkdirs()
                val module = py.getModule("bayan_runtime")
                module.callAttr("configure", envRoot.absolutePath)
                environmentReady = true
            }
            return py
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> {
                controlExecutor.execute {
                    try {
                        val py = ensurePython()
                        val module = py.getModule("bayan_runtime")
                        val abi = Build.SUPPORTED_ABIS.firstOrNull() ?: ""
                        module.callAttr("_configure_android", Build.VERSION.SDK_INT, abi)
                        val info = module.callAttr(
                            "environment_info",
                            Build.VERSION.SDK_INT,
                            abi,
                        ).toString()
                        emit(
                            mapOf(
                                "channel" to "runtime",
                                "type" to "ready",
                                "text" to info,
                            )
                        )
                        complete(result, info)
                    } catch (t: Throwable) {
                        fail(result, "python_init", friendly(t))
                    }
                }
            }

            "run" -> {
                val runId = call.argument<String>("runId")
                val scriptPath = call.argument<String>("scriptPath")
                // بصمة النص تُخزَّن كما هي (نص فقط)، وKotlin لا يفهمها
                val textHash = call.argument<String>("textHash")
                if (runId.isNullOrBlank() || scriptPath.isNullOrBlank()) {
                    fail(result, "bad_arguments", "بيانات التشغيل ناقصة")
                    return
                }
                val session: RunSession
                synchronized(sessionsLock) {
                    val active = sessions.values.firstOrNull { !it.finished }
                    if (active != null) {
                        fail(result, "busy", BUSY_MESSAGE)
                        return
                    }
                    session = RunSession(runId, scriptPath, textHash)
                    // جلسة هذا السكربت القديمة (المنتهية) تُستبدل، وجلسات غيره تبقى
                    sessions[scriptPath] = session
                    pruneFinishedLocked()
                }
                emit(
                    mapOf(
                        "channel" to "run",
                        "type" to "started",
                        "runId" to runId,
                        "scriptPath" to scriptPath,
                        // الواجهة تقارن بها نص المحرر فور البدء (زر «دخول») بلا انتظار runs.list
                        "textHash" to textHash,
                    )
                )
                // الخدمة الأمامية تبدأ هنا (الواجهة ظاهرة فالبدء مسموح) وتبقي العملية حيّة
                BayanScriptService.ensureStarted(context)
                pythonExecutor.execute {
                    try {
                        val py = ensurePython()
                        val module = py.getModule("bayan_runtime")
                        module.callAttr("run_script", scriptPath, session.callback)
                    } catch (t: Throwable) {
                        if (!session.finished) {
                            session.end(1)
                            emitError(runId, friendly(t))
                            emit(
                                mapOf(
                                    "channel" to "run",
                                    "type" to "exit",
                                    "runId" to runId,
                                    "exitCode" to 1,
                                )
                            )
                        }
                    } finally {
                        // الجلسة تبقى بعد الانتهاء (إخراجها وحالتها) إلى أن تُستبدل أو تُقصى بالحد
                        session.end(null)
                        synchronized(sessionsLock) { pruneFinishedLocked() }
                        main.post {
                            // شبكة أمان: سطر النهاية يُكتب مرة واحدة، فإن لم يصل حدث exit يُكتب هنا (المكرر يُتجاهل)
                            logs.endRun(session.scriptPath, runId, System.currentTimeMillis(), session.exitCode)
                            BayanScriptService.onRunsChanged()
                        }
                    }
                }
                complete(result, true)
            }

            "sendInput" -> {
                val runId = call.argument<String>("runId")
                val value = call.argument<String>("text") ?: ""
                if (runId.isNullOrBlank()) {
                    fail(result, "bad_arguments", "معرف التشغيل ناقص")
                    return
                }
                val session = sessionByRunId(runId)
                if (session == null || session.finished) {
                    complete(result, false)
                    return
                }
                session.waiting = false
                session.input.offer(value)
                // ما كتبه المستخدم يُسجَّل كما كُتب، قبل أي إخراج يليه (هذا الاستدعاء على الخيط الرئيسي)
                logs.addEvent(session.scriptPath, System.currentTimeMillis(), "i", value)
                complete(result, true)
            }

            "stop" -> {
                val runId = call.argument<String>("runId")
                if (runId.isNullOrBlank()) {
                    fail(result, "bad_arguments", "معرف التشغيل ناقص")
                    return
                }
                val session = sessionByRunId(runId)
                if (session == null || session.finished) {
                    complete(result, false)
                    return
                }
                session.stopped = true
                session.waiting = false
                session.input.offer("")
                complete(result, true)
            }

            // ───── ج6: طرق الجلسات ─────
            "runs.list" -> {
                val list = synchronized(sessionsLock) { sessions.values.map { it.summary() } }
                complete(result, list)
            }

            "runs.attach" -> {
                val runId = call.argument<String>("runId")
                if (runId.isNullOrBlank()) {
                    fail(result, "bad_arguments", "معرف التشغيل ناقص")
                    return
                }
                val session = sessionByRunId(runId)
                if (session == null) {
                    complete(result, null)
                    return
                }
                // هذا الاستدعاء والتخزين في emit على الخيط الرئيسي نفسه، فاللقطة ورقم lastSeq متطابقان
                val reply = session.summary() + mapOf(
                    "events" to session.ring.snapshot(),
                    "lastSeq" to session.seq,
                    "truncated" to session.ring.truncated,
                )
                complete(result, reply)
            }

            "runs.stopAll" -> {
                stopAll()
                complete(result, true)
            }

            "runs.move" -> {
                val fromPath = call.argument<String>("from")
                val toPath = call.argument<String>("to")
                if (fromPath.isNullOrBlank() || toPath.isNullOrBlank()) {
                    fail(result, "bad_arguments", "مسار السكربت ناقص")
                    return
                }
                val moved = synchronized(sessionsLock) {
                    val session = sessions[fromPath]
                    val clash = sessions[toPath]
                    if (session == null || (clash != null && !clash.finished)) {
                        false
                    } else {
                        sessions.remove(fromPath)
                        session.scriptPath = toPath
                        sessions[toPath] = session
                        true
                    }
                }
                complete(result, moved)
                if (moved) main.post { BayanScriptService.onRunsChanged() }
            }

            "runs.discard" -> {
                val path = call.argument<String>("scriptPath")
                if (path.isNullOrBlank()) {
                    fail(result, "bad_arguments", "مسار السكربت ناقص")
                    return
                }
                // تُحذف المنتهية فقط. السكربت الشغّال لا نمسه
                val discarded = synchronized(sessionsLock) {
                    val session = sessions[path]
                    if (session != null && session.finished) {
                        sessions.remove(path)
                        true
                    } else {
                        false
                    }
                }
                complete(result, discarded)
            }

            // ───── 2.5D1: سجل الإخراج الدائم (logs.*) — كلها غير متزامنة وتعمل على خيط LogStore ─────
            // المعامل scriptPath مسار السكربت (أو اسمه): المفتاح اسم الملف بحروف صغيرة.
            // logs.size   {scriptPath} -> Long (بايت، 0 إن لم يوجد سجل)
            "logs.size" -> {
                val path = call.argument<String>("scriptPath")
                if (path.isNullOrBlank()) {
                    fail(result, "bad_arguments", "مسار السكربت ناقص")
                    return
                }
                logs.size(path, { complete(result, it) }, { fail(result, "logs_size", friendly(it)) })
            }

            // logs.page   {scriptPath, before?: Long, maxBytes?: Int, epoch?: Long}
            //   -> {text, start, end, size, hasMore, epoch, stale}
            //   text: أسطر JSONL كاملة (القطعة تنتهي عند before وتمتد للخلف)، before = null يعني نهاية الملف.
            //   stale = true: تغيّر الملف (قص/مسح/نقل) منذ epoch المرسل، فابدأ من النهاية من جديد.
            "logs.page" -> {
                val path = call.argument<String>("scriptPath")
                if (path.isNullOrBlank()) {
                    fail(result, "bad_arguments", "مسار السكربت ناقص")
                    return
                }
                val before = call.argument<Number>("before")?.toLong()
                val maxBytes = call.argument<Number>("maxBytes")?.toInt() ?: LogStore.PAGE_DEFAULT_BYTES
                val epoch = call.argument<Number>("epoch")?.toLong()
                logs.page(path, before, maxBytes, epoch, { complete(result, it) }, { fail(result, "logs_page", friendly(it)) })
            }

            // logs.clear  {scriptPath} -> Boolean (يبقي سطر بداية التشغيل الجاري ويواصل التسجيل)
            "logs.clear" -> {
                val path = call.argument<String>("scriptPath")
                if (path.isNullOrBlank()) {
                    fail(result, "bad_arguments", "مسار السكربت ناقص")
                    return
                }
                logs.clear(path, { complete(result, it) }, { fail(result, "logs_clear", friendly(it)) })
            }

            // logs.move   {from, to} -> Boolean (false: تعذر النقل؛ لا سجل للمصدر يعني لا شيء ليُنقل فيعود true)
            "logs.move" -> {
                val fromPath = call.argument<String>("from")
                val toPath = call.argument<String>("to")
                if (fromPath.isNullOrBlank() || toPath.isNullOrBlank()) {
                    fail(result, "bad_arguments", "مسار السكربت ناقص")
                    return
                }
                logs.move(fromPath, toPath, { complete(result, it) }, { fail(result, "logs_move", friendly(it)) })
            }

            // logs.trash  {scriptPath} -> Boolean (true: حُجز السجل باسم ".trash"؛ false: لا سجل)
            "logs.trash" -> {
                val path = call.argument<String>("scriptPath")
                if (path.isNullOrBlank()) {
                    fail(result, "bad_arguments", "مسار السكربت ناقص")
                    return
                }
                logs.trash(path, { complete(result, it) }, { fail(result, "logs_trash", friendly(it)) })
            }

            // logs.untrash {scriptPath, restoreAs?} -> Boolean (false: لا سجل محجوز، أو وُجد سجل جديد بالاسم المستعاد فلا نكتب فوقه)
            "logs.untrash" -> {
                val path = call.argument<String>("scriptPath")
                val restoreAs = call.argument<String>("restoreAs")
                if (path.isNullOrBlank()) {
                    fail(result, "bad_arguments", "مسار السكربت ناقص")
                    return
                }
                logs.untrash(path, restoreAs, { complete(result, it) }, { fail(result, "logs_untrash", friendly(it)) })
            }

            // logs.purge  {scriptPath} -> Boolean (true: لم يبقَ سجل محجوز)
            "logs.purge" -> {
                val path = call.argument<String>("scriptPath")
                if (path.isNullOrBlank()) {
                    fail(result, "bad_arguments", "مسار السكربت ناقص")
                    return
                }
                logs.purge(path, { complete(result, it) }, { fail(result, "logs_purge", friendly(it)) })
            }

            "packages.list" -> {
                synchronized(sessionsLock) {
                    if (sessions.values.any { !it.finished }) {
                        fail(result, "busy", "لا يمكن قراءة المكتبات أثناء تشغيل سكربت")
                        return
                    }
                }
                controlExecutor.execute {
                    try {
                        val py = ensurePython()
                        val module = py.getModule("bayan_runtime")
                        module.callAttr("_configure_android", Build.VERSION.SDK_INT, Build.SUPPORTED_ABIS.firstOrNull() ?: "")
                        val value = module.callAttr("list_installed").toString()
                        val parsed = org.json.JSONArray(value)
                        complete(result, jsonArrayToList(parsed))
                    } catch (t: Throwable) {
                        fail(result, "packages_list", friendly(t))
                    }
                }
            }

            "packages.catalog" -> {
                synchronized(sessionsLock) {
                    if (sessions.values.any { !it.finished }) {
                        fail(result, "busy", "لا يمكن فحص المكتبات أثناء تشغيل سكربت")
                        return
                    }
                }
                controlExecutor.execute {
                    try {
                        val py = ensurePython()
                        val module = py.getModule("bayan_runtime")
                        module.callAttr("_configure_android", Build.VERSION.SDK_INT, Build.SUPPORTED_ABIS.firstOrNull() ?: "")
                        val value = module.callAttr("catalog_status").toString()
                        val parsed = org.json.JSONArray(value)
                        complete(result, jsonArrayToList(parsed))
                    } catch (t: Throwable) {
                        fail(result, "packages_catalog", friendly(t))
                    }
                }
            }

            "packages.check" -> {
                // هل توجد نسخة من كل مكتبة تعمل على أندرويد؟ (للقراءة فقط، لا يمس البيئة)
                val names = call.argument<List<String>>("names")
                if (names.isNullOrEmpty()) {
                    complete(result, emptyList<Map<String, Any?>>())
                    return
                }
                controlExecutor.execute {
                    try {
                        val py = ensurePython()
                        val module = py.getModule("bayan_runtime")
                        module.callAttr("_configure_android", Build.VERSION.SDK_INT, Build.SUPPORTED_ABIS.firstOrNull() ?: "")
                        val value = module.callAttr("check_availability", org.json.JSONArray(names).toString()).toString()
                        complete(result, jsonArrayToList(org.json.JSONArray(value)))
                    } catch (t: Throwable) {
                        fail(result, "packages_check", friendly(t))
                    }
                }
            }

            "packages.install" -> {
                val spec = call.argument<String>("spec")?.trim()
                val jobId = call.argument<String>("jobId")?.trim()
                if (spec.isNullOrBlank() || jobId.isNullOrBlank()) {
                    fail(result, "bad_arguments", "بيانات تثبيت المكتبة ناقصة")
                    return
                }
                synchronized(sessionsLock) {
                    if (sessions.values.any { !it.finished }) {
                        fail(result, "busy", "أوقف السكربت الحالي قبل تثبيت مكتبة")
                        return
                    }
                }
                pythonExecutor.execute {
                    try {
                        val py = ensurePython()
                        val abi = Build.SUPPORTED_ABIS.firstOrNull() ?: ""
                        val api = Build.VERSION.SDK_INT
                        val module = py.getModule("bayan_runtime")
                        module.callAttr("_configure_android", api, abi)
                        val callback = PackageCallback(jobId)
                        val raw = module.callAttr("install_package", spec, callback, jobId).toString()
                        val obj = org.json.JSONObject(raw)
                        if (!obj.optBoolean("ok", false)) {
                            fail(result, "package_install", obj.optString("error", "فشل تثبيت المكتبة"))
                        } else {
                            complete(result, true)
                        }
                    } catch (t: Throwable) {
                        emit(
                            mapOf(
                                "channel" to "package",
                                "type" to "error",
                                "jobId" to jobId,
                                "message" to friendly(t),
                                "progress" to 0,
                            )
                        )
                        fail(result, "package_install", friendly(t))
                    }
                }
            }

            "packages.remove" -> {
                val name = call.argument<String>("name")?.trim()
                if (name.isNullOrBlank()) {
                    fail(result, "bad_arguments", "اسم المكتبة ناقص")
                    return
                }
                synchronized(sessionsLock) {
                    if (sessions.values.any { !it.finished }) {
                        fail(result, "busy", "أوقف السكربت الحالي قبل إزالة مكتبة")
                        return
                    }
                }
                pythonExecutor.execute {
                    try {
                        val py = ensurePython()
                        val module = py.getModule("bayan_runtime")
                        val raw = module.callAttr("remove_package", name).toString()
                        val obj = org.json.JSONObject(raw)
                        if (!obj.optBoolean("ok", false)) {
                            fail(result, "package_remove", obj.optString("error", "تعذر إزالة المكتبة"))
                        } else {
                            complete(result, true)
                        }
                    } catch (t: Throwable) {
                        fail(result, "package_remove", friendly(t))
                    }
                }
            }

            else -> result.notImplemented()
        }
    }

    // Flutter's message codec accepts List/Map/primitives only, not org.json types,
    // so nested arrays (requires / requiredBy) and objects are converted too.
    private fun jsonValue(value: Any?): Any? {
        return when (value) {
            null -> null
            org.json.JSONObject.NULL -> null
            is org.json.JSONArray -> {
                val items = ArrayList<Any?>(value.length())
                for (i in 0 until value.length()) {
                    items.add(jsonValue(value.opt(i)))
                }
                items
            }
            is org.json.JSONObject -> {
                val nested = HashMap<String, Any?>()
                val nestedKeys = value.keys()
                while (nestedKeys.hasNext()) {
                    val nestedKey = nestedKeys.next()
                    nested[nestedKey] = jsonValue(value.opt(nestedKey))
                }
                nested
            }
            else -> value
        }
    }

    private fun jsonArrayToList(array: org.json.JSONArray): List<Map<String, Any?>> {
        val list = ArrayList<Map<String, Any?>>(array.length())
        for (i in 0 until array.length()) {
            val obj = array.optJSONObject(i) ?: continue
            val map = HashMap<String, Any?>()
            val keys = obj.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                map[key] = jsonValue(obj.opt(key))
            }
            list.add(map)
        }
        return list
    }

    private fun friendly(t: Throwable): String {
        val cause = t.cause ?: t
        val msg = cause.message?.trim().orEmpty()
        return if (msg.isNotEmpty()) msg else cause.javaClass.simpleName
    }

    inner class RunCallback(private val session: RunSession) {
        @Suppress("unused")
        fun shouldStop(): Boolean = session.stopped

        @Suppress("unused")
        fun emitOutput(kind: String, text: String) {
            emit(
                mapOf(
                    "channel" to "run",
                    "type" to kind,
                    "runId" to session.runId,
                    "text" to text,
                )
            )
        }

        @Suppress("unused")
        fun emitError(text: String) {
            emit(
                mapOf(
                    "channel" to "run",
                    "type" to "error",
                    "runId" to session.runId,
                    "text" to text,
                )
            )
        }

        @Suppress("unused")
        fun emitInput(prompt: String) {
            session.waiting = true
            emit(
                mapOf(
                    "channel" to "run",
                    "type" to "input",
                    "runId" to session.runId,
                    "text" to prompt,
                )
            )
        }

        @Suppress("unused")
        fun requestInput(prompt: String): String? {
            if (session.stopped) return null
            return try {
                session.input.take().also {
                    session.waiting = false
                    if (session.stopped) return null
                }
            } catch (_: InterruptedException) {
                null
            }
        }

        @Suppress("unused")
        fun emitState(state: String) {
            emit(
                mapOf(
                    "channel" to "run",
                    "type" to "state",
                    "runId" to session.runId,
                    "text" to state,
                )
            )
        }

        // بايثون يستدعيها عند انتهاء التشغيل بـ ModuleNotFoundError: JSON بالمكتبات الناقصة
        @Suppress("unused")
        fun emitMissing(json: String) {
            emit(
                mapOf(
                    "channel" to "run",
                    "type" to "missing",
                    "runId" to session.runId,
                    "text" to json,
                )
            )
        }

        @Suppress("unused")
        fun emitExit(code: Int) {
            session.end(code)
            emit(
                mapOf(
                    "channel" to "run",
                    "type" to "exit",
                    "runId" to session.runId,
                    "exitCode" to code,
                )
            )
        }
    }

    inner class PackageCallback(private val jobId: String) {
        // بايثون يستدعيها بعد تثبيت كل حزمة (install_package). غيابها كان يسبب
        // AttributeError ويلغي التثبيت بعد أول wheel. الجسر يعيش مع العملية الآن،
        // فإغلاق الواجهة لا يلغي التثبيت.
        @Suppress("unused")
        fun shouldStop(): Boolean = false

        @Suppress("unused")
        fun emitPackage(stage: String, received: Int, total: Int, message: String) {
            val progress = if (total > 0) received.toDouble() / total.toDouble() else 0.0
            emit(
                mapOf(
                    "channel" to "package",
                    "type" to "progress",
                    "jobId" to jobId,
                    "stage" to stage,
                    "received" to received,
                    "total" to total,
                    "progress" to progress,
                    "message" to message,
                )
            )
        }
    }

    inner class RunSession(val runId: String, initialPath: String, val textHash: String?) {
        @Volatile var scriptPath: String = initialPath
        @Volatile var stopped = false
        @Volatile var waiting = false
        @Volatile var finished = false
        @Volatile var exitCode = -1
        @Volatile var endedAt = 0L
        val startedAt: Long = System.currentTimeMillis()
        val displayName: String get() = scriptPath.substringAfterLast('/')
        val input = LinkedBlockingQueue<String>()
        val ring = EventRing()
        val callback = RunCallback(this)

        // عدّاد ترقيم الأحداث. يُلمس من الخيط الرئيسي فقط (داخل emit وrun.attach)
        var seq = 0

        /** running | waiting | finished | stopped | error — تُحسب من الحالة الفعلية، لا من نيّة الإيقاف. */
        val status: String
            get() = when {
                !finished -> if (waiting) "waiting" else "running"
                exitCode == 0 -> "finished"
                exitCode == 130 -> "stopped"
                else -> "error"
            }

        /** ينهي الجلسة مرة واحدة فقط. code == null يبقي رمز الخروج كما هو. */
        @Synchronized
        fun end(code: Int?) {
            if (finished) return
            if (code != null) exitCode = code
            endedAt = System.currentTimeMillis()
            finished = true
        }

        fun summary(): Map<String, Any?> = mapOf(
            "runId" to runId,
            "scriptPath" to scriptPath,
            "status" to status,
            "startedAt" to startedAt,
            "endedAt" to endedAt,
            "exitCode" to exitCode,
            "textHash" to textHash,
        )
    }
}

/**
 * خدمة أمامية (Foreground Service) تبقي العملية حيّة أثناء عمل السكربتات.
 * النوع specialUse: غير مشمول بحدود dataSync (6 ساعات) ولا بقيود BOOT_COMPLETED.
 * تبدأ مع أول سكربت وتتوقف بعد آخر سكربت. الإشعار فيه «فتح التطبيق» و«إيقاف الكل».
 */
class BayanScriptService : Service() {
    companion object {
        private const val TAG = "BayanScriptService"
        const val CHANNEL_ID = "bayan_scripts"
        const val NOTIFICATION_ID = 7771
        const val ACTION_STOP_ALL = "com.bynux.app.action.STOP_ALL"
        const val ACTION_PIP_NEXT = "com.bynux.app.action.PIP_NEXT"

        @Volatile private var instance: BayanScriptService? = null

        /** تُستدعى من الخيط الرئيسي عند بدء سكربت. */
        fun ensureStarted(context: Context) {
            BayanPythonBridge.peek()?.refreshPipParams()
            val running = instance
            if (running != null) {
                running.refresh()
                return
            }
            try {
                val intent = Intent(context, BayanScriptService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (t: Throwable) {
                // السكربت يعمل بدون خدمة، لكن قد يُقتل عند خروج التطبيق من الشاشة
                Log.w(TAG, "foreground service could not start: ${t.message}")
            }
        }

        /** تُستدعى من الخيط الرئيسي كلما تغيّرت قائمة السكربتات الجارية. */
        fun onRunsChanged() {
            BayanPythonBridge.peek()?.refreshPipParams()
            instance?.refresh()
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var stopping = false
    private var inForeground = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        instance = this
        // startForeground أول شيء (مهلته قصيرة بعد startForegroundService)
        try {
            enterForeground(buildNotification(currentRuns()))
        } catch (t: Throwable) {
            Log.w(TAG, "startForeground failed: ${t.message}")
            if (instance === this) instance = null
            stopSelf()
            return START_NOT_STICKY
        }
        if (intent?.action == ACTION_STOP_ALL) {
            stopping = true
            BayanPythonBridge.peek()?.stopAll()
        } else if (intent?.action == ACTION_PIP_NEXT) {
            BayanPythonBridge.peek()?.requestPipNextScript()
        }
        refresh()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        releaseLocks()
        super.onDestroy()
    }

    private fun currentRuns(): List<BayanPythonBridge.RunInfo> =
        BayanPythonBridge.peek()?.activeRuns().orEmpty()

    private fun refresh() {
        val runs = currentRuns()
        if (runs.isEmpty()) {
            shutDown()
            return
        }
        acquireLocks()
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NOTIFICATION_ID, buildNotification(runs))
        } catch (t: Throwable) {
            Log.w(TAG, "notification update failed: ${t.message}")
        }
    }

    private fun shutDown() {
        // نفرّغ instance قبل stopSelf حتى يبدأ سكربت جديد خدمة جديدة بدل الاعتماد على هذه
        if (instance === this) instance = null
        releaseLocks()
        if (inForeground) {
            stopForeground(Service.STOP_FOREGROUND_REMOVE)
            inForeground = false
        }
        stopSelf()
    }

    private fun enterForeground(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        inForeground = true
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(CHANNEL_ID, "تشغيل السكربتات", NotificationManager.IMPORTANCE_LOW)
        channel.description = "إشعار دائم يظهر أثناء عمل السكربتات في الخلفية"
        channel.setShowBadge(false)
        nm.createNotificationChannel(channel)
    }

    private fun smallIcon(): Int {
        val id = resources.getIdentifier("ic_bayan_notify", "drawable", packageName)
        return if (id != 0) id else android.R.drawable.ic_dialog_info
    }

    private fun buildNotification(runs: List<BayanPythonBridge.RunInfo>): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        val title = if (runs.isEmpty()) "Bynux" else "${runs.size} سكربت يعمل"
        val text = when {
            stopping -> "جارٍ إيقاف السكربتات…"
            runs.isEmpty() -> ""
            else -> runs.joinToString("، ") { it.name }
        }
        val iconRes = smallIcon()
        builder.setSmallIcon(iconRes)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setShowWhen(true)
            .setUsesChronometer(true)
            .setWhen(runs.minOfOrNull { it.startedAt } ?: System.currentTimeMillis())
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            builder.setPriority(Notification.PRIORITY_LOW)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }

        val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        if (launch != null) {
            launch.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            val open = PendingIntent.getActivity(this, 0, launch, flags)
            builder.setContentIntent(open)
            builder.addAction(
                Notification.Action.Builder(Icon.createWithResource(this, iconRes), "فتح التطبيق", open).build()
            )
        }
        // يبقى الزر ظاهرًا أثناء «جارٍ الإيقاف» ليمكن إعادة إرسال الإيقاف
        val stopIntent = Intent(this, BayanScriptService::class.java).setAction(ACTION_STOP_ALL)
        val stop = PendingIntent.getService(this, 1, stopIntent, flags)
        builder.addAction(
            Notification.Action.Builder(Icon.createWithResource(this, iconRes), "إيقاف الكل", stop).build()
        )
        return builder.build()
    }

    private fun acquireLocks() {
        try {
            if (wakeLock == null) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Bayan:scripts").apply {
                    setReferenceCounted(false)
                }
            }
            val lock = wakeLock
            if (lock != null && !lock.isHeld) lock.acquire()

            // أندرويد 10 فما فوق: الوضعان WIFI_MODE_FULL و WIFI_MODE_FULL_HIGH_PERF مُهمَلان
            // ولا أثر لهما، والوضع الوحيد العامل (LOW_LATENCY) يشترط تطبيقًا ظاهرًا وشاشة مضاءة.
            // لذلك نستعمل قفل Wi-Fi على الإصدارات الأقدم فقط.
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                if (wifiLock == null) {
                    val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                    @Suppress("DEPRECATION")
                    wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "Bayan:wifi").apply {
                        setReferenceCounted(false)
                    }
                }
                val wifi = wifiLock
                if (wifi != null && !wifi.isHeld) wifi.acquire()
            }
        } catch (t: Throwable) {
            Log.w(TAG, "lock acquire failed: ${t.message}")
        }
    }

    private fun releaseLocks() {
        try {
            val lock = wakeLock
            if (lock != null && lock.isHeld) lock.release()
            val wifi = wifiLock
            if (wifi != null && wifi.isHeld) wifi.release()
        } catch (t: Throwable) {
            Log.w(TAG, "lock release failed: ${t.message}")
        }
    }
}

/**
 * قناة bayan/system: حالة الصلاحيات التي لا تُطلب من permission_handler، وفتح صفحات الإعدادات.
 * لا نفحص وجود أنشطة الشركات مسبقًا (أندرويد 11+ يخفي الحزم الأخرى بلا queries)، بل نجرّب
 * startActivity مباشرة ونلتقط الفشل.
 */
class BayanSystem(private val context: Context) : MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null

    fun attach(engine: FlutterEngine) {
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "bayan/system").also {
            it.setMethodCallHandler(this)
        }
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "status" -> result.success(status())
                "requestBattery" -> result.success(requestBatteryExemption())
                "openBatterySettings" ->
                    result.success(launch(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)))
                "openAppSettings" -> result.success(openAppSettings())
                "openNotificationSettings" -> result.success(openNotificationSettings())
                "openAutoStart" -> result.success(openAutoStart())
                "openBrandBattery" -> result.success(openBrandBattery())
                "openDeveloperOptions" -> result.success(openDeveloperOptions())
                "setConsent" -> {
                    val allowed = call.argument<Boolean>("allowed") == true
                    val bridge = BayanPythonBridge.get(context)
                    bridge.consentGranted = allowed
                    if (!allowed) bridge.stopAll()
                    bridge.refreshPipParams()
                    result.success(true)
                }
                "pipStatus" -> result.success(BayanPythonBridge.peek()?.inPipMode == true)
                "expandFromPip" -> result.success(BayanPythonBridge.get(context).expandFromPip())
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            result.error("system_error", t.message ?: t.javaClass.simpleName, null)
        }
    }

    private fun oemKey(): String {
        val id = (Build.MANUFACTURER.orEmpty() + " " + Build.BRAND.orEmpty()).lowercase()
        return when {
            id.contains("xiaomi") || id.contains("redmi") || id.contains("poco") -> "xiaomi"
            id.contains("samsung") -> "samsung"
            id.contains("huawei") || id.contains("honor") -> "huawei"
            id.contains("oneplus") -> "oneplus"
            id.contains("oppo") || id.contains("realme") -> "oppo"
            id.contains("vivo") || id.contains("iqoo") -> "vivo"
            // مجموعة Transsion: XOS (Infinix) وHiOS (Tecno) وitel. «itel» كلمة قصيرة فنطابقها ككلمة كاملة.
            id.contains("infinix") || id.contains("tecno") || id.contains("transsion") ||
                id.split(Regex("[^a-z0-9]+")).contains("itel") -> "transsion"
            id.contains("asus") -> "asus"
            else -> ""
        }
    }

    private fun status(): Map<String, Any?> {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return mapOf(
            "notifications" to nm.areNotificationsEnabled(),
            "battery" to pm.isIgnoringBatteryOptimizations(context.packageName),
            "manufacturer" to Build.MANUFACTURER.orEmpty(),
            "brand" to Build.BRAND.orEmpty(),
            "oem" to oemKey(),
            "sdk" to Build.VERSION.SDK_INT,
        )
    }

    private fun launch(intent: Intent): Boolean {
        return try {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            true
        } catch (t: Throwable) {
            // ActivityNotFoundException أو SecurityException (نشاط غير مُصدَّر)
            false
        }
    }

    private fun openAppSettings(): Boolean =
        launch(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))
        )

    private fun openNotificationSettings(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
            if (launch(intent)) return true
        }
        return openAppSettings()
    }

    /** "dialog" نافذة النظام المباشرة، "list" قائمة تحسين البطارية، "app" إعدادات التطبيق، "failed". */
    private fun requestBatteryExemption(): String {
        val direct = Intent(
            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            Uri.parse("package:${context.packageName}"),
        )
        if (launch(direct)) return "dialog"
        if (launch(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))) return "list"
        return if (openAppSettings()) "app" else "failed"
    }

    // أزواج (الحزمة، النشاط) لصفحات «التشغيل التلقائي/الخلفية» عند الشركات.
    // المصدر: مكتبة AutoStarter المفتوحة. كثير منها غير مُصدَّر في الإصدارات الحديثة، فنجرّب بالترتيب.
    private fun autoStartTargets(oem: String): List<Pair<String, String>> = when (oem) {
        "xiaomi" -> listOf(
            "com.miui.securitycenter" to "com.miui.permcenter.autostart.AutoStartManagementActivity",
        )
        "huawei" -> listOf(
            "com.huawei.systemmanager" to "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
            "com.huawei.systemmanager" to "com.huawei.systemmanager.optimize.process.ProtectActivity",
        )
        "oppo" -> listOf(
            "com.coloros.safecenter" to "com.coloros.safecenter.permission.startup.StartupAppListActivity",
            "com.oppo.safe" to "com.oppo.safe.permission.startup.StartupAppListActivity",
            "com.coloros.safecenter" to "com.coloros.safecenter.startupapp.StartupAppListActivity",
        )
        "oneplus" -> listOf(
            "com.oneplus.security" to "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity",
            "com.coloros.safecenter" to "com.coloros.safecenter.permission.startup.StartupAppListActivity",
        )
        "vivo" -> listOf(
            "com.iqoo.secure" to "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity",
            "com.vivo.permissionmanager" to "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
            "com.iqoo.secure" to "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager",
        )
        "samsung" -> listOf(
            "com.samsung.android.lool" to "com.samsung.android.sm.ui.battery.BatteryActivity",
            "com.samsung.android.lool" to "com.samsung.android.sm.battery.ui.usage.CheckableAppListActivity",
            "com.samsung.android.lool" to "com.samsung.android.sm.battery.ui.BatteryActivity",
            "com.samsung.android.sm" to "com.samsung.android.sm.ui.battery.BatteryActivity",
        )
        // Infinix/Tecno/itel: تطبيق Phone Master (وأسماء أقدم له). نجرّب بالترتيب ونلتقط الفشل.
        "transsion" -> listOf(
            "com.transsion.phonemaster" to "com.cyin.himgr.autostart.AutoStartActivity",
            "com.transsion.phonemanager" to "com.itel.autobootmanager.activity.AutoBootMgrActivity",
            "com.transsion.mobilebutler" to "com.transsion.mobilebutler.MainActivity",
        )
        else -> emptyList()
    }

    private fun component(pkg: String, cls: String, data: String? = null): Intent {
        val intent = Intent().setComponent(ComponentName(pkg, cls))
        if (data != null) intent.data = Uri.parse(data)
        return intent
    }

    /** "oem" فُتحت صفحة الشركة، "app" فُتحت إعدادات التطبيق بدلها، "failed". */
    private fun openAutoStart(): String {
        val oem = oemKey()
        for ((pkg, cls) in autoStartTargets(oem)) {
            if (launch(Intent().setComponent(ComponentName(pkg, cls)))) return "oem"
        }
        if (oem == "oneplus" && launch(Intent("com.android.settings.action.BACKGROUND_OPTIMIZE"))) return "oem"
        if (oem == "xiaomi" && launch(Intent("miui.intent.action.OP_AUTO_START").addCategory(Intent.CATEGORY_DEFAULT))) {
            return "oem"
        }
        if (oem == "asus") {
            val asus = listOf(
                component("com.asus.mobilemanager", "com.asus.mobilemanager.entry.FunctionActivity", "mobilemanager://function/entry/AutoStart"),
                component("com.asus.mobilemanager", "com.asus.mobilemanager.MainActivity"),
            )
            for (intent in asus) if (launch(intent)) return "oem"
        }
        return if (openAppSettings()) "app" else "failed"
    }

    /** صفحة «توفير البطارية» الخاصة بالتطبيق عند الشركة (شاومي). "oem" | "app" | "failed". */
    private fun openBrandBattery(): String {
        if (oemKey() == "xiaomi") {
            val label = context.applicationInfo.loadLabel(context.packageManager).toString()
            val intents = listOf(
                component("com.miui.powerkeeper", "com.miui.powerkeeper.ui.HiddenAppsConfigActivity")
                    .putExtra("package_name", context.packageName)
                    .putExtra("package_label", label),
                Intent("miui.intent.action.POWER_HIDE_MODE_APP_LIST").addCategory(Intent.CATEGORY_DEFAULT),
                component("com.miui.securitycenter", "com.miui.powercenter.PowerSettings"),
            )
            for (intent in intents) if (launch(intent)) return "oem"
        }
        return if (openAppSettings()) "app" else "failed"
    }

    /**
     * خيارات المطور (فيها «Suspend execution for cached apps» و«حد العمليات في الخلفية»).
     * "dev" فُتحت، "about" غير مفعّلة فتحنا «حول الهاتف» لتفعيلها، "failed".
     */
    private fun openDeveloperOptions(): String {
        val enabled = try {
            Settings.Global.getInt(context.contentResolver, Settings.Global.DEVELOPMENT_SETTINGS_ENABLED, 0) == 1
        } catch (t: Throwable) {
            false
        }
        if (enabled && launch(Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS))) return "dev"
        return if (launch(Intent(Settings.ACTION_DEVICE_INFO_SETTINGS))) return "about" else "failed"
    }
}
