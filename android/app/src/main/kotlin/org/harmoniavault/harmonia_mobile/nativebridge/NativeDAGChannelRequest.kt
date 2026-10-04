package org.harmoniavault.harmonia_mobile.nativebridge

/** 仅公共通道的结构与缓冲所有权；操作语义仍由成熟Go Validate唯一判定。 */
internal class NativeDAGChannelRequest private constructor(
    val command: String,
    val completeCode: ByteArray,
) : AutoCloseable {
    override fun close() { completeCode.fill(0) }
    companion object {
        fun parse(arguments: Any?): NativeDAGChannelRequest {
            val values = arguments as? Map<*, *>
            val incoming = values?.get("completeCode") as? ByteArray
            try {
                check(values != null && values.keys == setOf("command", "completeCode"))
                val command = values["command"] as? String ?: error("command absent")
                check(command.toByteArray(Charsets.UTF_8).size in 1..32768)
                check(incoming != null && incoming.size <= 512)
                return NativeDAGChannelRequest(command, incoming.copyOf())
            } finally { incoming?.fill(0) }
        }
    }
}
