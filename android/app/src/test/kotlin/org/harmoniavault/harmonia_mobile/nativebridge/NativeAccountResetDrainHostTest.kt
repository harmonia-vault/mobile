package org.harmoniavault.harmonia_mobile.nativebridge

import java.util.concurrent.Executor
import java.util.concurrent.RejectedExecutionException

/** 仅排空业务顺序的 host 证据，不是 Android/Keystore/文件系统实证。 */
internal object NativeAccountResetDrainHostTest {
    @JvmStatic fun main(args: Array<String>) {
        for (mode in listOf("normal", "cleanup-failure", "retired-callback-failure", "worker-rejected", "main-rejected")) {
            val queue = mutableListOf<Runnable>()
            val main = mutableListOf<() -> Unit>()
            val events = mutableListOf<String>()
            var unconfirmed = false
            val worker = Executor { if (mode == "worker-rejected") throw RejectedExecutionException(); queue += it }
            val gate = NativeAccountResetDrain()
            val invoke = {
                gate.schedule(worker,
                    clean = { events += "close-and-release"; if (mode == "cleanup-failure") error("synthetic release failure") },
                    failed = { unconfirmed = true },
                    post = { if (mode == "main-rejected") false else { main += it; true } },
                    deliver = {
                        check(events == listOf("close-and-release") || mode == "worker-rejected")
                        check(unconfirmed == (mode in listOf("cleanup-failure", "worker-rejected")))
                        events += "completion"
                        if (mode == "retired-callback-failure") error("synthetic cancelled callback")
                    },
                    after = { events += "shutdown" },
                )
            }
            invoke(); invoke() // cancel/dispose/HTTP 三方竞争只能排一个 cleanup/completion。
            check(queue.size == if (mode == "worker-rejected") 0 else 1)
            queue.forEach { it.run() }
            if (mode != "main-rejected") {
                check(main.size == 1 && events.none { it == "shutdown" })
                try { main.single().invoke() } catch (_: IllegalStateException) { check(mode == "retired-callback-failure") }
                check(events.count { it == "completion" } == 1)
            } else check(unconfirmed && main.isEmpty())
            check(events.last() == "shutdown" && events.count { it == "shutdown" } == 1)
        }
        println("PASS account reset drain host cases=5; Android/JNI/Keystore UNRUN")
    }
}
