package org.harmoniavault.harmonia_mobile.nativebridge

/** 真实 dispatcher 使用的清理闭锁逻辑；不模拟或授予 SDK 认证。 */
internal object NativeDAGCleanupHostTest {
    @JvmStatic fun main(args: Array<String>) {
        var cases = 0
        for (failedResource in listOf("flow", "device", "owner")) {
            val cleanup = NativeDAGCleanup()
            val attempted = mutableListOf<String>()
            val lifecycle = NativeSlotLifecycle({ 1000L }, { _, _ -> NativeSlotTimer {} }, 41)
            lifecycle.onResumed(true)
            val oldEpoch = lifecycle.platformEpoch()
            // 每一步独立尝试；关闭不明不会短路后续 device/owner 清理。
            for (resource in listOf("flow", "captured-buffer", "device", "owner")) {
                cleanup.attempt {
                    attempted += resource
                    if (resource == failedResource) error("synthetic close failure")
                }
            }
            check(attempted == listOf("flow", "captured-buffer", "device", "owner"))
            check(cleanup.unconfirmed)
            lifecycle.invalidate()
            check(lifecycle.platformEpoch() != oldEpoch)
            // 新 platform epoch 或成功的后续清理都不能复开此 dispatcher。
            check(cleanup.attempt { attempted += "remaining-cleanup" })
            check(cleanup.unconfirmed)
            cases++
        }
        run {
            val cleanup = NativeDAGCleanup()
            var attempts = 0
            repeat(4) { check(cleanup.attempt { attempts++ }) }
            check(attempts == 4 && !cleanup.unconfirmed)
            cases++
        }
        println("PASS native cleanup host cases=" + cases)
    }
}
