package org.harmoniavault.harmonia_mobile.nativebridge

internal object NativeControlledEndpointScopeHostTest {
    @JvmStatic fun main(args: Array<String>) {
        val first = "https://first.synthetic.invalid"; val next = "https://next.synthetic.invalid"
        val scope = NativeControlledEndpointScope()
        check(scope.accepts(first) && scope.claimResetFlow(first)); check(!scope.claimResetFlow(next)); check(!scope.accepts(next))
        scope.releaseResetFlow(false); check(!scope.accepts(next)) // 未排空或DAG/ordinary仍占用。
        scope.releaseResetFlow(true); check(scope.claimResetFlow(next))
        scope.workflowOpened(next); scope.releaseResetFlow(true); check(!scope.accepts(first)) // P3不能释放ordinary来源。
        check(runCatching { scope.workflowOpened(first) }.isFailure)
        scope.releaseAfterLogoutDrain(); check(scope.accepts(first)); scope.workflowOpened(first)
        scope.dispose(); check(!scope.accepts(first) && !scope.claimResetFlow(first))
        check(runCatching { scope.workflowOpened(first) }.isFailure)
        println("PASS native controlled endpoint cases=6; identityinspection/trust/SDK UNRUN")
    }
}
