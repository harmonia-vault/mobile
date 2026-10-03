package org.harmoniavault.harmonia_mobile.nativebridge.pinlocal

import android.content.Context
import android.os.Process
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import java.util.Base64

/** 仅原生构造固定slot；通道不能决定认证模式、scope、权限或lease。 */
internal class PinMethodChannelDispatcher(
    private val context: Context,
    private val workflowFilename: String,
    private val systemArtifacts: () -> Boolean,
    private val retireOwners: () -> Unit,
    private val certificates: () -> ByteArray,
    private val active: (NativePinOperation?) -> Unit,
) {
    private fun configuration(endpoint: String) = PinSlot("harmonia/mobile/app-pin/v1", workflowFilename, endpoint)

    fun hasArtifacts(): Boolean {
        val id = PinNativeStateCAS.slotID(context.packageName, "harmonia/mobile/app-pin/v1", workflowFilename)
        val directory = File(context.noBackupFilesDir, "harmonia/app-pin")
        val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        return keys.containsAlias("harmonia/app-pin/integrity/v1/${Process.myUid()}/$id") ||
            listOf("$id.pin", "$id.workflow-pin-v1.gcm").any { stem -> listOf("", ".bak", ".new").any { File(directory, stem + it).exists() } }
    }

    fun execute(request: PinChannelRequest): Any {
        val config = configuration(request.endpoint)
        if (request.method == "forgetLocalPIN") {
            // 明确本地清理无需猜PIN；不读取旧材料，不调用云vault删除。
            // 清理在同一个PIN业务锁内再次核对实际system残留，不假称删除系统钥匙。
            val cleanup = PinNativeSlot(context, config, retireOwners)
            cleanup.acquireOperation()
            try {
                if (systemArtifacts()) throw PinLocalException(PinLocalFault.STATE)
                cleanup.clearAll()
            } finally { cleanup.releaseOperation() }
            return mapOf("version" to 1, "cleared" to true, "trustedDevice" to false)
        }
        if (request.method == "localProtectionInfo") return information(config)
        if (systemArtifacts()) throw PinLocalException(PinLocalFault.STATE)
        val mode = when (request.method) {
            "setupLocalPIN" -> PinNativeMode.SETUP
            "executePINWorkflow" -> PinNativeMode.BUSINESS
            "executePINApproval" -> PinNativeMode.APPROVAL
            "executePINEnrollment" -> PinNativeMode.ENROLLMENT
            else -> throw PinLocalException(PinLocalFault.CONFIGURATION)
        }
        val ca = if (mode == PinNativeMode.SETUP) ByteArray(0) else certificates()
        try {
            NativePinCoreAdapter.prepare(context, config, mode, retireOwners, ca, request.shortCode).use { operation ->
                active(operation)
                try {
                    if (mode == PinNativeMode.SETUP) {
                        val scope = operation.scope
                        operation.provision(request.pin, request.reentry)
                        // 与成熟Go Device.publicInfo相同的公开Ed指纹；不作为信任证明。
                        val public = Base64.getUrlDecoder().decode(scope.signingPublicKey)
                        val id = MessageDigest.getInstance("SHA-256").digest(public).joinToString("") { "%02x".format(it.toInt() and 255) }
                        return JSONObject(mapOf("version" to 1, "deviceId" to id, "signingPublicKey" to scope.signingPublicKey,
                            "receivingPublicKey" to scope.receivingPublicKey, "trusted" to false)).toString()
                    }
                    return operation.execute(request.pin, request.command.toByteArray(Charsets.UTF_8))
                } finally { active(null) }
            }
        } finally { ca.fill(0) }
    }

    /** MAC包只做状态投影；不能将system-ready/PIN-entry布尔变成云端授权。 */
    private fun information(config: PinSlot): Map<String, Any> {
        val slot = PinNativeSlot(context, config, retireOwners)
        slot.acquireOperation()
        try {
            val system = systemArtifacts()
            val id = PinNativeStateCAS.slotID(context.packageName, config.namespace, config.slot)
            val directory = File(context.noBackupFilesDir, "harmonia/app-pin")
            val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            val hasPIN = keys.containsAlias("harmonia/app-pin/integrity/v1/${Process.myUid()}/$id") ||
                listOf("$id.pin", "$id.workflow-pin-v1.gcm").any { stem -> listOf("", ".bak", ".new").any { File(directory, stem + it).exists() } }
            var verdict = PinCapabilityClassifier(context).current()
            if (system && hasPIN) verdict = PinSystemVerdict.BLOCKED
            var upgrade = false
            var delay = 0
            if (hasPIN) {
                val durable = PinKeystoreStore(context, config, retireOwners)
                durable.acquire()
                try {
                    val snapshot = durable.readProtected()
                    upgrade = snapshot.upgradeRequired
                    delay = snapshot.attempts.delaySeconds
                    if (!upgrade && verdict == PinSystemVerdict.SYSTEM_READY) {
                        durable.markUpgradeRequired(snapshot.scope)
                        upgrade = true
                    }
                } catch (_: Exception) {
                    // 固定slot残留已明确，但MAC/保存失败不返回能力；仅保留PIN本地清理入口。
                    retireOwners()
                    verdict = PinSystemVerdict.BLOCKED
                    delay = 0
                } finally { durable.release() }
            }
            val mode = when {
                system && hasPIN -> "blocked"
                system -> "system" // 系统凭证暂不可用也不降级。
                hasPIN && verdict != PinSystemVerdict.BLOCKED -> "pin"
                hasPIN -> "blocked"
                verdict == PinSystemVerdict.SYSTEM_READY -> "system"
                verdict == PinSystemVerdict.NO_SYSTEM_AUTH -> "none"
                else -> "blocked"
            }
            return mapOf("version" to 1, "profile" to "harmonia/local-protection/v1", "mode" to mode,
                "systemCapability" to verdict.name, "deviceExists" to (system || hasPIN),
                "pinSetupAvailable" to (!system && !hasPIN && verdict == PinSystemVerdict.NO_SYSTEM_AUTH),
                "upgradeRequired" to upgrade, "pinWorkflowReady" to false, "delaySeconds" to delay,
                "pinForgetAvailable" to (hasPIN && !system))
        } catch (failure: Exception) {
            retireOwners()
            throw if (failure is PinLocalException) failure else PinLocalException(PinLocalFault.STATE)
        } finally { slot.releaseOperation() }
    }

    companion object {
        val METHODS = setOf("localProtectionInfo", "setupLocalPIN", "executePINWorkflow", "executePINApproval", "executePINEnrollment", "forgetLocalPIN")
    }
}

