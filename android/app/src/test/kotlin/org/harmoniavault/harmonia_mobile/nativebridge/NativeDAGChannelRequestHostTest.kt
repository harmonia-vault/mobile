package org.harmoniavault.harmonia_mobile.nativebridge

object NativeDAGChannelRequestHostTest {
    @JvmStatic fun main(args: Array<String>) {
        var count = 0
        fun rejected(values: Any?, buffer: ByteArray? = null) {
            var failed = false
            try { NativeDAGChannelRequest.parse(values).close() } catch (_: Exception) { failed = true }
            check(failed); check(buffer == null || buffer.all { it == 0.toByte() }); count++
        }
        val input = byteArrayOf(65,66,67)
        val request = NativeDAGChannelRequest.parse(mapOf("command" to "SYNTHETIC_COMMAND", "completeCode" to input))
        check(input.all { it == 0.toByte() } && request.completeCode.contentEquals(byteArrayOf(65,66,67)))
        request.close(); check(request.completeCode.all { it == 0.toByte() }); count++
        NativeDAGChannelRequest.parse(mapOf("command" to "SYNTHETIC_COMMAND", "completeCode" to ByteArray(0))).close(); count++
        val extra = byteArrayOf(65); rejected(mapOf("command" to "SYNTHETIC_COMMAND", "completeCode" to extra, "authenticated" to true), extra)
        val oversized = ByteArray(513) { 65 }; rejected(mapOf("command" to "SYNTHETIC_COMMAND", "completeCode" to oversized), oversized)
        rejected(mapOf("command" to "SYNTHETIC_COMMAND", "completeCode" to listOf(65)))
        val wrong = byteArrayOf(65); rejected(mapOf("command" to false, "completeCode" to wrong), wrong)
        val empty = byteArrayOf(65); rejected(mapOf("command" to "", "completeCode" to empty), empty)
        val utf8 = byteArrayOf(65); rejected(mapOf("command" to "合".repeat(10923), "completeCode" to utf8), utf8)
        rejected(null)
        println("DAG_CHANNEL_PARSER_PASS=" + count)
    }
}
