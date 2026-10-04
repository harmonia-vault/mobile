package org.harmoniavault.harmonia_mobile.nativebridge

object NativeDAGEnvironmentChannelHostTest {
    @JvmStatic fun main(args: Array<String>) {
        var passed = 0
        fun case(action: () -> Unit) { action(); passed++ }
        fun reject(action: () -> Unit) { check(runCatching(action).isFailure) }
        fun request(name: ByteArray) = NativeDAGEnvironmentChannelRequest.parse(mapOf("command" to "synthetic-command", "name" to name))
        case {
            val incoming = "合成".toByteArray(); val r = request(incoming)
            check(incoming.all { it == 0.toByte() }); r.validateOperation("createDAGEnvironment")
            val owned = r.takeName(); check(owned.contentEquals("合成".toByteArray()))
            reject { r.takeName() }; owned.fill(0); r.close()
        }
        case { for (op in listOf("createDAGEnvironment", "renameDAGEnvironment")) {
            val r = request("合成".toByteArray()); r.validateOperation(op); r.close()
        } }
        case { for (op in listOf("rotateDAGEnvironment", "deleteDAGEnvironment", "pendingDAGEnvironments", "retryDAGEnvironment")) {
            val r = request(ByteArray(0)); r.validateOperation(op); r.close()
        } }
        case { for (op in listOf("rotateDAGEnvironment", "deleteDAGEnvironment", "pendingDAGEnvironments", "retryDAGEnvironment")) {
            val r = request("合成".toByteArray()); reject { r.validateOperation(op) }; r.close()
        } }
        case { for (op in listOf("createDAGEnvironment", "renameDAGEnvironment")) {
            val r = request(ByteArray(0)); reject { r.validateOperation(op) }; r.close()
        } }
        case { val r = request("   ".toByteArray()); reject { r.validateOperation("renameDAGEnvironment") }; r.close() }
        case { val r = request((" " + "a".repeat(120) + " ").toByteArray()); r.validateOperation("renameDAGEnvironment"); r.close() }
        case { val r = request("😀".repeat(120).toByteArray()); r.validateOperation("createDAGEnvironment"); r.close() }
        case { val r = request("a".repeat(121).toByteArray()); reject { r.validateOperation("createDAGEnvironment") }; r.close() }
        case { val r = request(ByteArray(0)); reject { r.validateOperation("putDAGVariable") }; r.close() }
        case {
            val incoming = byteArrayOf(65)
            reject { NativeDAGEnvironmentChannelRequest.parse(mapOf("command" to "x", "name" to incoming, "trustedDevice" to true)) }
            check(incoming.all { it == 0.toByte() })
        }
        case { val incoming = ByteArray(481) { 65 }; reject { request(incoming) }; check(incoming.all { it == 0.toByte() }) }
        case { val incoming = byteArrayOf(0xc0.toByte(), 0xaf.toByte()); reject { request(incoming) }; check(incoming.all { it == 0.toByte() }) }
        case { val incoming = byteArrayOf(65,0,66); reject { request(incoming) }; check(incoming.all { it == 0.toByte() }) }
        case { val incoming = byteArrayOf(65); reject { NativeDAGEnvironmentChannelRequest.parse(mapOf("command" to "界".repeat(1366), "name" to incoming)) }; check(incoming.all { it == 0.toByte() }) }
        case { val r = request(byteArrayOf(65)); r.close(); r.close(); reject { r.takeName() }; reject { r.validateOperation("createDAGEnvironment") }; check(r.toString() == "<DAG environment request>") }
        println("DAG environment channel host PASS $passed")
    }
}
