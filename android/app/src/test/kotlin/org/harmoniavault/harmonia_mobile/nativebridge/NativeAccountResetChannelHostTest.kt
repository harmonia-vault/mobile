package org.harmoniavault.harmonia_mobile.nativebridge

internal object NativeAccountResetChannelHostTest {
    @JvmStatic fun main(args: Array<String>) {
        var cases = 0
        fun rejected(method: String, arguments: Any?) {
            check(runCatching { NativeAccountResetChannelRequest.parse(method, arguments) }.isFailure)
            (arguments as? Map<*, *>)?.values?.filterIsInstance<ByteArray>()?.forEach { check(it.all { b -> b == 0.toByte() }) }
            cases++
        }
        val endpoint = "https://synthetic.invalid"
        val incoming = "synthetic@account.invalid".toByteArray()
        NativeAccountResetChannelRequest.parse("requestAccountResetEmail", mapOf("endpoint" to endpoint, "email" to incoming)).use {
            check(incoming.all { b -> b == 0.toByte() }); val owned = it.takeInput(); check(owned.isNotEmpty()); owned.fill(0)
        }; cases++
        for (method in listOf("beginAccountReset", "beginAccountResetQueryOnly")) {
            val proof = "{}".toByteArray()
            val request = NativeAccountResetChannelRequest.parse(method, mapOf("endpoint" to endpoint, "proof" to proof))
            val owned = request.takeInput(); request.close(); check(owned.contentEquals("{}".toByteArray())); owned.fill(0)
            check(proof.all { it == 0.toByte() }); cases++
        }
        for (method in listOf("queryAccountReset", "completeAccountReset", "cancelAccountReset")) {
            NativeAccountResetChannelRequest.parse(method, null).close(); rejected(method, emptyMap<String, Any>()); cases++
        }
        val password = "synthetic-password".toByteArray()
        NativeAccountResetChannelRequest.parse("prepareAccountReset", mapOf("password" to password, "confirmation" to "DELETE_OLD_VAULT")).close()
        check(password.all { it == 0.toByte() }); cases++
        rejected("requestAccountResetEmail", mapOf("endpoint" to endpoint, "email" to "x.invalid".toByteArray(), "authenticated" to true))
        rejected("beginAccountReset", mapOf("endpoint" to endpoint, "proof" to ByteArray(4097) { 1 }))
        rejected("prepareAccountReset", mapOf("password" to byteArrayOf(0xC3.toByte()), "confirmation" to "DELETE_OLD_VAULT"))
        rejected("prepareAccountReset", mapOf("password" to byteArrayOf(65), "confirmation" to "OTHER"))
        rejected("requestAccountResetEmail", mapOf("endpoint" to endpoint, "email" to byteArrayOf(65, 10)))
        rejected("beginAccountReset", mapOf("endpoint" to endpoint, "proof" to listOf(1,2)))
        check(cases == 16); println("PASS account reset strict channel cases=16; SDK/JNI UNRUN")
    }
}
