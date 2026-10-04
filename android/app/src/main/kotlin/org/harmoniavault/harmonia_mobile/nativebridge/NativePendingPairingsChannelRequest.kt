package org.harmoniavault.harmonia_mobile.nativebridge

/** 只有精确 channel envelope；Go 严格 DTO 验证在任何认证/解包之前。 */
internal class NativePendingPairingsChannelRequest private constructor(val command: String) {
    companion object {
        fun parse(arguments: Any?): NativePendingPairingsChannelRequest {
            val fields = arguments as? Map<*, *> ?: error("pending request envelope")
            check(fields.keys == setOf("command"))
            val command = fields["command"] as? String ?: error("pending command type")
            check(command.isNotEmpty() && command.toByteArray(Charsets.UTF_8).size <= 4096)
            return NativePendingPairingsChannelRequest(command)
        }
    }
    override fun toString() = "<pending pairing list request>"
}
