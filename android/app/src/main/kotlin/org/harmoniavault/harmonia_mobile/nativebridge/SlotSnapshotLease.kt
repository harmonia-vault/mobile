package org.harmoniavault.harmonia_mobile.nativebridge

/** 仅比较已捕获的完整包；不是云授权，也不从磁盘刷新已退役的 expected。 */
internal class SlotSnapshotLease(private val readSnapshot: () -> List<ByteArray>) {
    private var captured = readSnapshot().map { it.copyOf() }
    @Volatile private var alive = true
    private var transactionThread: Thread? = null
    private var epoch = epochs.incrementAndGet()
    companion object { private val epochs = java.util.concurrent.atomic.AtomicLong() }
    private fun requireAlive() { check(alive) { "slot owner retired" } }
    private fun same(a: List<ByteArray>, b: List<ByteArray>) = a.size == b.size && a.indices.all { a[it].contentEquals(b[it]) }
    private fun verify() {
        requireAlive()
        val current = readSnapshot()
        try { check(same(captured, current)) { "slot snapshot conflict" } }
        finally { current.forEach { it.fill(0) } }
    }
    @Synchronized fun <T> read(block: () -> T): T {
        try {
            requireAlive()
            if (transactionThread !== Thread.currentThread()) verify()
            val result = block()
            try { requireAlive() } catch (failure: Exception) { if (result is ByteArray) result.fill(0); throw failure }
            return result
        } catch (failure: Exception) { retire(); throw failure }
    }
    @Synchronized fun <T> mutate(onUnchangedFailure: (() -> Unit)? = null, block: () -> T): T {
        requireAlive()
        if (transactionThread === Thread.currentThread()) return block()
        try {
            verify(); transactionThread = Thread.currentThread()
            val result = block()
            requireAlive()
            val next = readSnapshot()
            requireAlive()
            captured.forEach { it.fill(0) }; captured = next
            return result
        } catch (failure: Exception) {
            // 只在原捕获快照仍精确相同的本次失败中消费预设native清理动作。
            // 不刷新 expected；readback不明且磁盘已变时不作推断。
            try {
                if (onUnchangedFailure != null && alive) {
                    val current = readSnapshot()
                    try { if (same(captured, current)) onUnchangedFailure() }
                    finally { current.forEach { it.fill(0) } }
                }
            } finally { retire() }
            throw failure
        }
        finally { transactionThread = null }
    }
    /** 本次私有清理票只可消费一次；清理异常也不能恢复旧 writer。 */
    @Synchronized fun clear(block: () -> Unit) {
        try { mutate(block = block) } finally { retire() }
    }
    fun retire() {
        // 先发布失效，再等待正在进行的短原子提交排空；绝不等Go业务/HTTP。
        alive = false
        synchronized(this) {
            if (captured.isEmpty()) return
            epoch = epochs.incrementAndGet()
            captured.forEach { it.fill(0) }; captured = emptyList()
        }
    }
    fun isAlive() = alive
    @Synchronized fun operationEpoch() = epoch
    override fun toString() = "<native slot owner>"
}

/** 两个释放步骤均已确认才允许同进程新fd；未知释放永久保留本进程busy。 */
internal object SlotReleaseGate {
    fun release(busy: java.util.concurrent.atomic.AtomicBoolean, releaseLock: () -> Unit, closeHandle: () -> Unit): Boolean {
        var confirmed = true
        try { releaseLock() } catch (_: Exception) { confirmed = false }
        try { closeHandle() } catch (_: Exception) { confirmed = false }
        if (confirmed) busy.set(false)
        return confirmed
    }
}
