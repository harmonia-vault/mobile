package org.harmoniavault.harmonia_mobile.nativebridge

import android.app.Activity
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.harmoniavault.go.mobilebridge.Mobilebridge
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Cipher
import org.json.JSONObject
import org.harmoniavault.go.mobilebridge.VaultWorkflow
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager
import java.security.KeyStore
import android.util.Base64

/** Flutter 只发送受限意图；私钥材料与 Go Device 永不经过 MethodChannel。 */
class NativeBridgePlugin internal constructor(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val store: ProtectedDeviceStore = ProtectedDeviceStore(activity),
    private val workflowFilename: String = "workflow-state-v1.gcm",
    private val additionalCA: ByteArray = ByteArray(0),
    private val beforeWorkflowSave: () -> Unit = {},
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "org.harmoniavault/native/v1")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val busy = AtomicBoolean(false)
    private var cancellation: CancellationSignal? = null
    @Volatile private var disposed = false
    @Volatile private var activeWorkflow: VaultWorkflow? = null
    @Volatile private var pendingShortCode: ByteArray? = null

    init { channel.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) { result.error("LOCKED", "原生桥已关闭。", null); return }
        when (call.method) {
            "capabilities" -> {
                if (call.arguments != null) { invalid(result); return }
                result.success(mapOf("version" to 1, "goCore" to true,
                    "systemStrongAuthentication" to store.supported(), "protectedDeviceExists" to store.exists(),
                    "realVaultReady" to false, "softwareDeviceKeys" to true))
            }
            "executePublic" -> {
                val command = call.arguments as? String
                if (command == null || command.toByteArray(Charsets.UTF_8).size > 4096) { invalid(result); return }
                runWorker(result) { Mobilebridge.executePublic(command) }
            }
            "createDevice" -> {
                if (call.arguments != null) { invalid(result); return }
                authenticated(result, create = true, command = null)
            }
            "workflowProfile" -> {
                if (call.arguments != null) { invalid(result); return }
                runWorker(result) { Mobilebridge.workflowProfile() }
            }
            "executeApproval", "executeEnrollment" -> {
                val args = call.arguments as? Map<*, *>
                val command = args?.get("command") as? String
                val incoming = args?.get("shortCode") as? ByteArray
                if (args == null || args.keys != setOf("command", "shortCode") || command == null ||
                    command.toByteArray(Charsets.UTF_8).size > 32768 || incoming == null || incoming.size != 8 ||
                    incoming.any { it < 48 || it > 57 }) { incoming?.fill(0); invalid(result); return }
                // 消费通道传入缓冲；只有短暂原生副本等候本次系统认证，不写JSON或文件。
                val shortCode = incoming.copyOf(); incoming.fill(0)
                authenticated(result, create = false, command = command, workflow = true, shortCode = shortCode, enrollment = call.method == "executeEnrollment")
            }
            "executeWorkflow" -> {
                val command = call.arguments as? String
                if (command == null || command.toByteArray(Charsets.UTF_8).size > 32768) { invalid(result); return }
                authenticated(result, create = false, command = command, workflow = true)
            }
            "executeUnlocked" -> {
                val command = call.arguments as? String
                if (command == null || command.toByteArray(Charsets.UTF_8).size > 4096) { invalid(result); return }
                authenticated(result, create = false, command = command)
            }
            else -> result.notImplemented()
        }
    }

    private fun invalid(result: MethodChannel.Result) = result.error("INVALID_COMMAND", "原生业务请求不符合协议。", null)
    private fun acquire(result: MethodChannel.Result): Boolean {
        if (!busy.compareAndSet(false, true)) { result.error("BUSY", "已有原生业务操作正在进行。", null); return false }
        return true
    }
    private fun finish(result: MethodChannel.Result, value: Any? = null, code: String? = null) {
        main.post {
            busy.set(false)
            cancellation = null
            if (!disposed) {
                if (code == null) result.success(value)
                else result.error(code, "原生安全操作未完成，未授予保险库访问。", null)
            }
        }
    }
    private fun runWorker(result: MethodChannel.Result, operation: () -> Any?) {
        if (!acquire(result)) return
        worker.execute {
            try { finish(result, operation()) }
            catch (_: Exception) { finish(result, code = "GO_REJECTED") }
        }
    }

    private fun authenticated(result: MethodChannel.Result, create: Boolean, command: String?, workflow: Boolean = false, shortCode: ByteArray? = null, enrollment: Boolean = false) {
        if (!store.supported() || Build.VERSION.SDK_INT < 30) {
            clearApproval(shortCode)
            result.error("AUTH_UNAVAILABLE", "需要系统设备密码或强生物认证，当前不能生成或解包设备钥匙。", null)
            return
        }
        if (!acquire(result)) { clearApproval(shortCode); return }
        pendingShortCode = shortCode
        val cipher: Cipher
        val ciphertext: ByteArray?
        try {
            if (create) { cipher = store.prepareCreate(); ciphertext = null }
            else { val opening = store.prepareOpen(); cipher = opening.cipher; ciphertext = opening.ciphertext }
        } catch (_: Exception) { clearApproval(shortCode); finish(result, code = "PROTECTED_KEYS_UNAVAILABLE"); return }
        val consumed = AtomicBoolean(false)
        val signal = CancellationSignal()
        cancellation = signal
        val prompt = BiometricPrompt.Builder(activity)
            .setTitle("和弦设备认证")
            .setSubtitle("解锁本次设备钥匙操作")
            .setAllowedAuthenticators(ProtectedDeviceStore.AUTHENTICATORS)
            .build()
        try {
            prompt.authenticate(BiometricPrompt.CryptoObject(cipher), signal, activity.mainExecutor,
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                        if (consumed.compareAndSet(false, true)) { clearApproval(shortCode); finish(result, code = "AUTH_CANCELLED") }
                    }
                    override fun onAuthenticationFailed() {
                        if (consumed.compareAndSet(false, true)) { clearApproval(shortCode); signal.cancel(); finish(result, code = "AUTH_FAILED") }
                    }
                    override fun onAuthenticationSucceeded(authentication: BiometricPrompt.AuthenticationResult) {
                        if (!consumed.compareAndSet(false, true)) return
                        if (authentication.cryptoObject?.cipher !== cipher || disposed) { clearApproval(shortCode); finish(result, code = "AUTH_FAILED"); return }
                        worker.execute {
                            var material: ByteArray? = null
                            var device: org.harmoniavault.go.mobilebridge.Device? = null
                            try {
                                // 成功认证后才生成设备钥，取消/失败不会生成可信设备。
                                if (create) {
                                    device = Mobilebridge.newDevice()
                                    material = device.exportProtectedMaterial()
                                    store.saveAuthenticated(cipher, material)
                                    finish(result, device.execute("{\"version\":1,\"operation\":\"publicInfo\"}"))
                                } else {
                                    check(!disposed)
                                    material = store.openAuthenticated(cipher, ciphertext!!)
                                    device = Mobilebridge.importProtectedMaterial(material)
                                    material.fill(0)
                                    if (workflow) {
                                        val protected = ProtectedWorkflowStore(activity, workflowFilename, beforeWorkflowSave) { !disposed }
                                        val endpoint = JSONObject(command!!).getString("endpoint")
                                        val state = protected.load()
                                        val flow = device.openWorkflow(endpoint, protected.namespace, state, nativeCertificates(), protected)
                                        activeWorkflow = flow
                                        try {
                                            check(!disposed)
                                            val response = when {
                                                shortCode != null && enrollment -> flow.executeEnrollment(command, shortCode)
                                                shortCode != null -> flow.executeApproval(command, shortCode)
                                                else -> flow.execute(command)
                                            }
                                            if (flow.requiresDeviceDeletion()) { store.delete(); protected.delete() }
                                            check(!disposed)
                                            finish(result, response)
                                        } finally { activeWorkflow = null; flow.close(); state.fill(0) }
                                    } else finish(result, device.execute(command!!))
                                }
                            } catch (_: Exception) { finish(result, code = "GO_OR_KEYSTORE_REJECTED") }
                            finally { clearApproval(shortCode); material?.fill(0); device?.close() }
                        }
                    }
                })
        } catch (_: Exception) {
            if (consumed.compareAndSet(false, true)) { clearApproval(shortCode); finish(result, code = "AUTH_UNAVAILABLE") }
        }
    }

    /** Go标准HTTPS使用系统信任根；测试追加CA仅构造器注入，MethodChannel无此字段。 */
    private fun nativeCertificates(): ByteArray {
        val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        factory.init(null as KeyStore?)
        val roots = factory.trustManagers.filterIsInstance<X509TrustManager>().flatMap { it.acceptedIssuers.toList() }
        val pem = roots.joinToString("") { cert ->
            "-----BEGIN CERTIFICATE-----\n" + Base64.encodeToString(cert.encoded, Base64.NO_WRAP) +
                "\n-----END CERTIFICATE-----\n"
        }.toByteArray(Charsets.US_ASCII)
        return pem + additionalCA
    }

    private fun clearApproval(bytes: ByteArray?) {
        bytes?.fill(0)
        if (pendingShortCode === bytes) pendingShortCode = null
    }

    fun dispose() {
        disposed = true
        clearApproval(pendingShortCode)
        activeWorkflow?.cancel()
        cancellation?.cancel()
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }
}
