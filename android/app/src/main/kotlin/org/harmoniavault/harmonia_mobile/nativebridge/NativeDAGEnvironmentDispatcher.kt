package org.harmoniavault.harmonia_mobile.nativebridge

import android.app.Activity
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import org.harmoniavault.go.mobilebridge.Mobilebridge
import org.harmoniavault.go.mobilebridge.VaultWorkflow
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** 每次 DAG 环境操作都绑定独立真实系统认证与 captured whole-state CAS；来源和写语义只由 Go 判定。 */
internal class NativeDAGEnvironmentDispatcher(
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
    private class Operation(val command: String, val nameBytes: ByteArray, val endpoint: String, val epoch: Long, val completion: Completion) {
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
    private val gate = Any()
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var operation: Operation? = null
    @Volatile private var disposed = false
    private val cleanup = NativeDAGCleanup()
    private val drain = NativeOwnerDrainBarrier()
    private val lifecycle = NativeSlotLifecycle(
        { SystemClock.elapsedRealtime() },
        { delay, action -> val runnable = Runnable { action() }; check(main.postDelayed(runnable, delay)); NativeSlotTimer { main.removeCallbacks(runnable) } },
        onRetired = ::retired,
    )
    private fun mainThread() { check(Looper.myLooper() === Looper.getMainLooper()) }
    private fun operationOrDrainActive(): Boolean = synchronized(gate) { operation != null || drain.isDraining() }
    fun isBusy(): Boolean = operationOrDrainActive() || cleanup.unconfirmed
    fun onResumed(deviceUnlocked: Boolean) { mainThread(); lifecycle.onResumed(deviceUnlocked); tryStart() }
    fun onPaused() { mainThread(); lifecycle.onPaused() }
    fun onStopped() { mainThread(); lifecycle.onStopped() }
    fun onUserLeaveHint() { mainThread(); lifecycle.onUserLeaveHint() }
    fun onScreenOff() { mainThread(); lifecycle.onScreenOff() }
    fun invalidate() { mainThread(); lifecycle.invalidate() }
    fun cancelAndDrain(completion: (String?) -> Unit) {
        mainThread()
        if (!drain.begin(completion)) { completion("BUSY"); return }
        invalidate()
        if (synchronized(gate) { operation == null }) drain.finish(if (cleanup.unconfirmed) "LOCAL_PROTECTION_PERSISTENCE" else null)
    }

    fun execute(request: NativeDAGEnvironmentChannelRequest, completion: Completion) {
        mainThread()
        val endpoint = try {
            // 不接受 scope、token、PIN、owner、shortCode 或调用者 auth bool。
            Mobilebridge.validateDAGEnvironmentCommand(request.command)
            val fields = JSONObject(request.command)
            request.validateOperation(fields.getString("operation"))
            fields.getString("endpoint")
        } catch (_: Exception) { request.close(); completion.complete(null, "INVALID_COMMAND"); return }
        if (disposed || cleanup.unconfirmed || !acceptsEndpoint(endpoint)) { request.close(); completion.complete(null, "LOCKED"); return }
        if (!ordinaryIdle() || isBusy()) { request.close(); completion.complete(null, "BUSY"); return }
        try { check(Build.VERSION.SDK_INT >= 30 && !hasPINArtifacts() && store.supported()) }
        catch (_: Exception) { request.close(); lifecycle.invalidate(); completion.complete(null, "AUTH_UNAVAILABLE"); return }
        val epoch = try { lifecycle.platformEpoch() } catch (_: Exception) { request.close(); completion.complete(null, "LOCKED"); return }
        val op = Operation(request.command, request.takeName(), endpoint, epoch, completion)
        request.close()
        synchronized(gate) { check(operation == null); operation = op }
        try {
            val owner = NativeSlotOwner.acquire(activity, workflowFilename, store.nativeFilename, store.nativeAlias)
            op.owner = owner
            owner.read { check(!disposed && !hasPINArtifacts()) }
            val opening = store.prepareOpen(owner); op.opening = opening
            val ticket = lifecycle.prepareAuthentication(opening.cipher, owner.operationEpoch()); op.ticket = ticket
            val signal = CancellationSignal(); op.signal = signal
            val prompt = BiometricPrompt.Builder(activity).setTitle("和弦设备认证")
                .setSubtitle("访问恢复设备的保险库")
                .setAllowedAuthenticators(ProtectedDeviceStore.AUTHENTICATORS).build()
            lifecycle.authenticationStarted(ticket)
            prompt.authenticate(BiometricPrompt.CryptoObject(opening.cipher), signal, activity.mainExecutor,
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                        if (op.callbackConsumed.compareAndSet(false, true)) {
                            op.fixedFailure = "AUTH_CANCELLED"; lifecycle.authenticationRejected(ticket); fail(op, "AUTH_CANCELLED")
                        }
                    }
                    override fun onAuthenticationFailed() {
                        if (op.callbackConsumed.compareAndSet(false, true)) {
                            op.fixedFailure = "AUTH_FAILED"; lifecycle.authenticationRejected(ticket); fail(op, "AUTH_FAILED")
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
    private fun alive(op: Operation, permit: NativeSlotLifecycle.Permit): Boolean =
        !disposed && !op.retired && lifecycle.isOperationActive(permit) && op.owner?.alive() == true
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
            val flow = device.openAtomicWorkflow(op.endpoint, protected.namespace, state, certificates(), protected)
            op.flow = flow
            workflowOpened(op.endpoint)
            check(alive(op, permit))
            // Go 唯一执行已应用 P4 来源、原签包/CAS、正式 Pull 与最后保存；没有 legacy fallback。
            response = flow.executeDAGEnvironment(op.command, op.nameBytes)
            check(alive(op, permit))
        } catch (_: Exception) { failure = "DAG_ENVIRONMENT_REJECTED" }
        finally {
            // hard trust/CAS 失败不发明原请求成功；异常路径也检查成熟 Go 删除标记。
            if (!cleanup.attempt {
                if (op.flow?.requiresDeviceDeletion() == true) {
                    response = null; failure = "TRUST_INVALIDATED"
                    val owner = op.owner ?: error("owner absent")
                    val captured = protected ?: error("protected state absent")
                    owner.clear { store.delete(owner); captured.delete(); store.finishDeletion(owner) }
                }
            }) failure = "LOCAL_PROTECTION_PERSISTENCE"
            material?.fill(0); state?.fill(0); op.nameBytes.fill(0)
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
                    op.owner!!.read { check(alive(op, permit)) }
                    lifecycle.complete(permit)
                    releaseAndComplete(op, value, null)
                } catch (_: Exception) { lifecycle.invalidate(); releaseAndComplete(op, null, "LOCKED") }
            }
        }
    }
    private fun retired(epoch: Long) {
        val op = synchronized(gate) { operation?.takeIf { it.epoch == epoch }?.also { it.retired = true } } ?: return
        // 取消中断本次认证/HTTP，不删原日志或表示服务器取消；所有释放在 worker 排空。
        listOf<() -> Unit>({ op.flow?.invalidate() }, { op.owner?.retire() }, { op.signal?.cancel() })
            .forEach { cleanup.attempt(it) }
        if (!op.workerStarted) fail(op, op.fixedFailure)
    }
    private fun fail(op: Operation, error: String) {
        if (!op.workerStarted) releaseAndComplete(op, null, error)
    }
    private fun releaseAndComplete(op: Operation, value: String?, error: String?) {
        if (!op.cleanupScheduled.compareAndSet(false, true)) return
        worker.execute {
            var fixedError = error
            op.nameBytes.fill(0)
            op.opening?.ciphertext?.fill(0); op.opening = null
            if (!cleanup.attempt { op.owner?.close() }) fixedError = "LOCAL_PROTECTION_PERSISTENCE"
            op.owner = null
            main.post {
                val outcome = if (cleanup.unconfirmed) "LOCAL_PROTECTION_PERSISTENCE" else fixedError
                val allowed = outcome == null && !op.retired && op.permit?.let(lifecycle::canDeliverCompleted) == true
                if (!allowed && !op.retired) lifecycle.invalidate()
                if (op.completed.compareAndSet(false, true)) {
                    synchronized(gate) { if (operation === op) operation = null }
                    drain.finish(if (cleanup.unconfirmed) "LOCAL_PROTECTION_PERSISTENCE" else null)
                    try { op.completion.complete(if (allowed) value else null, if (allowed) null else outcome ?: "LOCKED") }
                    finally { if (disposed) worker.shutdown() }
                }
            }
        }
    }
    fun dispose() {
        mainThread(); if (disposed) return
        disposed = true; lifecycle.dispose()
        // sticky cleanup 阻止新 admission，不能在无 worker/drain 时阻止 executor 结束。
        if (!operationOrDrainActive()) worker.shutdown()
    }
}
