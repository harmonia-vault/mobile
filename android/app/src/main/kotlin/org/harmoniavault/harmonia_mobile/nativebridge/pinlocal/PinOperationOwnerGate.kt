package org.harmoniavault.harmonia_mobile.nativebridge.pinlocal

/** 所有权只来自原生生命周期。prepare之后的注册与dispose退役共用同一锁。 */
internal class PinOperationOwnerGate<T>(private val cancel: (T) -> Unit) {
    private val lock = Any()
    private var retired = false
    private var active: T? = null

    fun register(owner: T?) {
        val reject = synchronized(lock) {
            if (owner == null) { active = null; false }
            else if (retired) true
            else { active = owner; false }
        }
        if (reject) {
            // 在锁外同步取消，避免回调重入；owner从未可执行也从未成为active。
            try { cancel(owner!!) } finally { throw PinLocalException(PinLocalFault.CLOSED) }
        }
    }

    fun retire(beforeRetire: () -> Unit = {}) {
        val owner = synchronized(lock) {
            retired = true
            beforeRetire()
            val value = active
            active = null
            value
        }
        if (owner != null) cancel(owner)
    }
}
