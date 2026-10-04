package org.harmoniavault.harmonia_mobile.nativebridge

internal object NativeOwnerDrainBarrierHostTest {
    @JvmStatic fun main(args: Array<String>) {
        var cases = 0
        val barrier = NativeOwnerDrainBarrier(); var calls = 0
        check(barrier.begin { check(it == null); calls++ }); check(!barrier.begin { error("duplicate delivery") })
        check(barrier.isDraining() && calls == 0); barrier.finish(null); barrier.finish(null)
        check(!barrier.isDraining() && calls == 1); cases++
        for (failing in listOf(false, true)) {
            val completions = mutableListOf<(String?) -> Unit>(); val closed = mutableListOf<Int>(); var delivered = false
            NativeOwnerDrainBarrier.all((0..3).map { id -> { done: (String?) -> Unit ->
                completions += { error -> closed += id; done(error) }
            } }) { error ->
                check(closed.size == 4); check((error != null) == failing); check(!delivered); delivered = true
            }
            for (index in listOf(2,0,3)) { completions[index](if (failing && index == 2) "fixed" else null); check(!delivered) }
            completions[1](null); check(delivered); completions[1](null); cases++
        }
        var attempts = 0; var delivered = false
        NativeOwnerDrainBarrier.all(listOf({ _: (String?) -> Unit -> attempts++; error("synthetic cleanup failure") },
            { done -> attempts++; done(null); done(null) })) { error -> check(attempts == 2 && error != null && !delivered); delivered = true }
        check(delivered); cases++
        var resetAfterWorker = false; val worker = mutableListOf<() -> Unit>(); val events = mutableListOf<String>()
        worker += { events += "ordinary-finally" }
        NativeOwnerDrainBarrier.all(listOf({ done -> worker += { events += "ordinary-close"; done(null) } },
            { done -> events += "mail-close"; done(null) }, { done -> events += "pending-close"; done(null) })) {
                check(events.contains("ordinary-finally") && events.contains("ordinary-close")); resetAfterWorker = true
            }
        check(!resetAfterWorker); worker.forEach { it() }; check(resetAfterWorker); cases++
        println("PASS owner drain barrier cases=$cases; SDK/JNI UNRUN")
    }
}
