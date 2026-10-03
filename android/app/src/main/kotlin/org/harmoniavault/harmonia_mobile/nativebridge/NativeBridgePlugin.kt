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
import org.harmoniavault.harmonia_mobile.nativebridge.pinlocal.*
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
    // 仅内部原生构造器的合成故障注入；默认空，通道不能设置，接收的仍只有AES密文。
    private val beforeWorkflowPacketSave: (ByteArray) -> Unit = {},
    private val beforeWorkflowSave: () -> Unit = {},
    private val productFixture: ProductFixtureConfiguration? = null,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "org.harmoniavault/native/v1")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val busy = AtomicBoolean(false)
    // 仅本插件进程持有；Go内部随机instance/handle/EdOwner不跨MethodChannel或磁盘。
    private val recoveryRegistry = Mobilebridge.newRecoveryRegistry(activity.packageName, workflowFilename)
    private var cancellation: CancellationSignal? = null
    @Volatile private var disposed = false
    @Volatile private var activeWorkflow: VaultWorkflow? = null
    @Volatile private var pendingShortCode: ByteArray? = null

    private val pinOwnerGate = PinOperationOwnerGate<NativePinOperation> { it.cancel() }
    @Volatile private var pendingPIN: PinChannelRequest? = null
    private val pinDispatcher = PinMethodChannelDispatcher(activity, workflowFilename,
        { store.hasArtifacts() || ProtectedWorkflowStore(activity, workflowFilename).hasArtifacts() },
        { recoveryRegistry.clear() }, { nativeCertificates() }, pinOwnerGate::register)

    init {
        check(productFixture == null || additionalCA.contentEquals(productFixture.publicCA()))
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) { result.error("LOCKED", "原生桥已关闭。", null); return }
        if (call.method in PinMethodChannelDispatcher.METHODS) { pinMethod(call, result); return }
        when (call.method) {
            "fixtureConnectionInfo" -> {
                if (call.arguments != null) { invalid(result); return }
                val fixture = productFixture
                if (fixture == null) result.notImplemented() else result.success(fixture.attestation())
            }
            "capabilities" -> {
                if (call.arguments != null) { invalid(result); return }
                try {
                    val pinExists = pinDispatcher.hasArtifacts()
                    result.success(mapOf("version" to 1, "goCore" to true,
                        "systemStrongAuthentication" to (!pinExists && store.supported()), "protectedDeviceExists" to store.exists(),
                        "appPINDeviceExists" to pinExists,
                        // 仅表示PIN业务ABI已接入；资格/受保护状态/逐项证据仍另行检查。
                        "appPINWorkflowReady" to true,
                        "realVaultReady" to false, "softwareDeviceKeys" to true))
                } catch (_: Exception) { recoveryRegistry.clear(); result.error("LOCAL_PROTECTION_STATE", "本机保护状态不可用。", null) }
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
                if (!acceptsWorkflowEndpoint(command)) { incoming.fill(0); invalid(result); return }
                // 消费通道传入缓冲；只有短暂原生副本等候本次系统认证，不写JSON或文件。
                val shortCode = incoming.copyOf(); incoming.fill(0)
                authenticated(result, create = false, command = command, workflow = true, shortCode = shortCode, enrollment = call.method == "executeEnrollment")
            }
            "executeWorkflow" -> {
                val command = call.arguments as? String
                if (command == null || command.toByteArray(Charsets.UTF_8).size > 32768) { invalid(result); return }
                if (!acceptsWorkflowEndpoint(command)) { invalid(result); return }
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

    private fun pinMethod(call: MethodCall, result: MethodChannel.Result) {
        val request = try { PinChannelRequest.parse(call.method, call.arguments) }
            catch (_: Exception) { invalid(result); return }
        if (!acceptsEndpoint(request.endpoint)) { request.close(); invalid(result); return }
        if (!acquire(result)) { request.close(); return }
        pendingPIN = request
        worker.execute {
            try {
                check(!disposed)
                val value = pinDispatcher.execute(request)
                check(!disposed)
                finish(result, value)
            } catch (failure: PinLocalException) {
                recoveryRegistry.clear()
                val code = when (failure.fault) {
                    PinLocalFault.BUSY -> "BUSY"
                    PinLocalFault.CONFIGURATION -> "INVALID_COMMAND"
                    PinLocalFault.UPGRADE_REQUIRED -> "PIN_UPGRADE_REQUIRED"
                    PinLocalFault.PERSISTENCE -> "LOCAL_PROTECTION_PERSISTENCE"
                    PinLocalFault.STATE -> "LOCAL_PROTECTION_STATE"
                    PinLocalFault.AUTHENTICATION -> "PIN_AUTH_FAILED"
                    PinLocalFault.CLOSED -> "PIN_BLOCKED"
                    PinLocalFault.BLOCKED -> "PIN_BLOCKED"
                }
                finish(result, code = code)
            } catch (_: Exception) { recoveryRegistry.clear(); finish(result, code = "PIN_BLOCKED") }
            finally { request.close(); if (pendingPIN === request) pendingPIN = null }
        }
    }

    private fun acceptsEndpoint(endpoint: String): Boolean = productFixture?.acceptsEndpoint(endpoint) ?: true

    private fun acceptsWorkflowEndpoint(command: String): Boolean = productFixture?.let { fixture ->
        try { fixture.acceptsEndpoint(JSONObject(command).getString("endpoint")) }
        catch (_: Exception) { false }
    } ?: true

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
        // 既有PIN包/alias/坏状态不能因系统后来可用而走新的系统provider。
        // 此endpoint-less入口仅拒绝；实际PIN info/operation会持久升级latch。
        val hasPIN = try { pinDispatcher.hasArtifacts() } catch (_: Exception) {
            clearApproval(shortCode); recoveryRegistry.clear(); result.error("LOCAL_PROTECTION_STATE", "本机保护状态不可用。", null); return
        }
        if (hasPIN) { clearApproval(shortCode); recoveryRegistry.clear(); result.error("PIN_UPGRADE_REQUIRED", "当前为PIN保护模式；不能自动切换系统provider。", null); return }
        if (!store.supported() || Build.VERSION.SDK_INT < 30) {
            clearApproval(shortCode)
            recoveryRegistry.clear()
            result.error("AUTH_UNAVAILABLE", "需要系统设备密码或强生物认证，当前不能生成或解包设备钥匙。", null)
            return
        }
        if (!acquire(result)) { clearApproval(shortCode); return }
        pendingShortCode = shortCode
        val cipher: Cipher
        val ciphertext: ByteArray?
        try {
            if (create) { recoveryRegistry.clear(); cipher = store.prepareCreate(); ciphertext = null }
            else { val opening = store.prepareOpen(); cipher = opening.cipher; ciphertext = opening.ciphertext }
        } catch (_: Exception) { recoveryRegistry.clear(); clearApproval(shortCode); finish(result, code = "PROTECTED_KEYS_UNAVAILABLE"); return }
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
                        if (consumed.compareAndSet(false, true)) { recoveryRegistry.clear(); clearApproval(shortCode); finish(result, code = "AUTH_CANCELLED") }
                    }
                    override fun onAuthenticationFailed() {
                        if (consumed.compareAndSet(false, true)) { recoveryRegistry.clear(); clearApproval(shortCode); signal.cancel(); finish(result, code = "AUTH_FAILED") }
                    }
                    override fun onAuthenticationSucceeded(authentication: BiometricPrompt.AuthenticationResult) {
                        if (!consumed.compareAndSet(false, true)) return
                        if (authentication.cryptoObject?.cipher !== cipher || disposed) { recoveryRegistry.clear(); clearApproval(shortCode); finish(result, code = "AUTH_FAILED"); return }
                        worker.execute {
                            var material: ByteArray? = null
                            var device: org.harmoniavault.go.mobilebridge.Device? = null
                            try {
                                // 成功认证后才生成设备钥，取消/失败不会生成可信设备。
                                if (create) {
                                    device = Mobilebridge.newDevice()
                                    material = device.exportProtectedMaterial()
                                    store.saveAuthenticated(cipher, material)
                                    recoveryRegistry.resetForNewDevice()
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
                                        val writer = object : org.harmoniavault.go.mobilebridge.SealedStateStore {
                                            override fun saveSealed(packet: ByteArray) {
                                                beforeWorkflowPacketSave(packet)
                                                protected.saveSealed(packet)
                                            }
                                        }
                                        val flow = device.openWorkflow(endpoint, protected.namespace, state, nativeCertificates(), writer)
                                        activeWorkflow = flow
                                        try {
                                            check(!disposed)
                                            flow.attachRecoveryRegistry(recoveryRegistry)
                                            val response = when {
                                                shortCode != null && enrollment -> flow.executeEnrollment(command, shortCode)
                                                shortCode != null -> flow.executeApproval(command, shortCode)
                                                else -> flow.execute(command)
                                            }
                                            if (flow.requiresDeviceDeletion()) { recoveryRegistry.clear(); store.delete(); protected.delete() }
                                            check(!disposed)
                                            finish(result, response)
                                        } finally { activeWorkflow = null; flow.close(); state.fill(0) }
                                    } else finish(result, device.execute(command!!))
                                }
                            } catch (_: Exception) { recoveryRegistry.clear(); finish(result, code = "GO_OR_KEYSTORE_REJECTED") }
                            finally { clearApproval(shortCode); material?.fill(0); device?.close() }
                        }
                    }
                })
        } catch (_: Exception) {
            if (consumed.compareAndSet(false, true)) { recoveryRegistry.clear(); clearApproval(shortCode); finish(result, code = "AUTH_UNAVAILABLE") }
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
        // 所有owner分别尝试关闭；某一取消失败也不能阻止其它输入/通道退役。
        var failed = false
        try { pinOwnerGate.retire { disposed = true } } catch (_: Exception) { failed = true }
        try { recoveryRegistry.close() } catch (_: Exception) { failed = true }
        pendingPIN?.close()
        clearApproval(pendingShortCode)
        try { activeWorkflow?.cancel() } catch (_: Exception) { failed = true }
        try { cancellation?.cancel() } catch (_: Exception) { failed = true }
        channel.setMethodCallHandler(null)
        worker.shutdown()
        if (failed) throw IllegalStateException("native owner cleanup unconfirmed")
    }
}
