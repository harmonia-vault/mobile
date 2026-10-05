package org.harmoniavault.harmonia_mobile.nativebridge.pinlocal

import android.content.Context
import org.harmoniavault.harmonia_mobile.nativebridge.NativeSlotOwner
import org.harmoniavault.harmonia_mobile.nativebridge.NativeSlotBusyException
import android.os.Process
import android.system.Os
import android.system.OsConstants
import android.util.AtomicFile
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files
import java.security.KeyStore
import java.security.MessageDigest

/** 原生固定 PIN slot；不接受 Dart 路径、alias、认证 bool 或材料。 */
internal class PinNativeSlot(
    private val context: Context,
    val configuration: PinSlot,
    private val retire: () -> Unit,
) : PinLocalCleanup {
    private val directory = File(context.noBackupFilesDir, "harmonia/app-pin")
    private val id = PinNativeStateCAS.slotID(context.packageName, configuration.namespace, configuration.slot)
    private val workflow = AtomicFile(File(directory, "$id.workflow-pin-v1.gcm"))
    private val businessLock = PinSlotFileLock(File(directory, "$id.operation.lock"))
    private var originalState: ByteArray? = null
    private var expectedStateHash: ByteArray? = null
    @Volatile private var active = false
    lateinit var owner: NativeSlotOwner
        private set

    init {
        configuration.validate()
        if (context.applicationInfo.uid != Process.myUid()) throw PinLocalException(PinLocalFault.CONFIGURATION)
    }

    fun retireOwners() {
        if (::owner.isInitialized) owner.retire()
        try { retire() } catch (_: Exception) { throw PinLocalException(PinLocalFault.PERSISTENCE) }
    }

    private fun pathsSafe() {
        for (path in listOf(File(context.noBackupFilesDir, "harmonia"), directory)) {
            if (Files.isSymbolicLink(path.toPath())) throw PinLocalException(PinLocalFault.PERSISTENCE)
        }
        for (suffix in listOf("", ".bak", ".new")) {
            if (Files.isSymbolicLink(File(workflow.baseFile.path + suffix).toPath())) throw PinLocalException(PinLocalFault.PERSISTENCE)
        }
    }

    fun acquireOperation() {
        owner = try { NativeSlotOwner.acquire(context, configuration.slot, pinNamespace = configuration.namespace) }
            catch (_: NativeSlotBusyException) { throw PinLocalException(PinLocalFault.BUSY) }
        try { pathsSafe()
        if (!(directory.exists() || directory.mkdirs()) || !directory.isDirectory) throw PinLocalException(PinLocalFault.PERSISTENCE)
        Os.chmod(directory.path, 0b111000000)
        NativeSlotOwner.syncDirectory(directory); NativeSlotOwner.syncDirectory(checkNotNull(directory.parentFile))
        try {
            businessLock.acquire()
            Os.chmod(File(directory, "$id.operation.lock").path, 0b110000000)
            active = true
        } catch (failure: Exception) {
            if (businessLock.valid()) try { businessLock.release() } catch (_: Exception) { }
            retireOwners()
            throw if (failure is PinLocalException) failure else PinLocalException(PinLocalFault.PERSISTENCE)
        }
        } catch (failure: Exception) { owner.close(); throw failure }
    }

    private fun requireOperation() {
        if (!active || !businessLock.valid()) throw PinLocalException(PinLocalFault.CLOSED)
        owner.read { pathsSafe() }
    }

    fun cancel() { active = false; retireOwners() }

    fun releaseOperation() {
        active = false
        originalState?.fill(0); originalState = null
        expectedStateHash?.fill(0); expectedStateHash = null
        var failed = false
        try { businessLock.release() } catch (_: Exception) { failed = true }
        try { owner.close() } catch (_: Exception) { failed = true }
        if (failed) { retireOwners(); throw PinLocalException(PinLocalFault.PERSISTENCE) }
    }

    fun requireNoSystemArtifacts() = owner.read {
        val root = File(context.noBackupFilesDir, "harmonia")
        val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (keys.containsAlias("harmonia/device-key-wrap/v1") || keys.containsAlias("harmonia/device-key-wrap/v1/setup-integrity/v1") ||
            listOf("device-keys-v1.gcm", "device-keys-v1.gcm.setup-v1.mac", configuration.slot).any { name -> listOf("", ".bak", ".new").any { File(root, name + it).exists() } }) {
            throw PinLocalException(PinLocalFault.STATE)
        }
    }

    /** 只在业务锁内检查新 slot，不读取/解包旧设备，也不能删原系统模式。 */
    fun requireFresh() {
        requireOperation()
        for (stem in listOf("$id.pin", "$id.workflow-pin-v1.gcm")) {
            for (suffix in listOf("", ".bak", ".new")) if (File(directory, stem + suffix).exists()) throw PinLocalException(PinLocalFault.STATE)
        }
        val alias = "harmonia/app-pin/integrity/v1/${Process.myUid()}/$id"
        val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (keys.containsAlias(alias)) throw PinLocalException(PinLocalFault.STATE)
    }

    private fun readState(): ByteArray {
        requireOperation()
        if (!workflow.baseFile.exists() && !File(workflow.baseFile.path + ".bak").exists()) {
            if (File(workflow.baseFile.path + ".new").exists()) throw PinLocalException(PinLocalFault.PERSISTENCE)
            return ByteArray(0)
        }
        return NativeSlotOwner.readAtomicBytes(workflow.baseFile, PinNativeStateCAS.MAX_STATE)?.also { PinNativeStateCAS.validate(it) } ?: ByteArray(0)
    }

    fun loadWorkflow(): ByteArray {
        val packet = readState()
        originalState?.fill(0)
        originalState = packet.copyOf()
        expectedStateHash?.fill(0)
        expectedStateHash = PinNativeStateCAS.hash(packet)
        return packet
    }

    fun saveWorkflow(packet: ByteArray) = owner.mutate {
        requireOperation(); PinNativeStateCAS.validate(packet)
        if (packet.isEmpty()) throw PinLocalException(PinLocalFault.STATE)
        val expected = expectedStateHash ?: throw PinLocalException(PinLocalFault.STATE)
        val current = readState()
        try { PinNativeStateCAS.match(expected, current) } finally { current.fill(0) }
        val output = workflow.startWrite()
        var publishing = false
        try {
            requireOperation()
            output.write(packet); Os.fchmod(output.fd, 0b110000000); output.fd.sync()
            requireOperation()
            publishing = true
            workflow.finishWrite(output); syncDirectory()
            val readback = readState()
            try {
                if (!readback.contentEquals(packet)) throw PinLocalException(PinLocalFault.PERSISTENCE)
            } finally { readback.fill(0) }
            expectedStateHash?.fill(0); expectedStateHash = PinNativeStateCAS.hash(packet)
        } catch (failure: Exception) {
            if (!publishing) workflow.failWrite(output)
            retireOwners()
            throw if (failure is PinLocalException) failure else PinLocalException(PinLocalFault.PERSISTENCE)
        }
    }

    private fun syncDirectory() {
        NativeSlotOwner.syncDirectory(directory)
    }

    override fun clearProtectedWorkflowAndDevice() = owner.mutate {
        requireOperation(); retire()
        workflow.delete(); syncDirectory()
        if (listOf("", ".bak", ".new").any { File(workflow.baseFile.path + it).exists() }) throw PinLocalException(PinLocalFault.PERSISTENCE)
        originalState?.fill(0); originalState = null
        expectedStateHash?.fill(0); expectedStateHash = null
    }

    /** 先退役 RAM，再由成熟 store 删除本 slot MAC alias/单包，最后删密封状态。 */
    fun clearAll() = owner.clear {
        requireOperation(); retire()
        val store = PinKeystoreStore(context, configuration, { retire() }, slotOwner = owner)
        store.acquire()
        try { store.deleteLocalPacket(); clearProtectedWorkflowAndDevice() } finally { store.release() }
    }
}

/** 纯比较助手的主机测试不构成 Android AtomicFile/Keystore 实证。 */
internal object PinNativeStateCAS {
    const val MAX_STATE = (8 shl 20) + 8192
    fun slotID(pkg: String, namespace: String, slot: String): String = hash((pkg + "\u0000" + namespace + "\u0000" + slot).toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it.toInt() and 255) }
    fun hash(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)
    fun validate(packet: ByteArray) {
        if (packet.isEmpty()) return
        if (packet.size !in 40..MAX_STATE || String(packet, 0, 8, Charsets.US_ASCII) != "HARMST02") throw PinLocalException(PinLocalFault.STATE)
    }
    fun match(expected: ByteArray, current: ByteArray) {
        if (expected.size != 32 || !MessageDigest.isEqual(expected, hash(current))) throw PinLocalException(PinLocalFault.PERSISTENCE)
    }
}
