package dev.pyrunner.py_runner

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
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
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue

class MainActivity : FlutterActivity() {
    private var attachedEngine: FlutterEngine? = null
    private var system: BayanSystem? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        attachedEngine = flutterEngine
        BayanPythonBridge.get(applicationContext).attach(flutterEngine)
        system = BayanSystem(applicationContext).also { it.attach(flutterEngine) }
    }

    // الواجهة وحدها تنفصل هنا. السكربتات الشغّالة لا تتوقف: الجسر يعيش مع العملية
    // وBayanScriptService يبقيها حيّة (إشعار دائم + WakeLock).
    override fun onDestroy() {
        attachedEngine?.let { BayanPythonBridge.get(applicationContext).detach(it) }
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

    private fun weight(event: Map<String, Any?>): Int =
        64 + ((event["text"] as? String)?.length ?: 0)

    fun add(event: Map<String, Any?>) {
        items.addLast(event)
        chars += weight(event)
        while (items.size > 1 && (items.size > maxEvents || chars > maxChars)) {
            val dropped = items.pollFirst() ?: break
            chars -= weight(dropped)
        }
    }

    fun snapshot(): List<Map<String, Any?>> = ArrayList(items)
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
    private val sessions = mutableMapOf<String, RunSession>()
    private val sessionsLock = Any()
    private var environmentReady = false

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

    private fun releaseChannels() {
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        methodChannel = null
        eventChannel = null
        eventSink = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        replayActiveRuns()
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    // واجهة جديدة (بعد إغلاق الأكتيفيتي) تستلم أحداث السكربتات الشغّالة من البداية
    private fun replayActiveRuns() {
        val sink = eventSink ?: return
        val active = synchronized(sessionsLock) { sessions.values.filter { !it.finished } }
        for (session in active) {
            for (event in session.ring.snapshot()) {
                sink.success(event + ("replay" to true))
            }
        }
    }

    private fun emit(values: Map<String, Any?>) {
        // التخزين والتسليم على الخيط الرئيسي معًا حتى لا يتكرر حدث بين الإعادة والبث الحي
        main.post {
            if (values["channel"] == "run") {
                val id = values["runId"] as? String
                if (id != null) {
                    synchronized(sessionsLock) { sessions[id] }?.ring?.add(values)
                }
            }
            eventSink?.success(values)
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
            sessions.values.forEach {
                it.stopped = true
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
                    sessions.clear()
                    session = RunSession(runId, scriptPath)
                    sessions[runId] = session
                }
                emit(mapOf("channel" to "run", "type" to "started", "runId" to runId))
                // الخدمة الأمامية تبدأ هنا (الواجهة ظاهرة فالبدء مسموح) وتبقي العملية حيّة
                BayanScriptService.ensureStarted(context)
                pythonExecutor.execute {
                    try {
                        val py = ensurePython()
                        val module = py.getModule("bayan_runtime")
                        module.callAttr("run_script", scriptPath, session.callback)
                    } catch (t: Throwable) {
                        if (!session.finished) {
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
                        session.finished = true
                        synchronized(sessionsLock) { sessions.remove(runId) }
                        main.post { BayanScriptService.onRunsChanged() }
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
                val session = synchronized(sessionsLock) { sessions[runId] }
                if (session == null || session.finished) {
                    complete(result, false)
                    return
                }
                session.input.offer(value)
                complete(result, true)
            }

            "stop" -> {
                val runId = call.argument<String>("runId")
                if (runId.isNullOrBlank()) {
                    fail(result, "bad_arguments", "معرف التشغيل ناقص")
                    return
                }
                val session = synchronized(sessionsLock) { sessions[runId] }
                if (session == null) {
                    complete(result, false)
                    return
                }
                session.stopped = true
                session.input.offer("")
                complete(result, true)
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
            session.exitCode = code
            session.finished = true
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

    inner class RunSession(val runId: String, val scriptPath: String) {
        @Volatile var stopped = false
        @Volatile var finished = false
        @Volatile var exitCode = -1
        val startedAt: Long = System.currentTimeMillis()
        val displayName: String = scriptPath.substringAfterLast('/')
        val input = LinkedBlockingQueue<String>()
        val ring = EventRing()
        val callback = RunCallback(this)
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
        const val ACTION_STOP_ALL = "dev.pyrunner.py_runner.action.STOP_ALL"

        @Volatile private var instance: BayanScriptService? = null

        /** تُستدعى من الخيط الرئيسي عند بدء سكربت. */
        fun ensureStarted(context: Context) {
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
        val title = if (runs.isEmpty()) "مشغّل بايثون" else "${runs.size} سكربت يعمل"
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
        )
        else -> emptyList()
    }

    /** "oem" فُتحت صفحة الشركة، "app" فُتحت إعدادات التطبيق بدلها، "failed". */
    private fun openAutoStart(): String {
        val oem = oemKey()
        for ((pkg, cls) in autoStartTargets(oem)) {
            if (launch(Intent().setComponent(ComponentName(pkg, cls)))) return "oem"
        }
        if (oem == "oneplus" && launch(Intent("com.android.settings.action.BACKGROUND_OPTIMIZE"))) return "oem"
        return if (openAppSettings()) "app" else "failed"
    }
}
