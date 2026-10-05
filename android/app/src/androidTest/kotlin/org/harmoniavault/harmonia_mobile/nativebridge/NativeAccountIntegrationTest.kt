package org.harmoniavault.harmonia_mobile.nativebridge

import android.content.Intent
import android.util.Base64
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.harmoniavault.harmonia_mobile.MainActivity
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.net.URL
import java.nio.ByteBuffer
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory

/** 仅合成账号和独立槽：每op真实CryptoObject，原ID跨两次真实进程停止，不测试Flutter UI。 */
class NativeAccountIntegrationTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val alias = "harmonia/synthetic-account-native/v1"
    private val keyFilename = "synthetic-account-key.gcm"
    private val stateFilename = "synthetic-account-state.gcm"
    private val endpoint = "https://10.0.2.2:4443"
    private val ca = Base64.decode(InstrumentationRegistry.getArguments().getString("syntheticCA")!!, Base64.NO_WRAP)
    private val messenger = object : BinaryMessenger {
        override fun send(channel: String, message: ByteBuffer?) {}
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {}
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {}
    }
    private class Outcome : MethodChannel.Result {
        val ready = CountDownLatch(1)
        var value: Any? = null
        var code: String? = null
        override fun success(result: Any?) { value = result; ready.countDown() }
        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) { code = errorCode; ready.countDown() }
        override fun notImplemented() { code = "NOT_IMPLEMENTED"; ready.countDown() }
    }
    private fun request(plugin: NativeBridgePlugin, method: String, args: Any?, stage: String): JSONObject {
        val out = Outcome()
        instrumentation.runOnMainSync { plugin.onMethodCall(MethodCall(method, args), out) }
        Log.i("HarmoniaNativeTest", "AWAIT_ACCOUNT_AUTH:$stage")
        assertTrue("native authenticated operation timed out", out.ready.await(90, TimeUnit.SECONDS))
        assertNull("native operation fixed platform rejection", out.code)
        return JSONObject(out.value as String)
    }
    private fun execute(plugin: NativeBridgePlugin, operation: String, fields: Map<String, String> = emptyMap()): JSONObject {
        val command = JSONObject().put("version", 1).put("operation", operation).put("endpoint", endpoint)
        fields.forEach { (key, value) -> command.put(key, value) }
        return request(plugin, "executeWorkflow", command.toString(), operation)
    }
    private fun data(result: JSONObject): JSONObject {
        assertTrue("business operation rejected", result.getBoolean("ok"))
        return result.getJSONObject("data")
    }
    private fun https(path: String, body: JSONObject? = null): String {
        val certificate = CertificateFactory.getInstance("X.509").generateCertificate(ca.inputStream())
        val trust = KeyStore.getInstance(KeyStore.getDefaultType()).apply { load(null); setCertificateEntry("synthetic-ca", certificate) }
        val manager = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(trust) }
        val tls = SSLContext.getInstance("TLS").apply { init(null, manager.trustManagers, null) }
        val connection = URL(endpoint + path).openConnection() as HttpsURLConnection
        connection.sslSocketFactory = tls.socketFactory; connection.connectTimeout = 5000; connection.readTimeout = 5000
        if (body != null) {
            connection.requestMethod = "POST"; connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.outputStream.use { it.write(body.toString().toByteArray()) }
        }
        try {
            assertEquals("synthetic HTTPS fixture unavailable", 200, connection.responseCode)
            return connection.inputStream.bufferedReader().use { it.readText() }
        } finally { connection.disconnect() }
    }
    private fun cleanup() {
        val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (keys.containsAlias(alias)) keys.deleteEntry(alias)
        listOf(keyFilename, stateFilename).forEach { name ->
            val file = File(File(context.noBackupFilesDir, "harmonia"), name)
            file.delete(); File(file.path + ".bak").delete(); File(file.path + ".new").delete()
        }
    }
    private fun withPlugin(operation: (NativeBridgePlugin, ProtectedDeviceStore) -> Unit) {
        val activity = instrumentation.startActivitySync(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        val store = ProtectedDeviceStore(context, alias, keyFilename)
        lateinit var plugin: NativeBridgePlugin
        instrumentation.runOnMainSync { plugin = NativeBridgePlugin(activity, messenger, store, stateFilename, ca) }
        try { operation(plugin, store) }
        finally { instrumentation.runOnMainSync { plugin.dispose(); activity.finish() } }
    }
    private fun restore(plugin: NativeBridgePlugin): JSONObject {
        val result = data(execute(plugin, "restoreSession"))
        assertEquals(setOf("trustedDevice", "accountId", "accountGeneration", "deviceId", "view"), result.keys().asSequence().toSet())
        assertTrue("verified session not trusted", result.getBoolean("trustedDevice"))
        assertTrue(result.getString("accountId").isNotBlank())
        assertTrue(result.getString("accountGeneration").toLong() > 0)
        assertEquals(result.getString("deviceId"), result.getJSONObject("view").getString("deviceId"))
        return result
    }
    private fun pending(plugin: NativeBridgePlugin, id: String): JSONObject {
        val result = execute(plugin, "businessPendingInfo")
        assertTrue(result.getBoolean("ok"))
        val list = result.getJSONArray("data")
        var selected: JSONObject? = null
        for (i in 0 until list.length()) if (list.getJSONObject(i).getString("id") == id) selected = list.getJSONObject(i)
        assertNotNull("original sealed operation missing", selected)
        assertEquals(setOf("id", "operation", "environmentId", "state", "sequence", "applied"), selected!!.keys().asSequence().toSet())
        assertFalse(selected!!.getBoolean("applied"))
        return selected!!
    }
    @Test fun test01LoginDoesNotTrustAndOriginalVariablePending() {
        cleanup()
        withPlugin { plugin, store ->
            val device = request(plugin, "createDevice", null, "createDevice")
            assertFalse(device.getBoolean("trusted"))
            val email = "native-account-${System.currentTimeMillis()}@example.invalid"
            val password = "synthetic-native-account-password"
            val registration = data(execute(plugin, "register", mapOf("email" to email, "password" to password)))
            assertTrue(registration.getBoolean("verificationRequired"))
            val emails = JSONArray(https("/test/emails")); var proof: JSONObject? = null
            for (i in 0 until emails.length()) {
                val message = emails.getJSONObject(i)
                if (message.getString("to") == email) for (line in message.getString("text").split('\n')) if (Regex("^[2-9A-HJ-NP-Z]{8}$").matches(line)) proof = JSONObject().put("accountId", registration.getString("accountId")).put("accountGeneration", registration.getString("accountGeneration")).put("code", line)
            }
            assertNotNull("synthetic email proof missing", proof)
            assertTrue(execute(plugin, "verifyEmail", listOf("accountId", "accountGeneration", "code").associateWith { proof!!.getString(it) }).getBoolean("ok"))
            val wrong = execute(plugin, "loginAccount", mapOf("email" to email, "password" to "synthetic-wrong-password"))
            assertFalse(wrong.getBoolean("ok")); assertFalse(wrong.has("data"))
            val login = data(execute(plugin, "loginAccount", mapOf("email" to email, "password" to password)))
            assertEquals(setOf("authenticated", "trustedDevice"), login.keys().asSequence().toSet())
            assertTrue(login.getBoolean("authenticated")); assertFalse(login.getBoolean("trustedDevice"))
            val untrusted = execute(plugin, "restoreSession")
            assertFalse(untrusted.getBoolean("ok")); assertFalse(untrusted.has("data")); assertEquals("NOT_TRUSTED", untrusted.getString("code"))
            val begin = execute(plugin, "beginInitialization", mapOf("email" to email, "password" to password, "name" to "合成账号环境", "id" to "native-account-initialization"))
            assertTrue(begin.getBoolean("ok"))
            val code = begin.getString("recoveryCode")
            assertEquals(52, code.length)
            val initialized = data(execute(plugin, "completeInitialization", mapOf("recoveryCode" to code)))
            val session = restore(plugin)
            assertEquals(registration.getString("accountId"), session.getString("accountId"))
            assertEquals(registration.getString("accountGeneration"), session.getString("accountGeneration"))
            assertEquals(device.getString("deviceId"), session.getString("deviceId"))
            val environment = initialized.getJSONArray("environments").getJSONObject(0).getString("id")
            https("/test/control", JSONObject().put("lose", "mutation"))
            val unknown = execute(plugin, "setVariable", mapOf("environmentId" to environment, "name" to "SYNTHETIC_ACCOUNT", "value" to "synthetic-account-value", "id" to "native-account-write"))
            assertFalse(unknown.getBoolean("ok")); assertEquals("PENDING", unknown.getString("code"))
            pending(plugin, "native-account-write")
            assertEquals(1, JSONObject(https("/test/counters")).getInt("mutations"))
            assertTrue(store.exists())
        }
    }
    @Test fun test02OriginalVariableRetryAfterProcessDeathAndEnvironmentPending() {
        withPlugin { plugin, store ->
            assertTrue(store.exists())
            pending(plugin, "native-account-write")
            val applied = data(execute(plugin, "retryBusinessOperation", mapOf("id" to "native-account-write")))
            assertTrue(applied.getBoolean("applied")); assertEquals("applied", applied.getString("state"))
            assertEquals("native-account-write", applied.getString("id"))
            assertEquals(1, JSONObject(https("/test/counters")).getInt("mutations"))
            val session = restore(plugin)
            val environment = session.getJSONObject("view").getJSONArray("environments").getJSONObject(0)
            assertEquals("synthetic-account-value", environment.getJSONObject("variables").getString("SYNTHETIC_ACCOUNT"))
            val baseline = JSONObject(https("/test/counters"))
            assertEquals(1, baseline.getInt("environmentChanges"))
            assertEquals(1, baseline.getInt("environmentAttempts"))
            https("/test/control", JSONObject().put("lose", "environment"))
            val unknown = execute(plugin, "createEnvironment", mapOf("name" to "合成续办环境", "id" to "native-account-create"))
            val diagnostic = JSONObject(https("/test/counters"))
            Log.i("HarmoniaNativeTest", "ACCOUNT_ENV_DIAGNOSTIC:accepted=${diagnostic.getInt("environmentChanges")},attempts=${diagnostic.getInt("environmentAttempts")},status=${diagnostic.getInt("environmentStatus")},controlStatus=${diagnostic.getInt("environmentControlStatus")},mutations=${diagnostic.getInt("mutations")}")
            assertFalse(unknown.getBoolean("ok")); assertEquals("REJECTED", unknown.getString("code"))
            assertTrue(unknown.getBoolean("retrySameId"))
            assertEquals("unknown", pending(plugin, "native-account-create").getString("state"))
            val after = JSONObject(https("/test/counters"))
            assertEquals(1, after.getInt("environmentChanges") - baseline.getInt("environmentChanges"))
            assertEquals(1, after.getInt("environmentAttempts") - baseline.getInt("environmentAttempts"))
            assertEquals(2, after.getInt("environmentChanges"))
        }
    }
    @Test fun test03OriginalEnvironmentRetryRestoreAndLogout() {
        withPlugin { plugin, store ->
            try {
                val beforeRetry = JSONObject(https("/test/counters"))
                assertEquals(2, beforeRetry.getInt("environmentChanges"))
                assertEquals(2, beforeRetry.getInt("environmentAttempts"))
                pending(plugin, "native-account-create")
                val applied = data(execute(plugin, "retryBusinessOperation", mapOf("id" to "native-account-create")))
                assertTrue(applied.getBoolean("applied")); assertEquals("applied", applied.getString("state"))
                assertEquals("native-account-create", applied.getString("id"))
                val counters = JSONObject(https("/test/counters"))
                assertEquals(2, counters.getInt("environmentChanges"))
                assertEquals(2, counters.getInt("environmentAttempts"))
                val before = restore(plugin)
                assertEquals(2, before.getJSONObject("view").getJSONArray("environments").length())
                val repeated = data(execute(plugin, "retryBusinessOperation", mapOf("id" to "native-account-create")))
                assertTrue(repeated.getBoolean("applied"))
                val repeatedCounters = JSONObject(https("/test/counters"))
                assertEquals(2, repeatedCounters.getInt("environmentChanges"))
                assertEquals(2, repeatedCounters.getInt("environmentAttempts"))
                val after = restore(plugin)
                assertEquals(before.getJSONObject("view").getLong("checkpoint"), after.getJSONObject("view").getLong("checkpoint"))
                val logout = execute(plugin, "logout")
                assertTrue(logout.getBoolean("ok")); assertFalse(store.exists())
                assertFalse(File(File(context.noBackupFilesDir, "harmonia"), stateFilename).exists())
                val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
                assertFalse(keys.containsAlias(alias))
                val missing = Outcome()
                val command = JSONObject().put("version", 1).put("operation", "restoreSession").put("endpoint", endpoint).toString()
                instrumentation.runOnMainSync { plugin.onMethodCall(MethodCall("executeWorkflow", command), missing) }
                assertTrue(missing.ready.await(10, TimeUnit.SECONDS)); assertEquals("PROTECTED_KEYS_UNAVAILABLE", missing.code)
            } finally { cleanup() }
        }
    }
}
