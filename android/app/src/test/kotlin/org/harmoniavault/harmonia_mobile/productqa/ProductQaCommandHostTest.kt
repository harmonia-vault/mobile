package org.harmoniavault.harmonia_mobile.productqa

/** 无UI/Android执行，只验证testsocket的JSON输入边界。 */
object ProductQaCommandHostTest {
    @JvmStatic fun main(args: Array<String>) {
        val accepted = ProductQaCommand.parse("""{"version":1,"operation":"fill","label":"邮箱","value":"qa@example.invalid"}""")
        check(accepted.keys == setOf("version","operation","label","value")) { "valid frame rejected" }
        check(accepted["version"] == 1 && accepted["label"] == "邮箱") { "valid scalar rejected" }
        val rejects = listOf(
            """{"version":1,"version":1,"operation":"finish"}""",
            """{"version":1,"operation":"finish","operatio\u006e":"tap"}""",
            """{"version":"1","operation":"finish"}""",
            """{"version":1.0,"operation":"finish"}""",
            """{"version":01,"operation":"finish"}""",
            """{'version':1,'operation':'finish'}""",
            """{"version":1,"operation":"finish",}""",
            """{"version":1,"operation":{}}""",
            """{"version":1,"operation":"finish"}{}""",
            """{"version":1,"operation":"\uD800"}""",
            """{"version":1,"operation":"finish","value":"\x31"}"""
        )
        for (frame in rejects) {
            var rejected = false
            try { ProductQaCommand.parse(frame) } catch (_: IllegalArgumentException) { rejected = true }
            check(rejected) { "invalid flat frame accepted" }
        }
        println("PASS product QA flat command boundary: positive + 11 fixed rejects")
    }
}
