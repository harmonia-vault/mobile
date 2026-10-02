package org.harmoniavault.harmonia_mobile.nativebridge

import android.app.Activity
import android.content.Intent
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.harmoniavault.harmonia_mobile.MainActivity
import org.json.JSONObject
import org.junit.Test
import org.junit.Assert.*
import java.io.File
import java.nio.ByteBuffer
import java.security.KeyStore
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** 只在显式合成锁屏的隔离 AVD 手动验收系统认证；不断言/自动操作 Flutter UI。 */
class NativeCredentialIntegrationTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val alias = "harmonia/synthetic-credential-test/v1"
    private val filename = "synthetic-credential-test.gcm"
    private val messenger = object : BinaryMessenger {
        override fun send(channel: String, message: ByteBuffer?) {}
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {}
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {}
    }
    private fun cleanup() {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (keyStore.containsAlias(alias)) keyStore.deleteEntry(alias)
        val file = File(File(instrumentation.targetContext.noBackupFilesDir, "harmonia"), filename)
        file.delete(); File(file.path + ".bak").delete(); File(file.path + ".new").delete()
    }
    private fun activity(): Activity = instrumentation.startActivitySync(
        Intent(instrumentation.targetContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
    )
    private class Outcome : MethodChannel.Result {
        val ready = CountDownLatch(1)
        var value: Any? = null
        var code: String? = null
        override fun success(result: Any?) { value = result; ready.countDown() }
        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) { code = errorCode; ready.countDown() }
        override fun notImplemented() { code = "NOT_IMPLEMENTED"; ready.countDown() }
    }
    private fun request(plugin: NativeBridgePlugin, method: String, args: Any?): Outcome {
        val outcome = Outcome()
        instrumentation.runOnMainSync { plugin.onMethodCall(MethodCall(method, args), outcome) }
        Log.i("HarmoniaNativeTest", "AWAIT_SYSTEM_AUTH:$method")
        assertTrue("system authentication callback timed out", outcome.ready.await(60, TimeUnit.SECONDS))
        return outcome
    }
    @Test fun testSystemCredentialProtectedLifecycle() {
        cleanup()
        val context = instrumentation.targetContext
        val store = ProtectedDeviceStore(context, alias, filename)
        assertTrue("explicit synthetic device credential required", store.supported())
        val activity = activity()
        lateinit var plugin: NativeBridgePlugin
        instrumentation.runOnMainSync { plugin = NativeBridgePlugin(activity, messenger, store) }
        try {
            val created = request(plugin, "createDevice", null)
            assertNull("create failed", created.code)
            val public = JSONObject(created.value as String)
            assertFalse(public.getBoolean("trusted"))
            assertTrue(store.exists())
            val materialFile = File(File(context.noBackupFilesDir, "harmonia"), filename).readBytes()
            assertEquals(108, materialFile.size)
            assertFalse(String(materialFile, Charsets.ISO_8859_1).contains("HARMKEY1"))
            // 新的 cipher 未通过认证，不能因为上一轮成功就再次解包。
            val unauthorized = store.prepareOpen()
            try { store.openAuthenticated(unauthorized.cipher, unauthorized.ciphertext); fail("prior authentication reused") }
            catch (_: Exception) { /* 每次必须认证。 */ }
            val checked = request(plugin, "executeUnlocked", "{\"version\":1,\"operation\":\"cryptoCheck\"}")
            assertNull("protected crypto failed", checked.code)
            assertTrue(JSONObject(checked.value as String).getBoolean("hpke"))
            assertFalse(JSONObject(checked.value as String).getBoolean("trusted"))
            val reopened = request(plugin, "executeUnlocked", "{\"version\":1,\"operation\":\"publicInfo\"}")
            assertNull("protected identity failed", reopened.code)
            assertEquals(created.value, reopened.value)
        } finally {
            instrumentation.runOnMainSync { plugin.dispose(); activity.finish() }
            cleanup()
        }
    }
    @Test fun testCancelledAuthenticationCreatesNoDevice() {
        cleanup()
        val store = ProtectedDeviceStore(instrumentation.targetContext, alias, filename)
        assertTrue("explicit synthetic device credential required", store.supported())
        val activity = activity()
        lateinit var plugin: NativeBridgePlugin
        instrumentation.runOnMainSync { plugin = NativeBridgePlugin(activity, messenger, store) }
        try {
            val cancelled = request(plugin, "createDevice", null)
            assertEquals("AUTH_CANCELLED", cancelled.code)
            assertNull(cancelled.value)
            assertFalse(store.exists())
        } finally {
            instrumentation.runOnMainSync { plugin.dispose(); activity.finish() }
            cleanup()
        }
    }
}
