package org.harmoniavault.harmonia_mobile.nativebridge

/** P3 精确七动作；秘密为独立字节，不进入 command JSON 或 toString。 */
internal class NativeAccountResetChannelRequest private constructor(
    val method: String, val endpoint: String = "", val confirmation: String = "",
    private var input: ByteArray? = null,
) : AutoCloseable {
    fun takeInput(): ByteArray = (input ?: error("input absent")).also { input = null }
    override fun close() { input?.fill(0); input = null }
    override fun toString() = "NativeAccountResetChannelRequest(opaque)"
    companion object {
        val METHODS = setOf("requestAccountResetEmail", "beginAccountReset", "beginAccountResetQueryOnly",
            "queryAccountReset", "prepareAccountReset", "completeAccountReset", "cancelAccountReset")
        fun parse(method: String, arguments: Any?): NativeAccountResetChannelRequest {
            val map = arguments as? Map<*, *>
            val buffers = map?.values?.filterIsInstance<ByteArray>().orEmpty()
            var owned: ByteArray? = null
            try {
                require(method in METHODS)
                if (method in setOf("queryAccountReset", "completeAccountReset", "cancelAccountReset")) {
                    require(arguments == null)
                    return NativeAccountResetChannelRequest(method)
                }
                require(map != null)
                val field = when (method) {
                    "requestAccountResetEmail" -> "email"
                    "prepareAccountReset" -> "password"
                    else -> "proof"
                }
                val keys = if (field == "password") setOf(field, "confirmation") else setOf("endpoint", field)
                require(map.keys == keys)
                val incoming = map[field] as? ByteArray ?: error("bytes required")
                val limit = when (field) { "email" -> 320; "password" -> 16384; else -> 4096 }
                require(incoming.size in 1..limit)
                if (field == "email") require(incoming.none { it == 0.toByte() || it == 10.toByte() || it == 13.toByte() })
                // Go 成熟 DTO 负责 proof/credential 语义；这里只约束通道 UTF-8 与长度。
                Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(incoming))
                val endpoint = if (field == "password") "" else (map["endpoint"] as? String ?: error("endpoint required")).also {
                    require(it.toByteArray(Charsets.UTF_8).size in 1..2048 && '\u0000' !in it)
                }
                val confirmation = if (field != "password") "" else (map["confirmation"] as? String ?: error("confirmation required")).also {
                    require(it == "DELETE_OLD_VAULT")
                }
                owned = incoming.copyOf()
                return NativeAccountResetChannelRequest(method, endpoint, confirmation, owned).also { owned = null }
            } finally { buffers.forEach { it.fill(0) }; owned?.fill(0) }
        }
    }
}
