package org.harmoniavault.harmonia_mobile.nativebridge.pinlocal

import android.content.Context
import org.harmoniavault.harmonia_mobile.nativebridge.NativeSlotOwner
import java.io.File
import java.security.KeyStore
import java.util.concurrent.atomic.AtomicBoolean

/** 私有Go adapter做JSON/ByteArray转换；这些接口不是gomobile导出或MethodChannel ABI。 */
internal data class PinProvisioned(val encryptedRecord: ByteArray, val attempts: PinAttemptState)
internal interface PinNativeCore : AutoCloseable {
    val scope: PinScope
    fun create(pin: ByteArray, reentry: ByteArray): PinProvisioned
    fun execute(pin: ByteArray, completeCanonicalIntent: ByteArray, snapshot: PinProtectedSnapshot, store: PinDurableStore): String
    override fun close()
}

/** bridge须同步清旧Go context/keys/journal/registry；未提供完整适配前产品能力保持关闭。 */
internal interface PinLocalCleanup { fun clearProtectedWorkflowAndDevice() }

/** 仅独立未接产品适配。系统模式不能调用该provider作为失败/取消后的回退。 */
internal class LocalPinProvider(
    private val context: Context,
    private val core: PinNativeCore,
    private val retireOwners: () -> Unit,
    private val cleanup: PinLocalCleanup,
    // 固定native slot映射，不从Dart传入文件名/alias或授权bool。
    private val systemKeyFilename: String = "device-keys-v1.gcm",
    private val systemStateFilename: String = "workflow-state-v1.gcm",
    private val systemKeyAlias: String = "harmonia/device-key-wrap/v1",
    private val slotOwner: NativeSlotOwner? = null,
) : AutoCloseable {
    private val capability = PinCapabilityClassifier(context)
    private val busy = AtomicBoolean()
    @Volatile private var closed = false
    private val scope = core.scope.also { it.validate(); check(it.packageName == context.packageName) }
    private val store = PinKeystoreStore(context, PinSlot(scope.namespace, scope.slot, scope.endpoint), retireOwners, slotOwner = slotOwner)
    private fun availableForSetup() {
        when (capability.current()) {
            PinSystemVerdict.NO_SYSTEM_AUTH -> Unit
            PinSystemVerdict.SYSTEM_READY -> { retireOwners(); throw PinLocalException(PinLocalFault.UPGRADE_REQUIRED) }
            PinSystemVerdict.BLOCKED -> { retireOwners(); throw PinLocalException(PinLocalFault.BLOCKED) }
        }
    }
    private inline fun <T> operation(block: () -> T): T {
        if (!busy.compareAndSet(false, true)) { retireOwners(); throw PinLocalException(PinLocalFault.BUSY) }
        try {
            if (closed) throw PinLocalException(PinLocalFault.CLOSED)
            return block()
        } catch (failure: Exception) {
            retireOwners()
            if (failure !is PinLocalException || failure.fault in listOf(PinLocalFault.PERSISTENCE, PinLocalFault.STATE, PinLocalFault.CLOSED)) { closed = true; core.close() }
            if (failure is PinLocalException) throw failure
            throw PinLocalException(PinLocalFault.BLOCKED)
        } finally { busy.set(false) }
    }
    private fun freshIdentityOnly() {
        for (name in listOf(systemKeyFilename, systemKeyFilename + ".setup-v1.mac", systemStateFilename)) {
            if (!name.matches(Regex("[A-Za-z0-9][A-Za-z0-9._-]{0,127}"))) throw PinLocalException(PinLocalFault.CONFIGURATION)
            for (suffix in listOf("", ".bak", ".new")) if (File(File(context.noBackupFilesDir, "harmonia"), name + suffix).exists()) throw PinLocalException(PinLocalFault.STATE)
        }
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (ks.containsAlias(systemKeyAlias) || ks.containsAlias(systemKeyAlias + "/setup-integrity/v1")) throw PinLocalException(PinLocalFault.STATE)
    }
    fun provision(pin: ByteArray, fullReentry: ByteArray) {
        try { operation {
            availableForSetup(); freshIdentityOnly()
            store.acquire()
            try {
                val provisioned = core.create(pin, fullReentry)
                store.provision(PinProtectedSnapshot(scope, provisioned.encryptedRecord, provisioned.attempts))
            } finally { store.release() }
        } } catch (failure: Exception) { closed = true; core.close(); throw failure }
        finally { pin.fill(0); fullReentry.fill(0) }
    }
    fun execute(pin: ByteArray, completeCanonicalIntent: ByteArray): String = try { operation {
        if (completeCanonicalIntent.isEmpty() || completeCanonicalIntent.size > 1_000_000) throw PinLocalException(PinLocalFault.CONFIGURATION)
        val snapshot: PinProtectedSnapshot
        store.acquire()
        try { snapshot = store.readProtected() } finally { store.release() }
        if (snapshot.scope != scope) throw PinLocalException(PinLocalFault.STATE)
        if (snapshot.upgradeRequired) throw PinLocalException(PinLocalFault.UPGRADE_REQUIRED)
        when (capability.current()) {
            PinSystemVerdict.NO_SYSTEM_AUTH -> Unit
            PinSystemVerdict.BLOCKED -> throw PinLocalException(PinLocalFault.BLOCKED)
            PinSystemVerdict.SYSTEM_READY -> {
                store.acquire()
                try { store.markUpgradeRequired(scope) } finally { store.release() }
                throw PinLocalException(PinLocalFault.UPGRADE_REQUIRED)
            }
        }
        // Go自己Unlock/precharge/settle/lease/import，并复验保护上下文及云权限。
        // 不返回localVaultKey/72B材料/lease/授权bool给Kotlin或Dart。
        val result = core.execute(pin, completeCanonicalIntent, snapshot, store)
        if (closed) throw PinLocalException(PinLocalFault.CLOSED)
        result
    } } finally { pin.fill(0); completeCanonicalIntent.fill(0) }

    /** 未实现正确旧PIN+真正系统CryptoObject迁移，SYSTEM_READY时普通业务永久拒绝。 */
    fun forgetLocal() {
        if (!busy.compareAndSet(false, true)) { retireOwners(); throw PinLocalException(PinLocalFault.BUSY) }
        closed = true
        try {
            core.close()
            val owner = slotOwner ?: throw PinLocalException(PinLocalFault.CLOSED)
            owner.clear {
            // 原provider可能已因损坏永久关闭。明确本地清理只用固定slot，
            // 不读取/解包旧钥、不创建MAC key、不允许云删除。
            val cleanupStore = PinKeystoreStore(context, PinSlot(scope.namespace, scope.slot, scope.endpoint), retireOwners, slotOwner = slotOwner)
            cleanupStore.acquire()
            try { cleanupStore.deleteLocalPacket(); cleanup.clearProtectedWorkflowAndDevice() } finally { cleanupStore.release() }
            }
            retireOwners()
        } catch (_: Exception) { retireOwners(); throw PinLocalException(PinLocalFault.PERSISTENCE) }
        finally { busy.set(false) }
    }
    override fun close() { closed = true; retireOwners(); core.close() }
}
