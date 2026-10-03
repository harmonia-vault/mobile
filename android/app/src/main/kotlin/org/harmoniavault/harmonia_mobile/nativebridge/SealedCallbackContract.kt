package org.harmoniavault.harmonia_mobile.nativebridge

/** gomobile把空Go []byte传为Java null；外部expected必须严格比较，不能成为省略检查。 */
internal object SealedCallbackContract {
    fun checkExpected(caller: ByteArray?, captured: ByteArray) {
        check((caller ?: ByteArray(0)).contentEquals(captured)) { "caller state conflict" }
    }
    fun requirePacket(packet: ByteArray?): ByteArray = checkNotNull(packet) { "sealed packet required" }
}
