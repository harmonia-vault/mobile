package org.harmoniavault.harmonia_mobile.nativebridge

import android.app.Activity
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import org.harmoniavault.go.mobilebridge.Mobilebridge
import org.harmoniavault.go.mobilebridge.NativeDAGRegistry
import org.harmoniavault.go.mobilebridge.VaultWorkflow
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** 受原生认证与 owner 排空约束的 DAG 路径；不接受调用方认证结果或本地槽参数。 */
internal class NativeDAGRecoveryDispatcher(
    private val activity: Activity,
    private val store: ProtectedDeviceStore,
    private val workflowFilename: String,
    private val certificates: () -> ByteArray,
    private val acceptsEndpoint: (String) -> Boolean,
    private val ordinaryIdle: () -> Boolean,
    private val hasPINArtifacts: () -> Boolean,
    private val workflowOpened: (String) -> Unit = {},
) {
    internal fun interface Completion { fun complete(value: String?, fixedError: String?) }
    private class RegistryRecord(val epoch: Long, val endpoint: String, val registry: NativeDAGRegistry)
    private class Operation(val request: Request, val epoch: Long, val completion: Completion) {
        val completed = AtomicBoolean()
        val callbackConsumed = AtomicBoolean()
        val cleanupScheduled = AtomicBoolean()
        var ticket: NativeSlotLifecycle.Ticket? = null
        var permit: NativeSlotLifecycle.Permit? = null
        var signal: CancellationSignal? = null
        @Volatile var owner: NativeSlotOwner? = null
        @Volatile var flow: VaultWorkflow? = null
        @Volatile var retired = false
        @Volatile var workerStarted = false
        @Volatile var fixedFailure = "LOCKED"
        var opening: ProtectedDeviceStore.Opening? = null
    }
    private class Request(val command: String, val endpoint: String, val operation: String, val code: ByteArray) : AutoCloseable {
        override fun close() { code.fill(0) }
        companion object {
            fun parse(command: String, incoming: ByteArray): Request {
                try {
                    // Go 解码器严格拒重复字段/类型/unknown/trailing，JSONObject只读取已预检字段。
                    Mobilebridge.validateDAGRecoveryCommand(command, incoming.size.toLong())
                    val objectValue = JSONObject(command)
                    return Request(command, objectValue.getString("endpoint"), objectValue.getString("operation"), incoming.copyOf())
                } finally { incoming.fill(0) }
            }
        }
    }
    private val gate = Any()
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var record: RegistryRecord? = null
    private var operation: Operation? = null
    private val cancellationCompletions = mutableListOf<Completion>()
    @Volatile private var disposed = false
    private val cleanup = NativeDAGCleanup()
    private val admission = NativeDAGAdmissionGate()
    private val lifecycle = NativeSlotLifecycle(
        { SystemClock.elapsedRealtime() },
        { delay, action -> val runnable = Runnable { action() }; check(main.postDelayed(runnable, delay)); NativeSlotTimer { main.removeCallbacks(runnable) } },
        onRetired = ::retired,
    )
    private fun mainThread() { check(Looper.myLooper() === Looper.getMainLooper()) }
    fun isBusy(): Boolean = admission.busy() || cleanup.unconfirmed
    fun hasOwner(): Boolean = synchronized(gate) { record != null } || isBusy()
    fun onResumed(deviceUnlocked: Boolean) { mainThread(); lifecycle.onResumed(deviceUnlocked); tryStart() }
    fun onPaused() { mainThread(); lifecycle.onPaused() }
    fun onStopped() { mainThread(); lifecycle.onStopped() }
    fun onUserLeaveHint() { mainThread(); lifecycle.onUserLeaveHint() }
    fun onScreenOff() { mainThread(); lifecycle.onScreenOff() }
    fun invalidate() { mainThread(); lifecycle.invalidate() }

    /** 本地取消只关本槽RAM，保留密封journal；不称服务器closed、accepted或trusted。 */
    fun execute(command: String, completeCode: ByteArray, completion: Completion) {
        mainThread()
        val request = try { Request.parse(command, completeCode) } catch (_: Exception) { completion.complete(null, "INVALID_COMMAND"); return }
        if (disposed || cleanup.unconfirmed || !acceptsEndpoint(request.endpoint)) { request.close(); completion.complete(null, "LOCKED"); return }
        if (request.operation == "cancelDAGRecoveryOwner") {
            val endpointMatches = synchronized(gate) { record?.endpoint?.let { it == request.endpoint } ?: (operation?.request?.endpoint?.let { it == request.endpoint } ?: true) }
            if (!endpointMatches) { request.close(); completion.complete(null, "INVALID_COMMAND"); return }
            cancellationCompletions += completion
            admission.cancellationBegan()
            lifecycle.invalidate(); request.close()
            if (!admission.operationActive()) queueRegistryDrain { /* 同一队列空fence也须worker→main确认。 */ }
            return
        }
        if (!ordinaryIdle() || isBusy()) { request.close(); completion.complete(null, "BUSY"); return }
        try {
            check(Build.VERSION.SDK_INT >= 30 && !hasPINArtifacts() && store.supported())
        } catch (_: Exception) { request.close(); lifecycle.invalidate(); completion.complete(null, "AUTH_UNAVAILABLE"); return }
        val epoch = try { lifecycle.platformEpoch() } catch (_: Exception) { request.close(); completion.complete(null, "LOCKED"); return }
        val op = Operation(request, epoch, completion)
        synchronized(gate) { check(operation == null); admission.operationBegan(); operation = op }
        try {
            val owner = NativeSlotOwner.acquire(activity, workflowFilename, store.nativeFilename, store.nativeAlias)
            op.owner = owner
            owner.read { check(!disposed && !hasPINArtifacts()) }
            val opening = store.prepareOpen(owner); op.opening = opening
            val ticket = lifecycle.prepareAuthentication(opening.cipher, owner.operationEpoch()); op.ticket = ticket
            val signal = CancellationSignal(); op.signal = signal
            val prompt = BiometricPrompt.Builder(activity).setTitle("和弦设备认证")
                .setSubtitle("解锁本次恢复操作")
                .setAllowedAuthenticators(ProtectedDeviceStore.AUTHENTICATORS).build()
            lifecycle.authenticationStarted(ticket)
            prompt.authenticate(BiometricPrompt.CryptoObject(opening.cipher), signal, activity.mainExecutor,
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                        if (op.callbackConsumed.compareAndSet(false, true)) {
                            op.fixedFailure = "AUTH_CANCELLED"
                            lifecycle.authenticationRejected(ticket); fail(op, "AUTH_CANCELLED")
                        }
                    }
                    override fun onAuthenticationFailed() {
                        if (op.callbackConsumed.compareAndSet(false, true)) {
                            op.fixedFailure = "AUTH_FAILED"
                            lifecycle.authenticationRejected(ticket); fail(op, "AUTH_FAILED")
                        }
                    }
                    override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                        if (!op.callbackConsumed.compareAndSet(false, true)) return
                        try {
                            val actual = result.cryptoObject?.cipher ?: error("crypto object absent")
                            lifecycle.authenticationSucceeded(ticket, actual); tryStart()
                        } catch (_: Exception) { lifecycle.authenticationRejected(ticket); fail(op, "AUTH_FAILED") }
                    }
                })
        } catch (failure: Exception) {
            // BUSY 没有读新槽或认证，不能破坏其它正在持有的owner。
            if (failure !is NativeSlotBusyException) lifecycle.invalidate()
            fail(op, if (failure is NativeSlotBusyException) "BUSY" else "AUTH_UNAVAILABLE")
        }
    }
    private fun tryStart() {
        val op = synchronized(gate) { operation } ?: return
        val ticket = op.ticket ?: return
        if (op.workerStarted || op.retired || !lifecycle.isAuthenticationReady(ticket)) return
        val permit = try { lifecycle.consume(ticket) } catch (_: Exception) { fail(op, "LOCKED"); return }
        op.permit = permit; op.workerStarted = true
        worker.execute { run(op, permit) }
    }
    private fun alive(op: Operation, permit: NativeSlotLifecycle.Permit): Boolean = !disposed && !op.retired && lifecycle.isOperationActive(permit) && op.owner?.alive() == true
    private fun registry(op: Operation): NativeDAGRegistry = synchronized(gate) {
        check(!disposed && !op.retired)
        val previous = record
        if (previous != null) {
            check(previous.epoch == op.epoch && previous.endpoint == op.request.endpoint)
            previous.registry
        } else Mobilebridge.newNativeDAGRegistry(activity.packageName, workflowFilename, op.epoch).also {
            record = RegistryRecord(op.epoch, op.request.endpoint, it)
        }
    }
    private fun run(op: Operation, permit: NativeSlotLifecycle.Permit) {
        var material: ByteArray? = null
        var state: ByteArray? = null
        var device: org.harmoniavault.go.mobilebridge.Device? = null
        var protected: ProtectedWorkflowStore? = null
        var response: String? = null
        var failure: String? = null
        try {
            check(alive(op, permit))
            val owner = op.owner ?: error("owner absent")
            val opening = op.opening ?: error("opening absent")
            material = store.openAuthenticated(opening.cipher, opening.ciphertext, owner)
            device = Mobilebridge.importProtectedMaterial(material); store.confirmImportedMaterial(owner)
            material.fill(0)
            protected = ProtectedWorkflowStore(activity, workflowFilename, operationActive = { alive(op, permit) }, owner = owner)
            state = protected.load()
            val flow = device.openAtomicWorkflow(op.request.endpoint, protected.namespace, state, certificates(), protected)
            op.flow = flow
            workflowOpened(op.request.endpoint)
            flow.attachDAGRegistry(registry(op))
            check(alive(op, permit))
            response = flow.executeDAGRecovery(op.request.command, op.request.code)
            check(alive(op, permit))
        } catch (_: Exception) { failure = "DAG_OR_PROTECTION_REJECTED" }
        finally {
            op.request.close(); material?.fill(0); state?.fill(0)
            if (!cleanup.attempt { op.flow?.close() }) failure = "LOCAL_PROTECTION_PERSISTENCE"
            op.flow = null
            if (!cleanup.attempt { protected?.closeCaptured() }) failure = "LOCAL_PROTECTION_PERSISTENCE"
            if (!cleanup.attempt { device?.close() }) failure = "LOCAL_PROTECTION_PERSISTENCE"
            op.opening?.ciphertext?.fill(0); op.opening = null
        }
        val value = response; val error = failure
        main.post {
            if (error != null || !alive(op, permit)) {
                lifecycle.invalidate(); releaseAndComplete(op, null, error ?: "LOCKED")
            } else {
                try {
                    // 最后完整capture核验仍使用本次owner；不能读新expected复活旧writer。
                    op.owner!!.read { check(alive(op, permit)) }
                    lifecycle.complete(permit)
                    releaseAndComplete(op, value, null)
                } catch (_: Exception) { lifecycle.invalidate(); releaseAndComplete(op, null, "LOCKED") }
            }
        }
    }
    /** 在 lifecycle gate 外撤销，只接触精确旧 epoch；Close/drain 放 worker finally之后。 */
    private fun retired(epoch: Long) {
        val oldRecord: RegistryRecord?
        val oldOperation: Operation?
        synchronized(gate) {
            oldRecord = record?.takeIf { it.epoch == epoch }
            if (oldRecord != null) record = null
            oldOperation = operation?.takeIf { it.epoch == epoch }
            oldOperation?.retired = true
        }
        // 各撤销独立尝试；任一步异常永久closed，不丢其余清理动作。
        listOf<() -> Unit>(
            { oldOperation?.flow?.invalidate() }, { oldRecord?.registry?.invalidate() },
            { oldOperation?.owner?.retire() }, { oldOperation?.signal?.cancel() },
        ).forEach { action -> cleanup.attempt(action) }
        if (oldRecord != null) queueRegistryDrain { oldRecord.registry.close() }
        if (oldOperation != null && !oldOperation.workerStarted) fail(oldOperation, oldOperation.fixedFailure)
    }
    private fun fail(op: Operation, error: String) {
        op.request.close()
        if (!op.workerStarted) releaseAndComplete(op, null, error)
    }
    private fun releaseAndComplete(op: Operation, value: String?, error: String?) {
        if (!op.cleanupScheduled.compareAndSet(false, true)) return
        worker.execute {
            var fixedError = error
            op.request.close(); op.opening?.ciphertext?.fill(0); op.opening = null
            if (!cleanup.attempt { op.owner?.close() }) fixedError = "LOCAL_PROTECTION_PERSISTENCE"
            op.owner = null
            main.post {
                // 释放在 worker 完成后，交付前重新核对 sticky 清理状态和原票期限。
                val outcome = if (cleanup.unconfirmed) "LOCAL_PROTECTION_PERSISTENCE" else fixedError
                val allowed = outcome == null && op.permit?.let(lifecycle::canDeliverCompleted) == true
                // complete 已 disarm timer；慢释放跨截止仍须退休原 RAM owner，保留 journal。
                if (!allowed && !op.retired) lifecycle.invalidate()
                if (op.completed.compareAndSet(false, true)) {
                    synchronized(gate) { if (operation === op) { operation = null; admission.operationEnded() } }
                    try { op.completion.complete(if (allowed) value else null, if (allowed) null else outcome ?: "LOCKED") }
                    finally {
                        finishCancellations(outcome?.takeIf { it == "LOCAL_PROTECTION_PERSISTENCE" })
                        if (disposed && admission.canFinishCancellation()) worker.shutdown()
                    }
                }
            }
        }
    }
    /** 每个close/fence从排队前即阻止新owner；只有worker完毕且main确认才释放。 */
    private fun queueRegistryDrain(action: () -> Unit) {
        val ticket = admission.drainBegan()
        try {
            worker.execute {
                cleanup.attempt(action)
                if (!main.post {
                    admission.drainEnded(ticket)
                    finishCancellations(null)
                    if (disposed && admission.canFinishCancellation()) worker.shutdown()
                }) cleanup.attempt { error("DAG main drain unconfirmed") }
            }
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            cleanup.attempt { error("DAG worker drain unconfirmed") }
            admission.drainEnded(ticket)
            finishCancellations("LOCAL_PROTECTION_PERSISTENCE")
        }
    }
    private fun finishCancellations(error: String?) {
        if (!admission.canFinishCancellation()) return
        admission.cancellationEnded()
        val callbacks = cancellationCompletions.toList(); cancellationCompletions.clear()
        val fixedError = if (cleanup.unconfirmed) "LOCAL_PROTECTION_PERSISTENCE" else error
        val result = "{\"version\":1,\"operation\":\"cancelDAGRecoveryOwner\",\"localOwnerClosed\":true,\"journalPreserved\":true,\"trustedDevice\":false}"
        callbacks.forEach { it.complete(if (fixedError == null) result else null, fixedError) }
    }
    fun dispose() {
        mainThread(); if (disposed) return
        disposed = true; lifecycle.dispose()
        // 已排队的取消/Close和owner释放继续完成，不能shutdownNow丢弃清理。
        if (admission.canFinishCancellation()) worker.shutdown()
    }
}
