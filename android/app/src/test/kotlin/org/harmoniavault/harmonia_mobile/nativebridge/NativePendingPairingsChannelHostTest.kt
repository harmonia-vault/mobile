package org.harmoniavault.harmonia_mobile.nativebridge

/** 仅 envelope/传参边界，不冒充 Android、Go JNI 或权限业务实测。 */
object NativePendingPairingsChannelHostTest {
 @JvmStatic fun main(args: Array<String>) {
  var cases = 0
  fun reject(value: Any?) {
   check(runCatching { NativePendingPairingsChannelRequest.parse(value) }.isFailure)
   cases++
  }
  val command = "{\"version\":1,\"endpoint\":\"https://synthetic.invalid\",\"operation\":\"pendingPairingRequestsV5\"}"
  check(NativePendingPairingsChannelRequest.parse(mapOf("command" to command)).command == command); cases++
  reject(null); reject(command); reject(emptyMap<String, Any>())
  reject(mapOf("command" to 1)); reject(mapOf("command" to ""))
  for (field in listOf("completeCode", "shortCode", "scope", "token", "owner", "authenticated")) reject(mapOf("command" to command, field to true))
  reject(mapOf("command" to "a".repeat(4097)))
  reject(mapOf("command" to "中".repeat(1366)))
  check(NativePendingPairingsChannelRequest.parse(mapOf("command" to "a".repeat(4096))).command.length == 4096); cases++
  println("NativePendingPairingsChannelHostTest PASS cases=" + cases)
 }
}
