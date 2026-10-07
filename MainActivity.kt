package dev.pyrunner.py_runner

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.Build
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
    private lateinit var bridge: BayanPythonBridge

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = BayanPythonBridge(applicationContext)
        bridge.attach(flutterEngine)
    }

    override fun onDestroy() {
        if (::bridge.isInitialized) bridge.close()
        super.onDestroy()
    }
}

class BayanPythonBridge(private val context: Context) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

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
    private var eventSink: EventChannel.EventSink? = null
    private var closed = false

    fun attach(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "bayan/python").setMethodCallHandler(this)
        EventChannel(engine.dartExecutor.binaryMessenger, "bayan/python/events").setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun emit(values: Map<String, Any?>) {
        if (closed) return
        main.post { eventSink?.success(values) }
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
        if (closed) {
            fail(result, "bridge_closed", "محرك Python مغلق")
            return
        }
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
                synchronized(sessionsLock) {
                    val active = sessions.values.firstOrNull { !it.finished }
                    if (active != null) {
                        fail(result, "busy", "هناك سكربت آخر يعمل حالياً")
                        return
                    }
                    sessions.clear()
                    val session = RunSession(runId)
                    sessions[runId] = session
                    emit(mapOf("channel" to "run", "type" to "started", "runId" to runId))
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

    private fun jsonArrayToList(array: org.json.JSONArray): List<Map<String, Any?>> {
        val list = ArrayList<Map<String, Any?>>(array.length())
        for (i in 0 until array.length()) {
            val obj = array.optJSONObject(i) ?: continue
            val map = HashMap<String, Any?>()
            val keys = obj.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                map[key] = obj.opt(key).let { if (it == org.json.JSONObject.NULL) null else it }
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

    fun close() {
        closed = true
        synchronized(sessionsLock) {
            sessions.values.forEach {
                it.stopped = true
                it.input.offer("")
            }
        }
        pythonExecutor.shutdownNow()
        controlExecutor.shutdownNow()
        eventSink = null
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
        // AttributeError ويلغي التثبيت بعد أول wheel.
        @Suppress("unused")
        fun shouldStop(): Boolean = closed

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

    inner class RunSession(val runId: String) {
        @Volatile var stopped = false
        @Volatile var finished = false
        @Volatile var exitCode = -1
        val input = LinkedBlockingQueue<String>()
        val callback = RunCallback(this)
    }
}
