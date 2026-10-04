package org.harmoniavault.harmonia_mobile.nativebridge

/** 使用生产admission gate与实际worker→main序，非Android/Go Close实证。 */
internal object NativeDAGAdmissionGateHostTest {
    @JvmStatic fun main(args: Array<String>) {
        for (explicit in listOf(false,true)) {
            val gate = NativeDAGAdmissionGate(); val worker = mutableListOf<() -> Unit>(); val main = mutableListOf<() -> Unit>()
            var closed = false; var delivered = false
            if (explicit) gate.cancellationBegan()
            val ticket = gate.drainBegan()
            worker += { closed = true; main += { gate.drainEnded(ticket); if (gate.canFinishCancellation()) { gate.cancellationEnded(); delivered = explicit } } }
            check(gate.busy() && !gate.canFinishCancellation()); check(runCatching { gate.operationBegan() }.isFailure)
            worker.single()(); check(closed && gate.busy() && !delivered) // worker完成仍等main确认。
            main.single()(); check(!gate.busy() && delivered == explicit)
            gate.operationBegan(); check(gate.operationActive()); gate.operationEnded()
        }
        val gate = NativeDAGAdmissionGate(); gate.operationBegan(); gate.cancellationBegan()
        val registry = gate.drainBegan(); val fence = gate.drainBegan()
        gate.operationEnded(); check(gate.busy() && !gate.canFinishCancellation())
        gate.drainEnded(registry); check(gate.busy() && !gate.canFinishCancellation())
        gate.drainEnded(fence); check(gate.canFinishCancellation()); gate.cancellationEnded(); check(!gate.busy())
        check(runCatching { gate.drainEnded(fence) }.isFailure)
        val unknown = NativeDAGCleanup(); unknown.attempt { error("synthetic close failure") }
        check(unknown.unconfirmed && (gate.busy() || unknown.unconfirmed))
        println("PASS DAG admission queue cases=4; Android/JNI UNRUN")
    }
}
