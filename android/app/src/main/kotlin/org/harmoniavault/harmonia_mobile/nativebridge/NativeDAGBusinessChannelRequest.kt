package org.harmoniavault.harmonia_mobile.nativebridge

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

/** 外层只收精确 command/value；Go Validate 判定完整命令及已应用的 P4 来源。 */
internal class NativeDAGBusinessChannelRequest private constructor(
    val command: String,
    private var valueBuffer: ByteArray?,
) : AutoCloseable {
    @Synchronized fun validateOperation(operation: String) {
        val bytes = valueBuffer ?: error("request consumed")
        check(operation in OPERATIONS)
        check(operation == "putDAGVariable" || bytes.isEmpty())
    }
    @Synchronized fun takeValue(): ByteArray {
        val bytes = valueBuffer ?: error("request consumed")
        valueBuffer = null
        return bytes
    }
    @Synchronized override fun close() {
        valueBuffer?.fill(0)
        valueBuffer = null
    }
    override fun toString() = "<DAG business request>"

    companion object {
        private val OPERATIONS = setOf("putDAGVariable", "deleteDAGVariable", "pendingDAGWrites", "retryDAGWrite")
        fun parse(arguments: Any?): NativeDAGBusinessChannelRequest {
            val fields = arguments as? Map<*, *>
            val incoming = fields?.get("value") as? ByteArray
            var copy: ByteArray? = null
            try {
                check(fields != null && fields.keys == setOf("command", "value"))
                val command = fields["command"] as? String ?: error("command type")
                check(command.toByteArray(Charsets.UTF_8).size in 1..4096)
                check(incoming != null && incoming.size <= 65536 && incoming.none { it == 0.toByte() })
                // 拒绝坏 UTF-8；不缓存解码明文。变量名、角色、来源、原请求仍由 Go 判定。
                val decoded = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(incoming))
                try { check(decoded.length <= 65536) }
                finally { for (index in 0 until decoded.limit()) decoded.put(index, '\u0000') }
                copy = incoming.copyOf()
                return NativeDAGBusinessChannelRequest(command, copy).also { copy = null }
            } finally {
                incoming?.fill(0)
                copy?.fill(0)
            }
        }
    }
}
