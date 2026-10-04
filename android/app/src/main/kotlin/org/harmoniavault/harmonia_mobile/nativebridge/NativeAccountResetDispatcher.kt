package org.harmoniavault.harmonia_mobile.nativebridge

import android.app.Activity
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import org.harmoniavault.go.mobilebridge.Device
import org.harmoniavault.go.mobilebridge.Mobilebridge
import org.harmoniavault.go.mobilebridge.NativeAccountReset
import org.harmoniavault.go.mobilebridge.NativeAccountResetCleanup
import org.harmoniavault.go.mobilebridge.NativeAccountResetCommit
import org.harmoniavault.go.mobilebridge.VaultWorkflow
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** P3 封闭原生消费者。无 MethodChannel 注册、Flutter cap 或 caller cleanup/auth bool。
 * 邮件 proof 只证明云账号所有权；旧本机槽另经真实 CryptoObject + AEAD binding 校验。
 * PIN/混合/未知残留拒绝，不能作为空槽或通过 forgetLocalPIN 清除。 */
internal class NativeAccountResetDispatcher(
    private val activity: Activity,
    private val store: ProtectedDeviceStore,
    private val workflowFilename: String,
    private val certificates: () -> ByteArray,
    private val acceptsEndpoint: (String) -> Boolean,
    private val otherOperationsIdle: () -> Boolean,
    private val hasPINArtifacts: () -> Boolean,
    private val retireOtherRAMOwners: () -> Unit,
    // 主线程发起；只有原 DAG worker 的 Close/slot 排空 completion 才能回调 nil。
    private val drainDAGOwner: (String, (String?) -> Unit) -> Unit,
) {
    internal fun interface Completion { fun complete(value: String?, fixedError: String?) }
    private class Record(val endpoint: String, val native: NativeAccountReset)
    private class Operation(val epoch: Long, val completion: Completion, var input: ByteArray? = null) {
        val drain = NativeAccountResetDrain()
        val callbackConsumed = AtomicBoolean()
        @Volatile var retired = false
        @Volatile var workerRunning = false
        @Volatile var deadline = SystemClock.elapsedRealtime() + 30_000
        @Volatile var owner: NativeSlotOwner? = null
        @Volatile var flow: VaultWorkflow? = null
        var device: Device? = null
        var protected: ProtectedWorkflowStore? = null
        var state: ByteArray? = null
        var material: ByteArray? = null
        var prepared: NativeAccountResetCommit? = null
        var opening: ProtectedDeviceStore.Opening? = null
        var ticket: NativeSlotLifecycle.Ticket? = null
        var permit: NativeSlotLifecycle.Permit? = null
        var signal: CancellationSignal? = null
        var timer: Runnable? = null
        var authenticationCompleted = false
    }
    private val gate = Any()
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val cleanup = NativeDAGCleanup()
    @Volatile private var record: Record? = null
    @Volatile private var operation: Operation? = null
    @Volatile private var disposed = false
    @Volatile private var foreground = false
    @Volatile private var unlocked = false
    private val lifecycle = NativeSlotLifecycle(
        { SystemClock.elapsedRealtime() },
        { delay, action -> val task = Runnable { action() }; check(main.postDelayed(task, delay)); NativeSlotTimer { main.removeCallbacks(task) } },
        onRetired = { retireNative() },
    )
    private fun mainThread() { check(Looper.myLooper() === Looper.getMainLooper()) }
    fun isBusy() = operation != null
    fun onResumed(deviceUnlocked: Boolean) { mainThread(); foreground = true; unlocked = deviceUnlocked; lifecycle.onResumed(deviceUnlocked); tryStartAuthenticated() }
    fun onPaused() { mainThread(); foreground = false; lifecycle.onPaused() }
    fun onStopped() { mainThread(); foreground = false; lifecycle.onStopped() }
    fun onUserLeaveHint() { mainThread(); foreground = false; unlocked = false; lifecycle.onUserLeaveHint() }
    fun onScreenOff() { mainThread(); foreground = false; unlocked = false; lifecycle.onScreenOff() }
    fun invalidate() { mainThread(); lifecycle.invalidate() }

    private fun alive(op: Operation): Boolean = !disposed && !cleanup.unconfirmed && !op.retired && operation === op &&
        foreground && unlocked && lifecycle.platformEpoch() == op.epoch && SystemClock.elapsedRealtime() < op.deadline &&
        (op.permit?.let { if (op.authenticationCompleted) lifecycle.canDeliverCompleted(it) else lifecycle.isOperationActive(it) } ?: true)

    private fun acquire(completion: Completion, input: ByteArray? = null): Operation? {
        mainThread()
        if (disposed || cleanup.unconfirmed || !foreground || !unlocked) { input?.fill(0); completion.complete(null, "LOCKED"); return null }
        if (isBusy() || !otherOperationsIdle()) { input?.fill(0); completion.complete(null, "BUSY"); return null }
        val op = Operation(lifecycle.platformEpoch(), completion, input)
        operation = op
        val timer = Runnable { if (operation === op && SystemClock.elapsedRealtime() >= op.deadline) lifecycle.invalidate() }
        op.timer = timer; check(main.postDelayed(timer, 30_000))
        return op
    }

    /** 明确的新流程；旧 owner 存在时拒替换。不得将冷恢复路由至此。 */
    fun begin(endpoint: String, proof: ByteArray, completion: Completion) {
        beginInternal(endpoint, proof, completion, Mode.NEW)
    }
    /** 原 payload 已失的冷恢复：Go 类型状态永久阻止 prepare/complete。 */
    fun beginQueryOnly(endpoint: String, proof: ByteArray, completion: Completion) {
        beginInternal(endpoint, proof, completion, Mode.QUERY_ONLY)
    }
    private enum class Mode { NEW, QUERY_ONLY }
    private fun beginInternal(endpoint: String, proof: ByteArray, completion: Completion, mode: Mode) {
        mainThread()
        if (record != null || !acceptsEndpoint(endpoint) || proof.size !in 1..4096) { proof.fill(0); completion.complete(null, "INVALID_COMMAND"); return }
        val op = acquire(completion, proof) ?: return
        runSimple(op) {
            val ca = certificates()
            val namespace = activity.packageName + "\u0000harmonia/workflow-state/v1\u0000" + workflowFilename
            val native = try { when (mode) {
                Mode.NEW -> Mobilebridge.newNativeAccountReset(endpoint, namespace, proof, ca)
                Mode.QUERY_ONLY -> Mobilebridge.openNativeAccountResetQuery(endpoint, namespace, proof, ca)
            } }
                finally { proof.fill(0); ca.fill(0) }
            synchronized(gate) {
                if (!alive(op) || record != null) { native.close(); error("retired reset") }
                record = Record(endpoint, native)
            }
            native.query()
        }
    }
    fun query(completion: Completion) {
        val op = acquire(completion) ?: return
        runSimple(op) { (record ?: error("reset owner absent")).native.query() }
    }
    /** 一次性新密码输入；以后 retry/complete/query 均无密码/proof/endpoint 参数。 */
    fun prepare(password: ByteArray, confirmation: String, completion: Completion) {
        mainThread()
        if (password.size !in 1..16384 || confirmation != "DELETE_OLD_VAULT") { password.fill(0); completion.complete(null, "INVALID_COMMAND"); return }
        val op = acquire(completion, password) ?: return
        runSimple(op) {
            (record ?: error("reset owner absent")).native.prepare(password, confirmation)
            "{\"version\":1,\"prepared\":true,\"trustedDevice\":false}"
        }
    }
    private fun runSimple(op: Operation, action: () -> String) {
        op.workerRunning = true
        worker.execute {
            var value: String? = null; var error: String? = null
            try { check(alive(op)); value = action(); check(alive(op)) }
            catch (_: Exception) { error = "ACCOUNT_RESET_REJECTED" }
            finally { op.input?.fill(0); op.input = null }
            finish(op, value, error)
        }
    }

    /** BeginCompletion 的真实 Query 成功前不读钥匙、更不删除固定槽。 */
    fun complete(completion: Completion) {
        val op = acquire(completion) ?: return
        op.workerRunning = true
        worker.execute {
            try {
                check(alive(op)); op.prepared = (record ?: error("reset owner absent")).native.beginCompletion()
                check(alive(op))
                retireOtherRAMOwners() // 成熟 recovery owner 同步清钥，必须在 worker。
                main.post {
                    op.workerRunning = false
                    if (!alive(op)) finish(op, null, "LOCKED") else {
                        try { drainDAGOwner((record ?: error("reset owner absent")).endpoint) { error ->
                            if (error != null) finish(op, null, error) else prepareLocal(op)
                        } } catch (_: Exception) { finish(op, null, "LOCAL_PROTECTION_PERSISTENCE") }
                    }
                }
            } catch (_: Exception) { finish(op, null, "ACCOUNT_RESET_QUERY_REQUIRED") }
        }
    }
    private fun prepareLocal(op: Operation) {
        mainThread()
        try {
            check(alive(op))
            val owner = NativeSlotOwner.acquire(activity, workflowFilename, store.nativeFilename, store.nativeAlias)
            op.owner = owner
            owner.read { check(alive(op) && !hasPINArtifacts()) }
            val systemExists = owner.read { store.hasArtifacts() || ProtectedWorkflowStore(activity, workflowFilename).hasArtifacts() }
            if (!systemExists) {
                owner.assertTrackedSlotEmpty()
                op.workerRunning = true; worker.execute { performCompletion(op) }; return
            }
            check(Build.VERSION.SDK_INT >= 30 && store.supported())
            val opening = store.prepareOpen(owner); op.opening = opening
            val ticket = lifecycle.prepareAuthentication(opening.cipher, owner.operationEpoch()); op.ticket = ticket
            // 认证等待由既有真实 SDK lifecycle 的短时票管理，不能让公共 HTTP timer 延长它。
            op.timer?.let(main::removeCallbacks); op.timer = null
            op.deadline = SystemClock.elapsedRealtime() + 120_000
            val signal = CancellationSignal(); op.signal = signal
            val prompt = BiometricPrompt.Builder(activity).setTitle("和弦设备认证")
                .setSubtitle("确认清理此设备上的旧账号资料")
                .setAllowedAuthenticators(ProtectedDeviceStore.AUTHENTICATORS).build()
            lifecycle.authenticationStarted(ticket)
            prompt.authenticate(BiometricPrompt.CryptoObject(opening.cipher), signal, activity.mainExecutor,
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                        if (op.callbackConsumed.compareAndSet(false, true)) lifecycle.authenticationRejected(ticket)
                    }
                    override fun onAuthenticationFailed() {
                        if (op.callbackConsumed.compareAndSet(false, true)) lifecycle.authenticationRejected(ticket)
                    }
                    override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                        if (!op.callbackConsumed.compareAndSet(false, true)) return
                        try { lifecycle.authenticationSucceeded(ticket, result.cryptoObject?.cipher ?: error("crypto absent")); tryStartAuthenticated() }
                        catch (_: Exception) { lifecycle.authenticationRejected(ticket) }
                    }
                })
        } catch (_: Exception) { finish(op, null, "LOCAL_PROTECTION_STATE") }
    }
    private fun tryStartAuthenticated() {
        val op = operation ?: return; val ticket = op.ticket ?: return
        if (op.workerRunning || op.retired || !lifecycle.isAuthenticationReady(ticket)) return
        try {
            op.permit = lifecycle.consume(ticket); op.deadline = SystemClock.elapsedRealtime() + 30_000
            op.workerRunning = true; worker.execute { performCompletion(op) }
        } catch (_: Exception) { finish(op, null, "LOCKED") }
    }

    private fun performCompletion(op: Operation) {
        var response: String? = null; var failure: String? = null
        try {
            check(alive(op)); val prepared = op.prepared ?: error("validated query absent")
            val opening = op.opening
            if (opening != null) {
                val owner = op.owner ?: error("owner absent")
                op.material = store.openAuthenticated(opening.cipher, opening.ciphertext, owner)
                val device = Mobilebridge.importProtectedMaterial(op.material); op.device = device
                store.confirmImportedMaterial(owner); op.material?.fill(0); op.material = null
                val protected = ProtectedWorkflowStore(activity, workflowFilename, operationActive = { alive(op) }, owner = owner)
                op.protected = protected; op.state = protected.load()
                op.flow = device.openAtomicWorkflow((record ?: error("reset owner absent")).endpoint,
                    protected.namespace, op.state, certificates(), protected)
            }
            response = prepared.complete(object : NativeAccountResetCleanup {
                override fun clearAndReacquireEmpty() {
                    check(alive(op)); val old = op.owner ?: error("owner absent")
                    val flow = op.flow
                    if (flow != null) {
                        prepared.logoutMatchedWorkflow(flow) // Go 的私有 AEAD binding 匹配在 Logout 之前。
                        old.clear { store.delete(old); op.protected!!.delete(); store.finishDeletion(old) }
                    } else old.assertTrackedSlotEmpty()
                    closeSensitive(op)
                    check(!cleanup.unconfirmed && alive(op))
                    check(cleanup.attempt { old.close() }); op.owner = null
                    check(alive(op))
                    val fresh = NativeSlotOwner.acquire(activity, workflowFilename, store.nativeFilename, store.nativeAlias)
                    op.owner = fresh
                    fresh.read { check(alive(op) && !hasPINArtifacts()) }; fresh.assertTrackedSlotEmpty()
                }
                override fun checkEmpty() {
                    check(alive(op)); val owner = op.owner ?: error("fresh owner absent")
                    owner.read { check(alive(op) && !hasPINArtifacts()) }; owner.assertTrackedSlotEmpty()
                }
            })
            check(alive(op))
        } catch (_: Exception) { failure = "ACCOUNT_RESET_OR_CLEANUP_UNCONFIRMED" }
        finish(op, response, failure)
    }
    /** 每一资源独立尝试关闭；任何失败 sticky 阻断后续提交及成功交付。 */
    private fun closeSensitive(op: Operation) {
        cleanup.attempt { op.flow?.close() }; op.flow = null
        cleanup.attempt { op.protected?.closeCaptured() }; op.protected = null
        cleanup.attempt { op.device?.close() }; op.device = null
        op.material?.fill(0); op.material = null; op.state?.fill(0); op.state = null
        op.opening?.ciphertext?.fill(0); op.opening = null
    }
    private fun finish(op: Operation, value: String?, error: String?) {
        op.drain.schedule(worker, clean = {
            closeSensitive(op); cleanup.attempt { op.prepared?.close() }; op.prepared = null
            op.input?.fill(0); op.input = null
            // 最终空槽仍核对完整捕获；释放失败不能成功交付。HTTP 失败保留同 RAM Attempt 可 Query。
            if (value != null && op.owner != null) cleanup.attempt { op.owner!!.assertTrackedSlotEmpty() }
            cleanup.attempt { op.owner?.close() }; op.owner = null
        }, failed = { cleanup.attempt { throw IllegalStateException("reset drain unconfirmed") } }, post = { main.post(it) }, deliver = {
                op.timer?.let(main::removeCallbacks); op.timer = null
                var active = alive(op)
                if (active && op.permit != null) {
                    try { lifecycle.complete(op.permit!!); op.authenticationCompleted = true; active = alive(op) }
                    catch (_: Exception) { active = false }
                }
                // 云端未知但前台/原票有效时保留同 Attempt，下一次仍先 Query；退休才清 RAM。
                if (!active && op.ticket != null) lifecycle.invalidate()
                val allowed = error == null && active
                if (operation === op) operation = null
                val fixed = if (cleanup.unconfirmed) "LOCAL_PROTECTION_PERSISTENCE" else error ?: "LOCKED"
                op.completion.complete(if (allowed) value else null, if (allowed) null else fixed)
        }, after = { if (disposed) worker.shutdown() })
    }
    private fun retireNative() {
        val old: Record?; val op: Operation?
        synchronized(gate) { old = record; record = null; op = operation; op?.retired = true }
        cleanup.attempt { old?.native?.close() }
        cleanup.attempt { op?.flow?.invalidate() }
        cleanup.attempt { op?.owner?.retire() }
        cleanup.attempt { op?.signal?.cancel() }
        if (op != null && !op.workerRunning) finish(op, null, "LOCKED")
    }
    fun dispose() { mainThread(); if (disposed) return; disposed = true; lifecycle.dispose(); if (!isBusy()) worker.shutdown() }
}
