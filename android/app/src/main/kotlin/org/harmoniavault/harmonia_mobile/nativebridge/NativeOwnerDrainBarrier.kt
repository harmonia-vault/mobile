package org.harmoniavault.harmonia_mobile.nativebridge

/** 本地取消的完成屏障；调用方负责主线程串行。回调只在各 owner 排空后交付。 */
internal class NativeOwnerDrainBarrier {
    private var callback: ((String?) -> Unit)? = null
    fun isDraining() = callback != null
    fun begin(completion: (String?) -> Unit): Boolean {
        if (callback != null) return false
        callback = completion
        return true
    }
    fun finish(error: String?) {
        val pending = callback ?: return
        callback = null
        pending(error)
    }
    companion object {
        fun all(actions: List<((String?) -> Unit) -> Unit>, completion: (String?) -> Unit) {
            if (actions.isEmpty()) { completion(null); return }
            var remaining = actions.size
            var failure: String? = null
            actions.forEach { action ->
                var returned = false
                val settled: (String?) -> Unit = { error ->
                    if (!returned) {
                        returned = true
                        if (error != null) failure = if (error == "BUSY" && failure != "LOCAL_PROTECTION_PERSISTENCE") "BUSY" else "LOCAL_PROTECTION_PERSISTENCE"
                        remaining--
                        if (remaining == 0) completion(failure)
                    }
                }
                try { action(settled) } catch (_: Exception) { settled("LOCAL_PROTECTION_PERSISTENCE") }
            }
        }
    }
}
