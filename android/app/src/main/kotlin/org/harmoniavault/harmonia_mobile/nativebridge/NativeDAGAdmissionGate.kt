package org.harmoniavault.harmonia_mobile.nativebridge

/** 实际 operation 与 worker→main drain 分开；票只由原生排队路径生成。 */
internal class NativeDAGAdmissionGate {
    internal class Drain private constructor() { companion object { fun fresh() = Drain() } }
    private var operation = false
    private var cancelling = false
    private val drains = mutableSetOf<Drain>()
    @Synchronized fun operationBegan() { check(!busy()); operation = true }
    @Synchronized fun operationEnded() { check(operation); operation = false }
    @Synchronized fun operationActive() = operation
    @Synchronized fun cancellationBegan() { cancelling = true }
    @Synchronized fun cancellationEnded() { check(canFinishCancellation()); cancelling = false }
    @Synchronized fun drainBegan(): Drain = Drain.fresh().also { drains += it }
    @Synchronized fun drainEnded(ticket: Drain) { check(drains.remove(ticket)) }
    @Synchronized fun canFinishCancellation() = !operation && drains.isEmpty()
    @Synchronized fun busy() = operation || cancelling || drains.isNotEmpty()
}
