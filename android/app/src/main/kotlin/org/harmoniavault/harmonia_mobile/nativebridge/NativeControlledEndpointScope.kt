package org.harmoniavault.harmonia_mobile.nativebridge

/** 仅原生 RAM 服务范围：成功成熟 Atomic opener，或首次 P3 flow 固定地址。
 * 首次 flow 固定不是服务身份inspection/设备信任；不持久URL或接受Dart scope bool。 */
internal class NativeControlledEndpointScope {
    private var endpoint: String? = null
    private var openedWorkflow = false
    private var retired = false
    @Synchronized fun accepts(candidate: String): Boolean = !retired && (endpoint == null || endpoint == candidate)
    @Synchronized fun claimResetFlow(candidate: String): Boolean {
        if (!accepts(candidate)) return false
        endpoint = candidate
        return true
    }
    @Synchronized fun workflowOpened(candidate: String) {
        check(accepts(candidate)); endpoint = candidate; openedWorkflow = true
    }
    @Synchronized fun releaseResetFlow(otherOwnersIdle: Boolean) {
        if (!retired && otherOwnersIdle && !openedWorkflow) endpoint = null
    }
    @Synchronized fun releaseAfterLogoutDrain() {
        check(!retired); endpoint = null; openedWorkflow = false
    }
    @Synchronized fun dispose() { retired = true; endpoint = null; openedWorkflow = false }
}
