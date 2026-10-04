package org.harmoniavault.harmonia_mobile.nativebridge

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

/** 外层只收精确 command/name；Go Validate 判定完整命令及已应用的 P4 来源。 */
internal class NativeDAGEnvironmentChannelRequest private constructor(
    val command: String,
    private var nameBuffer: ByteArray?,
) : AutoCloseable {
    @Synchronized fun validateOperation(operation: String) {
        val bytes = nameBuffer ?: error("request consumed")
        check(operation in OPERATIONS)
        if (operation == "createDAGEnvironment" || operation == "renameDAGEnvironment") {
            val decoded = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes))
            try {
                // Go 再校验自己的 TrimSpace/rune 合同，此处只拒绝空名和超长名字。
                val trimmed = decoded.trim { it.isWhitespace() || it == '\u0085' }
                check(trimmed.isNotEmpty() && Character.codePointCount(trimmed, 0, trimmed.length) <= 120)
            } finally { for (index in 0 until decoded.limit()) decoded.put(index, '\u0000') }
        } else check(bytes.isEmpty())
    }
    @Synchronized fun takeName(): ByteArray {
        val bytes = nameBuffer ?: error("request consumed")
        nameBuffer = null
        return bytes
    }
    @Synchronized override fun close() {
        nameBuffer?.fill(0)
        nameBuffer = null
    }
    override fun toString() = "<DAG environment request>"

    companion object {
        private val OPERATIONS = setOf("createDAGEnvironment", "renameDAGEnvironment", "rotateDAGEnvironment", "deleteDAGEnvironment", "pendingDAGEnvironments", "retryDAGEnvironment")
        fun parse(arguments: Any?): NativeDAGEnvironmentChannelRequest {
            val fields = arguments as? Map<*, *>
            val incoming = fields?.get("name") as? ByteArray
            var copy: ByteArray? = null
            try {
                check(fields != null && fields.keys == setOf("command", "name"))
                val command = fields["command"] as? String ?: error("command type")
                check(command.toByteArray(Charsets.UTF_8).size in 1..4096)
                check(incoming != null && incoming.size <= 480 && incoming.none { it == 0.toByte() })
                // 拒绝坏 UTF-8；不缓存解码明文。名称、角色、来源、原请求仍由 Go 判定。
                val decoded = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(incoming))
                try { check(decoded.length <= 480) }
                finally { for (index in 0 until decoded.limit()) decoded.put(index, '\u0000') }
                copy = incoming.copyOf()
                return NativeDAGEnvironmentChannelRequest(command, copy).also { copy = null }
            } finally {
                incoming?.fill(0)
                copy?.fill(0)
            }
        }
    }
}
