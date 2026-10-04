package org.harmoniavault.harmonia_mobile.nativebridge

object NativeDAGBusinessChannelHostTest {
    @JvmStatic fun main(args: Array<String>) {
        var passed = 0
        fun case(action: () -> Unit) { action(); passed++ }
        fun reject(action: () -> Unit) { check(runCatching(action).isFailure) }
        fun request(value: ByteArray) = NativeDAGBusinessChannelRequest.parse(mapOf("command" to "synthetic-command", "value" to value))
        case {
            val incoming = byteArrayOf(65, 66)
            val r = request(incoming)
            check(incoming.all { it == 0.toByte() })
            r.validateOperation("putDAGVariable")
            val owned = r.takeValue()
            check(owned.contentEquals(byteArrayOf(65, 66)))
            reject { r.takeValue() }
            owned.fill(0); r.close()
        }
        case { val r = request(ByteArray(0)); r.validateOperation("putDAGVariable"); r.close() }
        case {
            for (operation in listOf("deleteDAGVariable", "pendingDAGWrites", "retryDAGWrite")) {
                val r = request(ByteArray(0)); r.validateOperation(operation); r.close()
            }
        }
        case {
            for (operation in listOf("deleteDAGVariable", "pendingDAGWrites", "retryDAGWrite")) {
                val r = request(byteArrayOf(65)); reject { r.validateOperation(operation) }; r.close()
            }
        }
        case { val r = request(ByteArray(0)); reject { r.validateOperation("setVariable") }; r.close() }
        case {
            val incoming = byteArrayOf(65)
            reject { NativeDAGBusinessChannelRequest.parse(mapOf("command" to "x", "value" to incoming, "trustedDevice" to true)) }
            check(incoming.all { it == 0.toByte() })
        }
        case {
            val incoming = byteArrayOf(65)
            reject { NativeDAGBusinessChannelRequest.parse(mapOf("command" to 1, "value" to incoming)) }
            check(incoming.all { it == 0.toByte() })
        }
        case { reject { NativeDAGBusinessChannelRequest.parse(mapOf("command" to "x", "value" to "synthetic")) } }
        case {
            val incoming = ByteArray(65537) { 65 }
            reject { request(incoming) }; check(incoming.all { it == 0.toByte() })
        }
        case {
            val incoming = byteArrayOf(0xc0.toByte(), 0xaf.toByte())
            reject { request(incoming) }; check(incoming.all { it == 0.toByte() })
        }
        case {
            val r = request(ByteArray(65536) { 65 }); r.validateOperation("putDAGVariable")
            val owned = r.takeValue(); check(owned.size == 65536); owned.fill(0); r.close()
        }
        case {
            val r = request(byteArrayOf(65)); r.close(); r.close()
            reject { r.takeValue() }; reject { r.validateOperation("putDAGVariable") }
            check(r.toString() == "<DAG business request>")
        }
        case {
            val incoming = byteArrayOf(65)
            reject { NativeDAGBusinessChannelRequest.parse(mapOf("command" to "界".repeat(1366), "value" to incoming)) }
            check(incoming.all { it == 0.toByte() })
        }
        case {
            val incoming = byteArrayOf(65, 0, 66)
            reject { request(incoming) }; check(incoming.all { it == 0.toByte() })
        }
        println("DAG business channel host PASS $passed")
    }
}
