package org.harmoniavault.harmonia_mobile.nativebridge

/** 单个 dispatcher 的永久清理闭锁；成功的后续清理不能取消先前的不明结果。 */
internal class NativeDAGCleanup {
    @Volatile var unconfirmed: Boolean = false
        private set

    /** 每步分别调用，某步异常不阻止调用方继续尝试剩余资源。 */
    fun attempt(action: () -> Unit): Boolean = try {
        action()
        true
    } catch (_: Exception) {
        unconfirmed = true
        false
    }
}
