package org.harmoniavault.harmonia_mobile.nativebridge

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import org.harmoniavault.go.mobilebridge.Mobilebridge
import org.harmoniavault.go.mobilebridge.NativeAccountResetMail
import java.util.concurrent.Executors

/** 邮件申请只持有当次 RAM HTTP owner，不能读钥匙/账号/proof 或授予信任。 */
internal class NativeAccountResetMailDispatcher(
    private val activity: Activity, private val workflowFilename: String,
    private val certificates: () -> ByteArray, private val acceptsEndpoint: (String) -> Boolean,
    private val otherOperationsIdle: () -> Boolean,
) {
    internal fun interface Completion { fun complete(value: String?, fixedError: String?) }
    private class Operation(val epoch: Long, val input: ByteArray, val completion: Completion) {
        val deadline = SystemClock.elapsedRealtime() + 30_000
        @Volatile var retired = false
        @Volatile var native: NativeAccountResetMail? = null
        var timer: Runnable? = null
    }
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val cleanup = NativeDAGCleanup()
    private val drain = NativeOwnerDrainBarrier()
    @Volatile private var operation: Operation? = null
    @Volatile private var disposed = false
    @Volatile private var foreground = false
    @Volatile private var unlocked = false
    @Volatile private var epoch = 1L
    private fun mainThread() { check(Looper.myLooper() === Looper.getMainLooper()) }
    fun isBusy() = operation != null || drain.isDraining()
    fun onResumed(deviceUnlocked: Boolean) { mainThread(); foreground = true; unlocked = deviceUnlocked }
    fun onPaused() { mainThread(); foreground = false; invalidate() }
    fun onStopped() { mainThread(); foreground = false; invalidate() }
    fun onUserLeaveHint() { mainThread(); foreground = false; unlocked = false; invalidate() }
    fun onScreenOff() { mainThread(); foreground = false; unlocked = false; invalidate() }
    private fun alive(op: Operation) = !disposed && !cleanup.unconfirmed && !op.retired && operation === op &&
        op.epoch == epoch && foreground && unlocked && SystemClock.elapsedRealtime() < op.deadline
    fun execute(endpoint: String, email: ByteArray, completion: Completion) {
        mainThread()
        if (!acceptsEndpoint(endpoint) || email.size !in 1..320) { email.fill(0); completion.complete(null, "INVALID_COMMAND"); return }
        if (disposed || cleanup.unconfirmed || !foreground || !unlocked) { email.fill(0); completion.complete(null, "LOCKED"); return }
        if (isBusy() || !otherOperationsIdle()) { email.fill(0); completion.complete(null, "BUSY"); return }
        val op = Operation(epoch, email, completion); operation = op
        val timeout = Runnable { if (operation === op) invalidate() }; op.timer = timeout
        if (!main.postDelayed(timeout, 30_000)) { cleanup.attempt { error("timer unavailable") }; invalidate() }
        worker.execute {
            var value: String? = null; var failure: String? = null
            try {
                check(alive(op)); val ca = certificates()
                val native = try { Mobilebridge.openNativeAccountResetMail(endpoint,
                    activity.packageName + "\u0000harmonia/workflow-state/v1\u0000" + workflowFilename, ca) } finally { ca.fill(0) }
                op.native = native
                // Cancel may precede native construction; it cannot let a new HTTP escape.
                check(alive(op)); value = native.requestEmail(email); check(alive(op))
            } catch (_: Exception) { failure = "ACCOUNT_RESET_EMAIL_REJECTED" }
            finally { email.fill(0); cleanup.attempt { op.native?.close() }; op.native = null }
            val response = value; val fixedError = failure
            main.post {
                op.timer?.let(main::removeCallbacks); op.timer = null
                val allowed = fixedError == null && alive(op)
                if (operation === op) operation = null
                drain.finish(if (cleanup.unconfirmed) "LOCAL_PROTECTION_PERSISTENCE" else null)
                try { op.completion.complete(if (allowed) response else null,
                    if (allowed) null else if (cleanup.unconfirmed) "LOCAL_PROTECTION_PERSISTENCE" else fixedError ?: "LOCKED") }
                finally { if (disposed) worker.shutdown() }
            }
        }
    }
    fun invalidate() {
        mainThread(); check(epoch < Long.MAX_VALUE); epoch++
        val op = operation ?: return; op.retired = true
        cleanup.attempt { op.native?.close() }
    }
    fun cancelAndDrain(completion: (String?) -> Unit) {
        mainThread()
        if (!drain.begin(completion)) { completion("BUSY"); return }
        invalidate()
        if (operation == null) drain.finish(if (cleanup.unconfirmed) "LOCAL_PROTECTION_PERSISTENCE" else null)
    }
    fun dispose() { mainThread(); if (disposed) return; disposed = true; invalidate(); if (!isBusy()) worker.shutdown() }
}
