package org.harmoniavault.harmonia_mobile.productqa

import android.content.Intent
import android.content.pm.ApplicationInfo
import android.graphics.Rect
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.os.SystemClock
import android.system.Os
import android.system.OsConstants
import android.system.StructTimeval
import android.util.Log
import android.view.InputDevice
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.platform.app.InstrumentationRegistry
import org.harmoniavault.harmonia_mobile.BuildConfig
import org.json.JSONObject
import org.junit.Test
import java.io.DataInputStream
import java.io.DataOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

/**
 * 仅独立productfixture的实际用户流程驱动，不是UI单元测试。
 * 通过Android可访问节点定位后注入真实touch/key事件；不调用controller、Plugin或Go业务。
 * 所有表单值只走本机socket内存，恢复码在设备内显示/隐藏/回填，永不回传或dump节点。
 */
class NativeProductUiDriverTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val targetPackage = "org.harmoniavault.harmonia_mobile.productfixture"
    private val systemPackages = setOf("com.android.systemui", "com.android.settings", "android")
    private val automation get() = instrumentation.uiAutomation

    private class FixedFailure(val category: String) : RuntimeException()
    private fun requireFixed(condition: Boolean, category: String) {
        if (!condition) throw FixedFailure(category)
    }
    private fun exactKeys(value: JSONObject, keys: Set<String>) =
        requireFixed(value.keys().asSequence().toSet() == keys, "INVALID_COMMAND")
    private fun publicLabel(value: JSONObject): String {
        val label = value.opt("label")
        requireFixed(label is String && label.length in 1..160 &&
            !label.any { it == '\u0000' || it == '\r' || it == '\n' }, "INVALID_LABEL")
        return label as String
    }
    private fun labels(node: AccessibilityNodeInfo): Sequence<String> = sequence {
        for (text in listOf(node.text, node.contentDescription, node.hintText)) {
            if (text != null) for (line in text.toString().split('\n')) yield(line)
        }
    }
    private fun activePackage(): String? = automation.rootInActiveWindow?.let { root ->
        try { root.packageName?.toString() } finally { root.recycle() }
    }
    // 节点值只在进程RAM比较；禁止toString/log/整树返回与截图。
    private fun findNodes(allowed: Set<String>, predicate: (AccessibilityNodeInfo) -> Boolean): List<AccessibilityNodeInfo> {
        val matches = mutableListOf<AccessibilityNodeInfo>()
        val root = automation.rootInActiveWindow ?: return matches
        var visited = 0
        fun visit(node: AccessibilityNodeInfo, depth: Int) {
            try {
                requireFixed(++visited <= 4096 && depth <= 64, "ACCESSIBILITY_BOUNDED")
                if (node.packageName?.toString() in allowed && node.isVisibleToUser && predicate(node))
                    matches.add(AccessibilityNodeInfo.obtain(node))
                for (i in 0 until node.childCount) node.getChild(i)?.let { visit(it, depth + 1) }
            } finally { node.recycle() }
        }
        try { visit(root, 0); return matches }
        catch (error: Exception) { matches.forEach { it.recycle() }; throw error }
    }
    private fun unique(allowed: Set<String>, predicate: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo {
        val deadline = SystemClock.elapsedRealtime() + 15000
        while (SystemClock.elapsedRealtime() < deadline) {
            val matches = findNodes(allowed, predicate)
            if (matches.size == 1) return matches.single()
            matches.forEach { it.recycle() }
            requireFixed(matches.size <= 1, "SELECTOR_AMBIGUOUS")
            SystemClock.sleep(100)
        }
        throw FixedFailure("SELECTOR_UNAVAILABLE")
    }
    private fun tap(node: AccessibilityNodeInfo) {
        requireFixed(node.isEnabled, "CONTROL_DISABLED")
        val bounds = Rect().also { node.getBoundsInScreen(it) }
        requireFixed(!bounds.isEmpty && bounds.left >= 0 && bounds.top >= 0, "CONTROL_BOUNDS_INVALID")
        val start = SystemClock.uptimeMillis()
        for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
            val event = MotionEvent.obtain(start, SystemClock.uptimeMillis(), action,
                bounds.exactCenterX(), bounds.exactCenterY(), 0)
            try { requireFixed(automation.injectInputEvent(event, true), "TOUCH_REJECTED") }
            finally { event.recycle() }
        }
        instrumentation.waitForIdleSync()
    }
    private fun tapLabel(label: String, allowed: Set<String> = setOf(targetPackage)) {
        unique(allowed) { node -> !node.isEditable && labels(node).any { it == label } }.let { node ->
            try { tap(node) } finally { node.recycle() }
        }
    }
    private fun fill(label: String, bytes: ByteArray) {
        requireFixed(bytes.size in 1..2048 && bytes.all { it.toInt() in 32..126 }, "INPUT_NOT_SYNTHETIC_ASCII")
        val node = unique(setOf(targetPackage)) { it.isEditable && labels(it).any { text -> text == label } }
        try { tap(node) } finally { node.recycle() }
        requireFixed(activePackage() == targetPackage, "WRONG_INPUT_WINDOW")
        // 不经过adb shell argv、不读clipboard、不借UI/controller私有入口。
        instrumentation.sendStringSync(bytes.toString(Charsets.US_ASCII))
        instrumentation.waitForIdleSync()
    }
    private fun recoveryCodeReentry() {
        tapLabel("显示恢复码")
        var code: ByteArray? = null
        try {
            val shown = unique(setOf(targetPackage)) {
                !it.isEditable && labels(it).any { text -> Regex("[A-Z2-7]{52}").matches(text) }
            }
            try { code = labels(shown).single { Regex("[A-Z2-7]{52}").matches(it) }.toByteArray(Charsets.US_ASCII) }
            finally { shown.recycle() }
            tapLabel("隐藏恢复码")
            fill("完整重新输入恢复码", code!!)
        } finally { code?.fill(0) }
    }
    private fun injectSystemKey(key: Int) {
        requireFixed(activePackage() in systemPackages, "SYSTEM_PROMPT_UNAVAILABLE")
        val down = SystemClock.uptimeMillis()
        for (action in listOf(KeyEvent.ACTION_DOWN, KeyEvent.ACTION_UP)) {
            val event = KeyEvent(down, SystemClock.uptimeMillis(), action, key, 0, 0,
                KeyCharacterMap.VIRTUAL_KEYBOARD, 0, KeyEvent.FLAG_FROM_SYSTEM, InputDevice.SOURCE_KEYBOARD)
            // KeyEvent没有SDK公开recycle；不通过hidden API。注入成功仍不等于认证成功。
            requireFixed(automation.injectInputEvent(event, true), "SYSTEM_KEY_REJECTED")
        }
    }
    private fun systemCredential(pin: ByteArray) {
        requireFixed(pin.size in 6..32 && pin.all { it.toInt() in 48..57 }, "INVALID_SYNTHETIC_CREDENTIAL")
        requireFixed(activePackage() in systemPackages, "SYSTEM_PROMPT_UNAVAILABLE")
        val passwordField = unique(systemPackages) { it.isEditable && it.isPassword }
        try { tap(passwordField) } finally { passwordField.recycle() }
        requireFixed(activePackage() in systemPackages, "SYSTEM_PROMPT_UNAVAILABLE")
        for (digit in pin) {
            val key = KeyEvent.KEYCODE_0 + digit.toInt() - 48
            injectSystemKey(key)
        }
        injectSystemKey(KeyEvent.KEYCODE_ENTER)
    }
    private fun dispatch(command: JSONObject): Boolean {
        requireFixed(command.optInt("version", -1) == 1, "INVALID_COMMAND")
        when (command.optString("operation")) {
            "await" -> {
                exactKeys(command, setOf("version", "operation", "label"))
                val label = publicLabel(command)
                unique(setOf(targetPackage)) { labels(it).any { text -> text == label } }.recycle()
            }
            "tap" -> {
                exactKeys(command, setOf("version", "operation", "label"))
                tapLabel(publicLabel(command))
            }
            "fill" -> {
                exactKeys(command, setOf("version", "operation", "label", "value"))
                requireFixed(command.opt("value") is String, "INVALID_COMMAND")
                val bytes = command.getString("value").toByteArray(Charsets.UTF_8)
                try { fill(publicLabel(command), bytes) } finally { bytes.fill(0) }
            }
            "reenterDisplayedRecoveryCode" -> {
                exactKeys(command, setOf("version", "operation")); recoveryCodeReentry()
            }
            "systemTap" -> {
                exactKeys(command, setOf("version", "operation", "label"))
                val label = publicLabel(command)
                requireFixed(label in setOf("使用 PIN 码", "使用PIN码", "使用密码", "Use PIN", "Use password", "取消", "Cancel"), "INVALID_SYSTEM_LABEL")
                requireFixed(activePackage() in systemPackages, "SYSTEM_PROMPT_UNAVAILABLE")
                tapLabel(label, systemPackages)
            }
            "systemCredential" -> {
                exactKeys(command, setOf("version", "operation", "value"))
                requireFixed(command.opt("value") is String, "INVALID_COMMAND")
                val bytes = command.getString("value").toByteArray(Charsets.UTF_8)
                try { systemCredential(bytes) } finally { bytes.fill(0) }
            }
            "finish" -> { exactKeys(command, setOf("version", "operation")); return false }
            else -> throw FixedFailure("INVALID_COMMAND")
        }
        return true
    }
    private fun read(input: DataInputStream): JSONObject {
        val size = input.readInt()
        requireFixed(size in 1..32768, "FRAME_BOUNDED")
        val raw = ByteArray(size)
        try {
            input.readFully(raw)
            val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(raw)).toString()
            return JSONObject(ProductQaCommand.parse(text))
        } finally { raw.fill(0) }
    }
    private fun reply(output: DataOutputStream, sequence: Int, error: String? = null) {
        val result = JSONObject().put("version", 1).put("sequence", sequence)
            .put("status", if (error == null) "ok" else "failed")
        if (error != null) result.put("error", error)
        val bytes = result.toString().toByteArray(Charsets.US_ASCII)
        output.writeInt(bytes.size); output.write(bytes); output.flush()
    }
    @Test fun driveActualProductWidgets() {
        requireFixed(BuildConfig.DEBUG && BuildConfig.HARMONIA_PRODUCT_FIXTURE &&
            context.packageName == targetPackage &&
            context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0, "WRONG_TEST_TARGET")
        val name = InstrumentationRegistry.getArguments().getString("qaSocket") ?: ""
        requireFixed(Regex("harmonia-product-qa-[a-z0-9]{16}").matches(name), "INVALID_SOCKET_NAMESPACE")
        val activity = instrumentation.startActivitySync(Intent().setClassName(targetPackage,
            "org.harmoniavault.harmonia_mobile.MainActivity").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        try {
            LocalServerSocket(name).use { server ->
                Os.setsockoptTimeval(server.fileDescriptor, OsConstants.SOL_SOCKET,
                    OsConstants.SO_RCVTIMEO, StructTimeval.fromMillis(180000))
                Log.i("HarmoniaProductQA", "QA_DRIVER_READY")
                server.accept().use { socket ->
                    socket.soTimeout = 180000
                    requireFixed(socket.peerCredentials.uid in setOf(0, 2000, context.applicationInfo.uid), "LOCAL_PEER_REJECTED")
                    val input = DataInputStream(socket.inputStream)
                    val output = DataOutputStream(socket.outputStream)
                    val magic = ByteArray(8)
                    input.readFully(magic)
                    requireFixed(magic.contentEquals("HPRDQA01".toByteArray(Charsets.US_ASCII)), "INVALID_HANDSHAKE")
                    var running = true
                    var sequence = 0
                    while (running && sequence < 256) {
                        sequence++
                        try { running = dispatch(read(input)); reply(output, sequence) }
                        catch (error: FixedFailure) { reply(output, sequence, error.category); throw AssertionError("product QA fixed failure") }
                        catch (error: Exception) { reply(output, sequence, "DRIVER_REJECTED"); throw AssertionError("product QA fixed failure") }
                    }
                    requireFixed(!running, "COMMANDS_BOUNDED")
                }
            }
            Log.i("HarmoniaProductQA", "QA_DRIVER_FINISHED")
        } catch (error: Exception) { throw AssertionError("product QA fixed failure") }
        finally { instrumentation.runOnMainSync { activity.finish() } }
    }
}
