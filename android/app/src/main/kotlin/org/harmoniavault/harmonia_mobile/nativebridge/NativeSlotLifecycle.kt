package org.harmoniavault.harmonia_mobile.nativebridge

import java.security.SecureRandom

internal fun interface NativeSlotTimer { fun cancel() }

/**
 * native 宿主生命周期。稳定 generation 不等于认证，更不等于 SlotSnapshotLease.operationEpoch。
 * timer、retirement callback 均在 gate 外执行；Go Close/drain 不可放入立即 callback。
 * A 分片仅接收 Activity 事件，尚未接生产 BiometricPrompt/业务入口。
 */
internal class NativeSlotLifecycle(
    private val clockMillis: () -> Long,
    private val schedule: (Long, () -> Unit) -> NativeSlotTimer,
    initialEpoch: Long = freshEpoch(),
    private val onRetired: (Long) -> Unit = {},
) {
    internal enum class Phase { PREPARED, AUTH_WAIT, AUTH_WAIT_STOPPED, WAIT_FOREGROUND, READY, ACTIVE, CLOSED, DEAD }
    internal class Ticket private constructor(
        internal val platformEpoch: Long,
        internal val operationEpoch: Long,
        private val operationSerial: Long,
        internal val cryptoIdentity: Any,
        internal val authDeadline: Long,
    ) {
        internal var phase = Phase.PREPARED
        internal var deadline = authDeadline
        internal var succeeded = false
        companion object {
            internal fun create(platform: Long, operationEpoch: Long, serial: Long, crypto: Any, deadline: Long) = Ticket(platform, operationEpoch, serial, crypto, deadline)
        }
        override fun toString() = "<native authentication ticket>"
    }
    internal class Permit private constructor(internal val ticket: Ticket) {
        companion object { internal fun create(ticket: Ticket) = Permit(ticket) }
        override fun toString() = "<native operation permit>"
    }
    private val gate = Any()
    private var generation = initialEpoch
    private var nextOperation = 0L
    private var disposed = false
    private var resumed = false
    private var unlocked = false
    private var ticket: Ticket? = null
    private var timer: NativeSlotTimer? = null
    private var timerSerial = 0L

    init { require(initialEpoch > 0) }
    companion object {
        private const val MAX_AUTH = 120_000L
        private const val STOP_PARKING = 30_000L
        private const val WAIT_RESUME = 5_000L
        private const val MAX_OPERATION = 30_000L
        private fun freshEpoch(): Long {
            val random = SecureRandom()
            var epoch: Long
            do { epoch = random.nextLong() and Long.MAX_VALUE } while (epoch == 0L || epoch == Long.MAX_VALUE)
            return epoch
        }
    }
    private fun <T> transition(action: (MutableList<() -> Unit>) -> T): T {
        val effects = mutableListOf<() -> Unit>()
        var actionFailure: Throwable? = null
        var result: T? = null
        synchronized(gate) {
            try { result = action(effects) } catch (failure: Throwable) { actionFailure = failure }
        }
        // 抛出拒绝异常前也须完成死票/取消效果；外部效果不占 native gate。
        var cleanupFailure: Exception? = null
        effects.forEach { effect -> try { effect() } catch (e: Exception) { if (cleanupFailure == null) cleanupFailure = e } }
        if (cleanupFailure != null) { dispose(); throw IllegalStateException("native lifecycle cleanup unconfirmed") }
        actionFailure?.let { throw it }
        @Suppress("UNCHECKED_CAST")
        return result as T
    }
    private fun disarm(effects: MutableList<() -> Unit>) {
        timerSerial++
        val previous = timer
        timer = null
        if (previous != null) effects += { previous.cancel() }
    }
    private fun arm(t: Ticket, effects: MutableList<() -> Unit>) {
        disarm(effects)
        val serial = timerSerial
        val delay = (t.deadline - clockMillis()).coerceAtLeast(0)
        effects += {
            val pending = schedule(delay) { timeout(t, serial) }
            val accepted = synchronized(gate) {
                if (!disposed && ticket === t && t.phase != Phase.DEAD && serial == timerSerial) { timer = pending; true } else false
            }
            if (!accepted) pending.cancel()
        }
    }
    private fun retire(effects: MutableList<() -> Unit>, permanent: Boolean = false) {
        if (disposed) return
        val old = generation
        ticket?.phase = Phase.DEAD
        ticket = null
        disarm(effects)
        resumed = false
        unlocked = false
        if (permanent || generation == Long.MAX_VALUE) disposed = true else generation++
        effects += { onRetired(old) }
    }
    private fun valid(t: Ticket): Boolean = !disposed && ticket === t && t.platformEpoch == generation && t.phase != Phase.DEAD && t.phase != Phase.CLOSED && clockMillis() < t.deadline
    private fun timeout(t: Ticket, serial: Long) = transition { effects ->
        if (!disposed && ticket === t && timerSerial == serial) {
            if (clockMillis() >= t.deadline) retire(effects) else arm(t, effects)
        }
    }
    fun platformEpoch(): Long = synchronized(gate) { check(!disposed); generation }
    fun isOperationActive(permit: Permit): Boolean = synchronized(gate) {
        valid(permit.ticket) && permit.ticket.phase == Phase.ACTIVE && resumed && unlocked
    }
    fun onResumed(deviceUnlocked: Boolean) = transition { effects ->
        if (!disposed) {
            if (!deviceUnlocked) retire(effects) else {
                resumed = true; unlocked = true
                val t = ticket
                if (t != null) {
                    if (!valid(t)) retire(effects)
                    else if (t.succeeded && t.phase == Phase.WAIT_FOREGROUND) { t.phase = Phase.READY; arm(t, effects) }
                    // resume 没有成功 callback 时不产生 permit，也不延长 stopped deadline。
                }
            }
        }
    }
    fun onPaused() = transition { effects ->
        if (!disposed) {
            resumed = false
            when (ticket?.phase) {
                Phase.AUTH_WAIT, Phase.AUTH_WAIT_STOPPED, Phase.WAIT_FOREGROUND -> Unit
                else -> retire(effects)
            }
        }
    }
    fun onStopped() = transition { effects ->
        if (!disposed) {
            resumed = false
            val t = ticket
            if (t == null || !valid(t)) retire(effects)
            else when (t.phase) {
                Phase.AUTH_WAIT -> { t.phase = Phase.AUTH_WAIT_STOPPED; t.deadline = minOf(t.deadline, clockMillis() + STOP_PARKING); arm(t, effects) }
                Phase.AUTH_WAIT_STOPPED, Phase.WAIT_FOREGROUND -> Unit
                else -> retire(effects)
            }
        }
    }
    fun onUserLeaveHint() = transition { retire(it) }
    fun onScreenOff() = transition { retire(it) }
    fun invalidate() = transition { retire(it) }
    fun dispose() = transition { retire(it, permanent = true) }

    /** 仅未来原生 dispatcher 从实际 SlotSnapshotLease 取 epoch，取得完整 owner/Cipher 后调用。
     * 本类的私有 serial 只是防复用票身份，不能冒充真实文件owner epoch。未授任何业务执行。 */
    fun prepareAuthentication(cryptoIdentity: Any, capturedOperationEpoch: Long): Ticket = transition { effects ->
        check(!disposed && resumed && unlocked && ticket == null && capturedOperationEpoch > 0) { "native authentication unavailable" }
        if (nextOperation == Long.MAX_VALUE) { retire(effects, permanent = true); error("native operation counter exhausted") }
        val now = clockMillis()
        check(now >= 0 && now <= Long.MAX_VALUE - MAX_AUTH)
        Ticket.create(generation, capturedOperationEpoch, ++nextOperation, cryptoIdentity, now + MAX_AUTH).also { ticket = it }
    }
    /** 必须紧邻真实 SDK authenticate 调用；prepare 票本身不能停后台后续办。 */
    fun authenticationStarted(t: Ticket) = transition { effects ->
        if (!valid(t) || t.phase != Phase.PREPARED || !resumed || !unlocked) { retire(effects); error("native authentication ticket rejected") }
        t.phase = Phase.AUTH_WAIT
        arm(t, effects)
    }
    fun authenticationSucceeded(t: Ticket, cryptoIdentity: Any) = transition { effects ->
        // 迟到的旧成功 callback 被拒绝，但不能把新 generation/另一票退役。
        if (ticket !== t) error("native authentication callback rejected")
        if (!valid(t) || t.cryptoIdentity !== cryptoIdentity || t.succeeded || t.phase !in setOf(Phase.AUTH_WAIT, Phase.AUTH_WAIT_STOPPED)) {
            retire(effects); error("native authentication callback rejected")
        }
        t.succeeded = true
        if (resumed && unlocked) t.phase = Phase.READY
        else { t.phase = Phase.WAIT_FOREGROUND; t.deadline = minOf(t.deadline, clockMillis() + WAIT_RESUME) }
        arm(t, effects)
    }
    fun authenticationRejected(t: Ticket) = transition { effects ->
        // 迟到 callback 不能取消已经存在的另一新操作，但也不能复活旧票。
        if (ticket === t) retire(effects)
    }
    fun consume(t: Ticket): Permit = transition { effects ->
        if (!valid(t) || t.phase != Phase.READY || !t.succeeded || !resumed || !unlocked) {
            if (ticket === t && !valid(t)) retire(effects)
            error("native operation permit unavailable")
        }
        // 5秒仅等待SDK前台，不可误当已开始业务的5秒寿命；单次业务仍有独立30秒上限。
        // 不延长原认证票上限，也不改变Go owner/server的任何期限。
        t.deadline = minOf(t.authDeadline, clockMillis() + MAX_OPERATION)
        t.phase = Phase.ACTIVE
        arm(t, effects)
        Permit.create(t)
    }
    fun complete(permit: Permit) = transition { effects ->
        val t = permit.ticket
        if (!valid(t) || t.phase != Phase.ACTIVE || !resumed || !unlocked) {
            if (ticket === t) retire(effects)
            error("native operation result rejected")
        }
        t.phase = Phase.CLOSED; ticket = null; disarm(effects)
    }
}
