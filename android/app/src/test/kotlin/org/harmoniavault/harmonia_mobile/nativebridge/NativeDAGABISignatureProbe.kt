package org.harmoniavault.harmonia_mobile.nativebridge

import org.harmoniavault.go.mobilebridge.Mobilebridge
import org.harmoniavault.go.mobilebridge.NativeDAGRegistry
import org.harmoniavault.go.mobilebridge.VaultWorkflow

/** 仅编译探针：引用真实 gomobile Java types，不能计为JNI运行。 */
internal object NativeDAGABISignatureProbe {
    fun create(namespace: String, slot: String, nativeEpoch: Long): NativeDAGRegistry =
        Mobilebridge.newNativeDAGRegistry(namespace, slot, nativeEpoch)
    fun attach(flow: VaultWorkflow, registry: NativeDAGRegistry) = flow.attachDAGRegistry(registry)
    fun invalidate(flow: VaultWorkflow, registry: NativeDAGRegistry) { flow.invalidate(); registry.invalidate() }
    fun drain(registry: NativeDAGRegistry) = registry.close()
}
