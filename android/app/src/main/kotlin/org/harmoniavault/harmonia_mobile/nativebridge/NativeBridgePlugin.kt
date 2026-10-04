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
    store: ProtectedDeviceStore = ProtectedDeviceStore(activity),
    private val workflowFilename: String = "workflow-state-v1.gcm",
    private val additionalCA: ByteArray = ByteArray(0),
    // 仅内部原生构造器的合成故障注入；默认空，通道不能设置，接收的仍只有AES密文。
    private val beforeWorkflowPacketSave: (ByteArray) -> Unit = {},
    private val beforeWorkflowSave: () -> Unit = {},
    private val productFixture: ProductFixtureConfiguration? = null,
) : MethodChannel.MethodCallHandler {
    private val store = store.withWorkflowSlot(workflowFilename)
    private val channel = MethodChannel(messenger, "org.harmoniavault/native/v1")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val busy = AtomicBoolean(false)
    private val endpointScope = NativeControlledEndpointScope()
    private val ownerCleanupUnconfirmed = AtomicBoolean(false)
    // 仅本插件进程持有；Go内部随机instance/handle/EdOwner不跨MethodChannel或磁盘。
    private val recoveryRegistry = Mobilebridge.newRecoveryRegistry(activity.packageName, workflowFilename)
    private var cancellation: CancellationSignal? = null
    @Volatile private var disposed = false
    @Volatile private var activeWorkflow: VaultWorkflow? = null
    @Volatile private var pendingShortCode: ByteArray? = null
    @Volatile private var activeSlotOwner: NativeSlotOwner? = null

    private val pinOwnerGate = PinOperationOwnerGate<NativePinOperation> { it.cancel() }
    @Volatile private var pendingPIN: PinChannelRequest? = null
    private val pinDispatcher = PinMethodChannelDispatcher(activity, workflowFilename,
        { store.hasArtifacts() || ProtectedWorkflowStore(activity, workflowFilename).hasArtifacts() },
        { recoveryRegistry.invalidate() }, { nativeCertificates() }, pinOwnerGate::register)

    // 严格 typed 原生入口；编译能力与逐项独立运行证据分开，whole ready仍关闭。
    private val dagDispatcher: NativeDAGRecoveryDispatcher = NativeDAGRecoveryDispatcher(activity, this.store, workflowFilename,
        ::nativeCertificates, ::acceptsEndpoint, { !disposed && !ownerCleanupUnconfirmed.get() && !busy.get() && !dagBusinessBusy() && !dagEnvironmentBusy() && !resetDispatcher.isBusy() && !pendingPairingsBusy() && !mailBusy() }, pinDispatcher::hasArtifacts, endpointScope::workflowOpened)
    private val pendingPairingsDispatcher: NativePendingPairingsDispatcher = NativePendingPairingsDispatcher(activity, this.store, workflowFilename,
        ::nativeCertificates, ::acceptsEndpoint, { !disposed && !ownerCleanupUnconfirmed.get() && !busy.get() && !dagBusinessBusy() && !dagEnvironmentBusy() && !dagDispatcher.isBusy() && !resetDispatcher.isBusy() && !mailBusy() }, pinDispatcher::hasArtifacts, endpointScope::workflowOpened)
    private val resetMailDispatcher: NativeAccountResetMailDispatcher = NativeAccountResetMailDispatcher(activity, workflowFilename,
        ::nativeCertificates, ::acceptsEndpoint, { !disposed && !ownerCleanupUnconfirmed.get() && !busy.get() && !dagBusinessBusy() && !dagEnvironmentBusy() && !dagDispatcher.isBusy() && !pendingPairingsBusy() && !resetDispatcher.isBusy() && !resetDispatcher.hasOwner() })
    private val resetDispatcher: NativeAccountResetDispatcher = NativeAccountResetDispatcher(activity, this.store, workflowFilename,
        ::nativeCertificates, ::acceptsEndpoint, { !disposed && !ownerCleanupUnconfirmed.get() && !busy.get() && !dagBusinessBusy() && !dagEnvironmentBusy() && !dagDispatcher.isBusy() && !pendingPairingsBusy() && !mailBusy() },
        pinDispatcher::hasArtifacts, { recoveryRegistry.clear() }, ::drainOwnersForReset)
    private val dagBusinessDispatcher: NativeDAGBusinessDispatcher = NativeDAGBusinessDispatcher(activity, this.store, workflowFilename,
        ::nativeCertificates, ::acceptsEndpoint, { !dagEnvironmentBusy() && !disposed && !ownerCleanupUnconfirmed.get() && !busy.get() && !dagDispatcher.isBusy() && !pendingPairingsBusy() && !mailBusy() && !resetDispatcher.isBusy() },
        pinDispatcher::hasArtifacts, endpointScope::workflowOpened)
    private val dagEnvironmentDispatcher: NativeDAGEnvironmentDispatcher = NativeDAGEnvironmentDispatcher(activity, this.store, workflowFilename,
        ::nativeCertificates, ::acceptsEndpoint, { !disposed && !ownerCleanupUnconfirmed.get() && !busy.get() && !dagBusinessBusy() && !dagDispatcher.isBusy() && !pendingPairingsBusy() && !mailBusy() && !resetDispatcher.isBusy() },
        pinDispatcher::hasArtifacts, endpointScope::workflowOpened)
    private fun dagEnvironmentBusy() = dagEnvironmentDispatcher.isBusy()
    private fun dagBusinessBusy() = dagBusinessDispatcher.isBusy()
    private fun pendingPairingsBusy() = pendingPairingsDispatcher.isBusy()
    private fun mailBusy() = resetMailDispatcher.isBusy()

    /** Query成功后才调用。每个 owner 精确退休；普通 worker fence在其 finally 清钥之后。 */
    private fun drainOwnersForReset(endpoint: String, completed: (String?) -> Unit) {
        NativeOwnerDrainBarrier.all(listOf(
            { done -> dagBusinessDispatcher.cancelAndDrain(done) },
            { done -> dagEnvironmentDispatcher.cancelAndDrain(done) },
            { done -> pendingPairingsDispatcher.cancelAndDrain(done) },
            { done -> resetMailDispatcher.cancelAndDrain(done) },
            { done ->
                worker.execute {
                    val error = try { recoveryRegistry.clear(); null } catch (_: Exception) { "LOCAL_PROTECTION_PERSISTENCE" }
                    check(main.post { done(error) })
                }
            },
            { done ->
                val command = JSONObject(mapOf("version" to 1, "operation" to "cancelDAGRecoveryOwner", "endpoint" to endpoint)).toString()
                dagDispatcher.execute(command, ByteArray(0)) { _, error -> done(error) }
            },
        )) { error ->
            if (error == "LOCAL_PROTECTION_PERSISTENCE") ownerCleanupUnconfirmed.set(true)
            completed(error)
        }
    }
    internal fun executeNativeDAG(command: String, code: ByteArray, completion: NativeDAGRecoveryDispatcher.Completion) {
        pendingPairingsDispatcher.invalidate(); resetMailDispatcher.invalidate(); dagBusinessDispatcher.invalidate(); dagEnvironmentDispatcher.invalidate()
        dagDispatcher.execute(command, code, completion)
    }
    internal fun beginNativeAccountReset(endpoint: String, proof: ByteArray, completion: NativeAccountResetDispatcher.Completion) = resetDispatcher.begin(endpoint, proof, completion)
    internal fun queryOnlyNativeAccountReset(endpoint: String, proof: ByteArray, completion: NativeAccountResetDispatcher.Completion) = resetDispatcher.beginQueryOnly(endpoint, proof, completion)
    internal fun queryNativeAccountReset(completion: NativeAccountResetDispatcher.Completion) = resetDispatcher.query(completion)
    internal fun prepareNativeAccountReset(password: ByteArray, confirmation: String, completion: NativeAccountResetDispatcher.Completion) = resetDispatcher.prepare(password, confirmation, completion)
    internal fun completeNativeAccountReset(completion: NativeAccountResetDispatcher.Completion) = resetDispatcher.complete(completion)
    internal fun cancelNativeAccountReset() = resetDispatcher.invalidate()
    internal fun onHostResumed(deviceUnlocked: Boolean) { dagDispatcher.onResumed(deviceUnlocked); resetDispatcher.onResumed(deviceUnlocked); pendingPairingsDispatcher.onResumed(deviceUnlocked); resetMailDispatcher.onResumed(deviceUnlocked); dagBusinessDispatcher.onResumed(deviceUnlocked); dagEnvironmentDispatcher.onResumed(deviceUnlocked) }
    internal fun onHostPaused() { dagDispatcher.onPaused(); resetDispatcher.onPaused(); pendingPairingsDispatcher.onPaused(); resetMailDispatcher.onPaused(); dagBusinessDispatcher.onPaused(); dagEnvironmentDispatcher.onPaused() }
    internal fun onHostStopped() { dagDispatcher.onStopped(); resetDispatcher.onStopped(); pendingPairingsDispatcher.onStopped(); resetMailDispatcher.onStopped(); dagBusinessDispatcher.onStopped(); dagEnvironmentDispatcher.onStopped() }
    internal fun onHostUserLeaveHint() { dagDispatcher.onUserLeaveHint(); resetDispatcher.onUserLeaveHint(); pendingPairingsDispatcher.onUserLeaveHint(); resetMailDispatcher.onUserLeaveHint(); dagBusinessDispatcher.onUserLeaveHint(); dagEnvironmentDispatcher.onUserLeaveHint() }
    internal fun onHostScreenOff() { dagDispatcher.onScreenOff(); resetDispatcher.onScreenOff(); pendingPairingsDispatcher.onScreenOff(); resetMailDispatcher.onScreenOff(); dagBusinessDispatcher.onScreenOff(); dagEnvironmentDispatcher.onScreenOff() }

    init {
        check(productFixture == null || additionalCA.contentEquals(productFixture.publicCA()))
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        // 字节请求先经过消费解析；关闭/格式失败也清理传入缓冲。
        if (call.method == "executeDAGRecovery") { dagRecoveryMethod(call, result); return }
        if (call.method == "executeDAGBusiness") { dagBusinessMethod(call, result); return }
        if (call.method == "executeDAGEnvironment") { dagEnvironmentMethod(call, result); return }
        if (call.method in NativeAccountResetChannelRequest.METHODS) { accountResetMethod(call, result); return }
        if (disposed) { result.error("LOCKED", "原生桥已关闭。", null); return }
        if (call.method in PinMethodChannelDispatcher.METHODS) { pinMethod(call, result); return }
        if (call.method in setOf("createDevice", "executeApproval", "executeEnrollment", "executeWorkflow", "executeUnlocked")) {
            pendingPairingsDispatcher.invalidate(); resetMailDispatcher.invalidate(); dagBusinessDispatcher.invalidate(); dagEnvironmentDispatcher.invalidate()
        }
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
                        "nativeDAGOwnerCancellation" to true,
                        // 仅实际编译入口声明；独立业务 profile 与 verified op 交集仍须实测。
                        "nativeDAGBusiness" to true, "nativeDAGEnvironment" to true,
                        "nativePendingPairingRequestsV3" to true, "nativePendingPairingRequestsV4" to true,
                        "nativeAccountReset" to true, "nativeAccountResetEmailRequest" to true,
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
                dagDispatcher.invalidate()
                resetDispatcher.invalidate()
                authenticated(result, create = true, command = null)
            }
            "workflowProfile" -> {
                if (call.arguments != null) { invalid(result); return }
                runWorker(result) { Mobilebridge.workflowProfile() }
            }
            "dagWorkflowProfile" -> {
                if (call.arguments != null) { invalid(result); return }
                runWorker(result) { Mobilebridge.dagWorkflowProfile() }
            }
            "dagEnvironmentProfile" -> {
                if (call.arguments != null) { invalid(result); return }
                runWorker(result) { Mobilebridge.dagEnvironmentProfile() }
            }
            "dagBusinessProfile" -> {
                if (call.arguments != null) { invalid(result); return }
                runWorker(result) { Mobilebridge.dagBusinessProfile() }
            }
            "executePendingPairings" -> {
                if (ownerCleanupUnconfirmed.get()) { deliverTyped(result, null, "LOCAL_PROTECTION_PERSISTENCE"); return }
                val request = try { NativePendingPairingsChannelRequest.parse(call.arguments) }
                    catch (_: Exception) { invalid(result); return }
                pendingPairingsDispatcher.execute(request) { value, error ->
                    if (!disposed) deliverTyped(result, value, error)
                }
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
                // 仅本地RAM撤销；真正Logout仍经原Go严格DTO与系统认证。
                try { if (JSONObject(command).optString("operation") == "logout") { dagDispatcher.invalidate(); resetDispatcher.invalidate() } } catch (_: Exception) { }
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
        pendingPairingsDispatcher.invalidate(); resetMailDispatcher.invalidate(); dagBusinessDispatcher.invalidate(); dagEnvironmentDispatcher.invalidate()
        val request = try { PinChannelRequest.parse(call.method, call.arguments) }
            catch (_: Exception) { invalid(result); return }
        if (!acceptsEndpoint(request.endpoint)) { request.close(); invalid(result); return }
        // PIN业务不接DAG owner，任一模式切换/forget前先撤销本槽DAG RAM。
        dagDispatcher.invalidate()
        resetDispatcher.invalidate()
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
            finally {
                request.close(); if (pendingPIN === request) pendingPIN = null
                recoveryRegistry.clear() // native slot/provider已排空，才同步清钥。
            }
        }
    }

    private fun deliverTyped(result: MethodChannel.Result, value: String?, error: String?) {
        if (error == "LOCAL_PROTECTION_PERSISTENCE") ownerCleanupUnconfirmed.set(true)
        if (error == null) result.success(value) else result.error(error, "原生安全操作未完成。", null)
    }
    private fun dagRecoveryMethod(call: MethodCall, result: MethodChannel.Result) {
        val request = try { NativeDAGChannelRequest.parse(call.arguments) } catch (_: Exception) { invalid(result); return }
        request.use {
            if (disposed) { result.error("LOCKED", "原生桥已关闭。", null); return }
            if (ownerCleanupUnconfirmed.get()) { deliverTyped(result, null, "LOCAL_PROTECTION_PERSISTENCE"); return }
            try { Mobilebridge.validateDAGRecoveryCommand(request.command, request.completeCode.size.toLong()) }
            catch (_: Exception) { invalid(result); return }
            if (!acceptsWorkflowEndpoint(request.command)) { invalid(result); return }
            val once = AtomicBoolean()
            executeNativeDAG(request.command, request.completeCode) { value, error ->
                if (once.compareAndSet(false, true) && !disposed) deliverTyped(result, value, error)
            }
        }
    }
    private fun dagBusinessMethod(call: MethodCall, result: MethodChannel.Result) {
        val request = try { NativeDAGBusinessChannelRequest.parse(call.arguments) }
            catch (_: Exception) { invalid(result); return }
        request.use {
            if (disposed) { result.error("LOCKED", "原生桥已关闭。", null); return }
            if (ownerCleanupUnconfirmed.get()) { deliverTyped(result, null, "LOCAL_PROTECTION_PERSISTENCE"); return }
            val once = AtomicBoolean()
            // Dispatcher 在认证前用成熟 Go Validate 唯一判定 DTO，再接管独立 value 缓冲。
            dagBusinessDispatcher.execute(request) { value, error ->
                if (once.compareAndSet(false, true) && !disposed) deliverTyped(result, value, error)
            }
        }
    }
    private fun dagEnvironmentMethod(call: MethodCall, result: MethodChannel.Result) {
        val request = try { NativeDAGEnvironmentChannelRequest.parse(call.arguments) }
            catch (_: Exception) { invalid(result); return }
        request.use {
            if (disposed) { result.error("LOCKED", "原生桥已关闭。", null); return }
            if (ownerCleanupUnconfirmed.get()) { deliverTyped(result, null, "LOCAL_PROTECTION_PERSISTENCE"); return }
            val once = AtomicBoolean()
            // Dispatcher 在认证前用成熟 Go Validate 唯一判定 DTO，再接管独立 value 缓冲。
            dagEnvironmentDispatcher.execute(request) { value, error ->
                if (once.compareAndSet(false, true) && !disposed) deliverTyped(result, value, error)
            }
        }
    }
    private fun accountResetMethod(call: MethodCall, result: MethodChannel.Result) {
        val request = try { NativeAccountResetChannelRequest.parse(call.method, call.arguments) }
            catch (_: Exception) { invalid(result); return }
        request.use {
            if (disposed) { result.error("LOCKED", "原生桥已关闭。", null); return }
            if (ownerCleanupUnconfirmed.get() && request.method != "cancelAccountReset") { deliverTyped(result, null, "LOCAL_PROTECTION_PERSISTENCE"); return }
            if (request.endpoint.isNotEmpty()) {
                // BUSY拒绝不能在cold状态先固定另一地址，影响已在等待认证的opener。
                if (busy.get() || dagBusinessBusy() || dagEnvironmentBusy() || dagDispatcher.isBusy() || pendingPairingsBusy() || mailBusy() || resetDispatcher.isBusy() ||
                    (request.method == "requestAccountResetEmail" && resetDispatcher.hasOwner())) {
                    deliverTyped(result, null, "BUSY"); return
                }
                try {
                    val canonical = JSONObject(Mobilebridge.executePublic(JSONObject(mapOf("version" to 1, "operation" to "validateEndpoint", "endpoint" to request.endpoint)).toString())).getString("endpoint")
                    if (canonical != request.endpoint || !acceptsEndpoint(request.endpoint) || !endpointScope.claimResetFlow(request.endpoint)) { invalid(result); return }
                } catch (_: Exception) { invalid(result); return }
            }
            val once = AtomicBoolean()
            val completion = NativeAccountResetDispatcher.Completion { value, error ->
                if (once.compareAndSet(false, true) && !disposed) deliverTyped(result, value, error)
            }
            when (request.method) {
                "requestAccountResetEmail" -> resetMailDispatcher.execute(request.endpoint, request.takeInput()) { value, error -> completion.complete(value, error) }
                "beginAccountReset" -> resetDispatcher.begin(request.endpoint, request.takeInput(), completion)
                "beginAccountResetQueryOnly" -> resetDispatcher.beginQueryOnly(request.endpoint, request.takeInput(), completion)
                "queryAccountReset" -> resetDispatcher.query(completion)
                "prepareAccountReset" -> resetDispatcher.prepare(request.takeInput(), request.confirmation, completion)
                "completeAccountReset" -> resetDispatcher.complete(completion)
                "cancelAccountReset" -> NativeOwnerDrainBarrier.all(listOf(
                    { done -> resetMailDispatcher.cancelAndDrain(done) },
                    { done -> resetDispatcher.cancelAndDrain(done) },
                )) { error ->
                    if (error == null) endpointScope.releaseResetFlow(!busy.get() && !dagBusinessBusy() && !dagEnvironmentBusy() && !dagDispatcher.hasOwner() && !pendingPairingsBusy())
                    completion.complete(null, error)
                }
            }
        }
    }

    private fun acceptsEndpoint(endpoint: String): Boolean = endpointScope.accepts(endpoint) && (productFixture?.acceptsEndpoint(endpoint) ?: true)

    private fun acceptsWorkflowEndpoint(command: String): Boolean = try {
        acceptsEndpoint(JSONObject(command).getString("endpoint"))
    } catch (_: Exception) { false }

    private fun invalid(result: MethodChannel.Result) = result.error("INVALID_COMMAND", "原生业务请求不符合协议。", null)
    private fun acquire(result: MethodChannel.Result): Boolean {
        if (ownerCleanupUnconfirmed.get()) { result.error("LOCAL_PROTECTION_PERSISTENCE", "本机资源排空未确认。", null); return false }
        if (dagBusinessBusy() || dagEnvironmentBusy() || dagDispatcher.isBusy() || resetDispatcher.isBusy() || pendingPairingsBusy() || mailBusy() || !busy.compareAndSet(false, true)) { result.error("BUSY", "已有原生业务操作正在进行。", null); return false }
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
        if (hasPIN) { dagDispatcher.invalidate(); clearApproval(shortCode); recoveryRegistry.clear(); result.error("PIN_UPGRADE_REQUIRED", "当前为PIN保护模式；不能自动切换系统provider。", null); return }
        if (!store.supported() || Build.VERSION.SDK_INT < 30) {
            dagDispatcher.invalidate()
            clearApproval(shortCode)
            recoveryRegistry.clear()
            result.error("AUTH_UNAVAILABLE", "需要系统设备密码或强生物认证，当前不能生成或解包设备钥匙。", null)
            return
        }
        if (!acquire(result)) { clearApproval(shortCode); return }
        pendingShortCode = shortCode
        val owner = try {
            NativeSlotOwner.acquire(activity, workflowFilename, store.nativeFilename, store.nativeAlias).also {
                activeSlotOwner = it
                it.read { check(!disposed && !pinDispatcher.hasArtifacts()) }
            }
        } catch (failure: Exception) {
            try { activeSlotOwner?.close() } catch (_: Exception) { }
            activeSlotOwner = null
            clearApproval(shortCode)
            if (failure !is NativeSlotBusyException) recoveryRegistry.clear()
            finish(result, code = if (failure is NativeSlotBusyException) "BUSY" else "LOCAL_PROTECTION_STATE"); return
        }
        fun releaseOwner(cancelCreate: Boolean = false): Boolean {
            var confirmed = true
            if (cancelCreate && create) try { store.cancelPreparedCreate(owner) } catch (_: Exception) { confirmed = false }
            try { owner.close() } catch (_: Exception) { confirmed = false }
            if (activeSlotOwner === owner) activeSlotOwner = null
            return confirmed
        }
        val cipher: Cipher
        val ciphertext: ByteArray?
        try {
            if (create) { recoveryRegistry.clear(); cipher = store.prepareCreate(owner); ciphertext = null }
            else { val opening = store.prepareOpen(owner); cipher = opening.cipher; ciphertext = opening.ciphertext }
        } catch (_: Exception) { recoveryRegistry.clear(); clearApproval(shortCode); finish(result, code = if (releaseOwner()) "PROTECTED_KEYS_UNAVAILABLE" else "LOCAL_PROTECTION_PERSISTENCE"); return }
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
                        if (consumed.compareAndSet(false, true)) { dagDispatcher.invalidate(); recoveryRegistry.clear(); clearApproval(shortCode); finish(result, code = if (releaseOwner(cancelCreate = true)) "AUTH_CANCELLED" else "LOCAL_PROTECTION_PERSISTENCE") }
                    }
                    override fun onAuthenticationFailed() {
                        if (consumed.compareAndSet(false, true)) { dagDispatcher.invalidate(); recoveryRegistry.clear(); clearApproval(shortCode); signal.cancel(); finish(result, code = if (releaseOwner(cancelCreate = true)) "AUTH_FAILED" else "LOCAL_PROTECTION_PERSISTENCE") }
                    }
                    override fun onAuthenticationSucceeded(authentication: BiometricPrompt.AuthenticationResult) {
                        if (!consumed.compareAndSet(false, true)) return
                        if (authentication.cryptoObject?.cipher !== cipher || disposed) { dagDispatcher.invalidate(); recoveryRegistry.clear(); clearApproval(shortCode); finish(result, code = if (releaseOwner(cancelCreate = true)) "AUTH_FAILED" else "LOCAL_PROTECTION_PERSISTENCE"); return }
                        worker.execute {
                            var material: ByteArray? = null
                            var device: org.harmoniavault.go.mobilebridge.Device? = null
                            var response: Any? = null
                            var failureCode: String? = null
                            try {
                                // 成功认证后才生成设备钥，取消/失败不会生成可信设备。
                                if (create) {
                                    device = Mobilebridge.newDevice()
                                    material = device.exportProtectedMaterial()
                                    store.saveAuthenticated(cipher, material, owner)
                                    recoveryRegistry.resetForNewDevice()
                                    response = device.execute("{\"version\":1,\"operation\":\"publicInfo\"}")
                                } else {
                                    check(!disposed)
                                    material = store.openAuthenticated(cipher, ciphertext!!, owner)
                                    device = Mobilebridge.importProtectedMaterial(material)
                                    store.confirmImportedMaterial(owner)
                                    material.fill(0)
                                    if (workflow) {
                                        val protected = ProtectedWorkflowStore(activity, workflowFilename, beforeWorkflowSave, { !disposed }, owner)
                                        val endpoint = JSONObject(command!!).getString("endpoint")
                                        val state = protected.load()
                                        val writer = object : org.harmoniavault.go.mobilebridge.AtomicSealedStateStore {
                                            override fun saveSealed(packet: ByteArray?) {
                                                val checked = SealedCallbackContract.requirePacket(packet)
                                                beforeWorkflowPacketSave(checked)
                                                protected.saveSealed(checked)
                                            }
                                            override fun checkSealed(expected: ByteArray?) = protected.checkSealed(expected)
                                            override fun compareAndSwapSealed(expected: ByteArray?, next: ByteArray?) {
                                                val checked = SealedCallbackContract.requirePacket(next)
                                                beforeWorkflowPacketSave(checked)
                                                protected.compareAndSwapSealed(expected, checked)
                                            }
                                        }
                                        val flow = device.openAtomicWorkflow(endpoint, protected.namespace, state, nativeCertificates(), writer)
                                        activeWorkflow = flow
                                        try {
                                            endpointScope.workflowOpened(endpoint)
                                            check(!disposed)
                                            flow.attachRecoveryRegistry(recoveryRegistry)
                                            response = when {
                                                shortCode != null && enrollment -> flow.executeEnrollment(command, shortCode)
                                                shortCode != null -> flow.executeApproval(command, shortCode)
                                                else -> flow.execute(command)
                                            }
                                            if (flow.requiresDeviceDeletion()) {
                                                recoveryRegistry.clear()
                                                owner.clear { store.delete(owner); protected.delete(); store.finishDeletion(owner) }
                                            }
                                            check(!disposed)
                                        } finally { activeWorkflow = null; flow.close(); state.fill(0); protected.closeCaptured() }
                                    } else response = device.execute(command!!)
                                }
                            } catch (_: Exception) { owner.retire(); recoveryRegistry.clear(); failureCode = "GO_OR_KEYSTORE_REJECTED" }
                            finally {
                                clearApproval(shortCode); material?.fill(0)
                                try { device?.close() } catch (_: Exception) { failureCode = "GO_OR_KEYSTORE_REJECTED" }
                                if (!releaseOwner()) failureCode = "LOCAL_PROTECTION_PERSISTENCE"
                            }
                            val logout = workflow && try { JSONObject(command!!).getString("operation") == "logout" } catch (_: Exception) { false }
                            if (logout && failureCode == null) {
                                val value = response
                                check(main.post {
                                    drainOwnersForReset(JSONObject(command!!).getString("endpoint")) { error ->
                                        if (error == null && value is String && JSONObject(value).optBoolean("ok", false)) endpointScope.releaseAfterLogoutDrain()
                                        finish(result, value, error)
                                    }
                                })
                            } else finish(result, response, failureCode)
                        }
                    }
                })
        } catch (_: Exception) {
            if (consumed.compareAndSet(false, true)) { dagDispatcher.invalidate(); recoveryRegistry.clear(); clearApproval(shortCode); finish(result, code = if (releaseOwner(cancelCreate = true)) "AUTH_UNAVAILABLE" else "LOCAL_PROTECTION_PERSISTENCE") }
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
        endpointScope.dispose()
        try { dagBusinessDispatcher.dispose() } catch (_: Exception) { failed = true }
        try { dagEnvironmentDispatcher.dispose() } catch (_: Exception) { failed = true }
        try { resetMailDispatcher.dispose() } catch (_: Exception) { failed = true }
        try { pendingPairingsDispatcher.dispose() } catch (_: Exception) { failed = true }
        try { dagDispatcher.dispose() } catch (_: Exception) { failed = true }
        try { resetDispatcher.dispose() } catch (_: Exception) { failed = true }
        try { pinOwnerGate.retire { disposed = true } } catch (_: Exception) { failed = true }
        try { activeWorkflow?.invalidate() } catch (_: Exception) { failed = true }
        try { recoveryRegistry.invalidate() } catch (_: Exception) { failed = true }
        activeSlotOwner?.retire() // 先令 writer 失效；Go Close 与 FileLock 排空在 worker finally，不持 commit gate。
        // Go同步Close只能在worker排空后执行，不能占主线程或native保存gate。
        try { worker.execute { recoveryRegistry.close() } } catch (_: Exception) { failed = true }
        pendingPIN?.close()
        clearApproval(pendingShortCode)
        try { cancellation?.cancel() } catch (_: Exception) { failed = true }
        channel.setMethodCallHandler(null)
        worker.shutdown()
        if (failed) throw IllegalStateException("native owner cleanup unconfirmed")
    }
}
