package org.harmoniavault.harmonia_mobile.nativebridge.pinlocal

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

// 真正状态机的确定性prepare/register交错；不声称验证Android/Go/HTTP。
fun main() {
    val prepared = CountDownLatch(1)
    val continueRegister = CountDownLatch(1)
    val canceled = AtomicInteger()
    val executed = AtomicInteger()
    val disposed = AtomicBoolean()
    val rejected = AtomicBoolean()
    val gate = PinOperationOwnerGate<Any> { canceled.incrementAndGet() }
    val owner = Any()
    val worker = Thread {
        prepared.countDown()
        check(continueRegister.await(5, TimeUnit.SECONDS))
        try { gate.register(owner); executed.incrementAndGet() }
        catch (failure: PinLocalException) { check(failure.fault == PinLocalFault.CLOSED); rejected.set(true) }
    }
    worker.start()
    check(prepared.await(5, TimeUnit.SECONDS))
    gate.retire { disposed.set(true) }
    continueRegister.countDown()
    worker.join(5000)
    check(!worker.isAlive && disposed.get() && rejected.get() && canceled.get() == 1 && executed.get() == 0)
    val normalCanceled = AtomicInteger()
    val normal = PinOperationOwnerGate<Any> { normalCanceled.incrementAndGet() }
    normal.register(Any()); normal.retire(); normal.retire()
    check(normalCanceled.get() == 1)
    println("PASS: late owner rejected before execution; registered owner retired once")
}