/** 清理通道的可控字节缓冲；永不格式化PIN/意图/短码到错误或日志。 */
internal class PinChannelRequest private constructor(
    val method: String, val endpoint: String, val command: String,
    val pin: ByteArray, val reentry: ByteArray, val shortCode: ByteArray,
) : AutoCloseable {
    override fun close() { pin.fill(0); reentry.fill(0); shortCode.fill(0) }
    override fun toString() = "<native PIN operation>"

    companion object {
        fun parse(method: String, arguments: Any?): PinChannelRequest {
            val values = arguments as? Map<*, *> ?: throw PinLocalException(PinLocalFault.CONFIGURATION)
            var pin = ByteArray(0); var confirmation = ByteArray(0); var code = ByteArray(0)
            try {
                val fields = when (method) {
                    "localProtectionInfo", "forgetLocalPIN" -> setOf("version", "endpoint")
                    "setupLocalPIN" -> setOf("version", "endpoint", "pin", "reentry")
                    "executePINWorkflow" -> setOf("version", "command", "pin")
                    "executePINApproval", "executePINEnrollment" -> setOf("version", "command", "pin", "shortCode")
                    else -> throw PinLocalException(PinLocalFault.CONFIGURATION)
                }
                if (values.keys != fields || values["version"] != 1) throw PinLocalException(PinLocalFault.CONFIGURATION)
                fun bytes(name: String): ByteArray = ((values[name] as? ByteArray) ?: throw PinLocalException(PinLocalFault.CONFIGURATION)).copyOf()
                if ("pin" in fields) {
                    pin = bytes("pin")
                    if (pin.size !in 6..32 || pin.any { it.toInt() !in 48..57 }) throw PinLocalException(PinLocalFault.CONFIGURATION)
                }
                if ("reentry" in fields) {
                    confirmation = bytes("reentry")
                    if (confirmation.size !in 6..32 || confirmation.any { it.toInt() !in 48..57 }) throw PinLocalException(PinLocalFault.CONFIGURATION)
                }
                if ("shortCode" in fields) {
                    code = bytes("shortCode")
                    if (code.size != 8 || code.any { it.toInt() !in 48..57 }) throw PinLocalException(PinLocalFault.CONFIGURATION)
                }
                val command = if ("command" in fields) values["command"] as? String ?: throw PinLocalException(PinLocalFault.CONFIGURATION) else ""
                if (command.toByteArray(Charsets.UTF_8).size > 32768) throw PinLocalException(PinLocalFault.CONFIGURATION)
                val endpoint = if ("endpoint" in fields) values["endpoint"] as? String ?: throw PinLocalException(PinLocalFault.CONFIGURATION)
                    else try { JSONObject(command).getString("endpoint") } catch (_: Exception) { throw PinLocalException(PinLocalFault.CONFIGURATION) }
                if (endpoint.length !in 1..2048) throw PinLocalException(PinLocalFault.CONFIGURATION)
                // 完整命令字段/重复JSON/操作版本/角色/原id随后由成熟Go严格核验，不在Kotlin重实现授权。
                return PinChannelRequest(method, endpoint, command, pin, confirmation, code)
            } catch (failure: Exception) {
                pin.fill(0); confirmation.fill(0); code.fill(0)
                throw if (failure is PinLocalException) failure else PinLocalException(PinLocalFault.CONFIGURATION)
            } finally {
                for (name in listOf("pin", "reentry", "shortCode")) (values[name] as? ByteArray)?.fill(0)
            }
        }
    }
}
