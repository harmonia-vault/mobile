package org.harmoniavault.harmonia_mobile.nativebridge

import java.util.concurrent.Executor
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean

/** 每个 P3 操作恰好一次排空：先 worker 关闭，再主线程交付，最后允许 shutdown。
 * 失败回调须永久标记清理不确定；它不是 caller 的认证/cleanup 许可。 */
internal class NativeAccountResetDrain {
    private val scheduled = AtomicBoolean()
    fun schedule(worker: Executor, clean: () -> Unit, failed: () -> Unit,
        post: (() -> Unit) -> Boolean, deliver: () -> Unit, after: () -> Unit) {
        if (!scheduled.compareAndSet(false, true)) return
        val complete = {
            try { deliver() } finally { after() }
        }
        try {
            worker.execute {
                try { clean() } catch (_: Exception) { failed() }
                if (!post(complete)) { failed(); after() }
            }
        } catch (_: RejectedExecutionException) {
            // executor 拒绝意味着未确认排空；只能交付 failure，绝不能伪装清理成功。
            failed()
            if (!post(complete)) after()
        }
    }
}
