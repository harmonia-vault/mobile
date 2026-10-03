package org.harmoniavault.harmonia_mobile.nativebridge.pinlocal

import android.content.Context
import android.os.Process
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.system.Os
import android.system.OsConstants
import android.util.AtomicFile
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.RandomAccessFile
import java.net.URI
import java.nio.channels.FileLock
import java.nio.channels.OverlappingFileLockException
import java.nio.file.Files
import java.security.KeyStore
import java.security.MessageDigest
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory

internal enum class PinLocalFault { BUSY, BLOCKED, UPGRADE_REQUIRED, CONFIGURATION, STATE, PERSISTENCE, AUTHENTICATION, CLOSED }
internal class PinLocalException(val fault: PinLocalFault) : Exception(fault.name)
private fun reject(test: Boolean, fault: PinLocalFault = PinLocalFault.STATE) { if (!test) throw PinLocalException(fault) }
private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it.toInt() and 255) }
private fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes)
private fun lowerHex(value: String, length: Int) = value.length == length && value.all { it in '0'..'9' || it in 'a'..'f' }

/** native 固定 slot 配置。endpoint 变更必须另走本地退出/新身份，不能移用旧钥。 */
internal data class PinSlot(val namespace: String, val slot: String, val endpoint: String) {
    fun validate() {
        reject(namespace.isNotEmpty() && namespace.toByteArray().size <= 512 && !namespace.contains('\r') && !namespace.contains('\n'), PinLocalFault.CONFIGURATION)
        reject(slot.matches(Regex("[A-Za-z0-9][A-Za-z0-9._:-]{0,127}")), PinLocalFault.CONFIGURATION)
        val u = try { URI(endpoint) } catch (_: Exception) { throw PinLocalException(PinLocalFault.CONFIGURATION) }
        reject(endpoint.length <= 2048 && u.scheme == "https" && !u.host.isNullOrEmpty() && u.rawUserInfo == null && u.rawQuery == null && u.rawFragment == null && !endpoint.endsWith('/') && !endpoint.contains('\\') && u.host == u.host.lowercase() && u.toASCIIString() == endpoint, PinLocalFault.CONFIGURATION)
    }
    fun matches(scope: PinScope) = scope.namespace == namespace && scope.slot == slot && scope.endpoint == endpoint
}

internal data class PinScope(
    val packageName: String, val namespace: String, val slot: String, val endpoint: String,
    val mode: String, val authGeneration: String, val keyEpoch: String,
    val signingPublicKey: String, val receivingPublicKey: String,
) {
    fun validate() {
        PinSlot(namespace, slot, endpoint).validate()
        reject(packageName.length <= 256 && packageName.matches(Regex("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+")))
        reject(mode == "pin" && lowerHex(authGeneration, 32) && lowerHex(keyEpoch, 32) && authGeneration != keyEpoch)
        for (pub in listOf(signingPublicKey, receivingPublicKey)) {
            val decoded = try { Base64.getUrlDecoder().decode(pub) } catch (_: Exception) { throw PinLocalException(PinLocalFault.STATE) }
            reject(decoded.size == 32 && Base64.getUrlEncoder().withoutPadding().encodeToString(decoded) == pub)
        }
    }
}

/** Go uint64 大于 Long.MAX_VALUE 必须在私有 wrapper 拒绝，不能截断或转浮点。 */
internal data class PinAttemptState(
    val revision: Long, val recordHash: String, val total: Long, val failures: Long,
    val pendingAttempt: String, val delaySeconds: Int,
) {
    fun validate(record: ByteArray) {
        reject(revision > 0 && total >= 0 && failures in 0..total && recordHash == hex(digest(record)))
        reject(pendingAttempt.isEmpty() || (lowerHex(pendingAttempt, 64) && failures > 0))
        val expected = if (failures < 5) 0 else if (failures >= 10) 600 else minOf(600, 30 shl (failures.toInt() - 5))
        reject(delaySeconds == expected)
    }
}

internal data class PinProtectedSnapshot(val scope: PinScope, val record: ByteArray, val attempts: PinAttemptState, val upgradeRequired: Boolean = false)
internal interface PinDurableStore {
    fun acquire()
    fun release()
    fun load(): PinAttemptState
    fun commit(expectedRevision: Long, next: PinAttemptState)
}

/** 编码器不提供认证。生产必须验证 AndroidKeyStore MAC 后才解码。 */
internal object PinPacketCodec {
    const val MAX_PACKET = 24_576
    private val header = "HARMPN01".toByteArray(Charsets.US_ASCII)
    private fun DataOutputStream.part(value: ByteArray) { writeInt(value.size); write(value) }
    private fun DataInputStream.part(max: Int): ByteArray {
        val n = readInt(); reject(n in 1..max && n <= available())
        return ByteArray(n).also { readFully(it) }
    }
    fun encode(snapshot: PinProtectedSnapshot): ByteArray {
        snapshot.scope.validate(); reject(snapshot.record.size in 1..8192); snapshot.attempts.validate(snapshot.record)
        val output = ByteArrayOutputStream()
        DataOutputStream(output).use { o ->
            o.write(header); o.writeByte(if (snapshot.upgradeRequired) 1 else 0)
            val s = snapshot.scope
            for (v in listOf(s.packageName, s.namespace, s.slot, s.endpoint, s.mode, s.authGeneration, s.keyEpoch, s.signingPublicKey, s.receivingPublicKey)) o.part(v.toByteArray(Charsets.UTF_8))
            o.part(snapshot.record)
            val a = snapshot.attempts
            o.writeLong(a.revision); o.part(a.recordHash.toByteArray(Charsets.US_ASCII)); o.writeLong(a.total); o.writeLong(a.failures)
            o.writeInt(a.pendingAttempt.length); o.write(a.pendingAttempt.toByteArray(Charsets.US_ASCII)); o.writeInt(a.delaySeconds)
        }
        return output.toByteArray().also { reject(it.size + 32 <= MAX_PACKET) }
    }
    fun seal(snapshot: PinProtectedSnapshot, computeMac: (ByteArray) -> ByteArray): ByteArray {
        val body = encode(snapshot); val tag = computeMac(body)
        reject(tag.size == 32)
        return body + tag
    }
    fun open(packet: ByteArray, computeMac: (ByteArray) -> ByteArray): PinProtectedSnapshot {
        reject(packet.size in 40..MAX_PACKET)
        val body = packet.copyOfRange(0, packet.size - 32)
        val expected = computeMac(body)
        reject(expected.size == 32 && MessageDigest.isEqual(expected, packet.copyOfRange(packet.size - 32, packet.size)))
        return decode(body)
    }
    fun decode(body: ByteArray): PinProtectedSnapshot = try {
        reject(body.size in 8..MAX_PACKET - 32)
        val input = DataInputStream(ByteArrayInputStream(body))
        reject(ByteArray(8).also { input.readFully(it) }.contentEquals(header))
        val latch = input.readUnsignedByte(); reject(latch in 0..1)
        val max = listOf(256, 512, 128, 2048, 3, 32, 32, 64, 64)
        val values = max.map { bound ->
            val b = input.part(bound)
            val text = b.toString(Charsets.UTF_8)
            reject(text.toByteArray(Charsets.UTF_8).contentEquals(b)); text
        }
        val scope = PinScope(values[0], values[1], values[2], values[3], values[4], values[5], values[6], values[7], values[8])
        val record = input.part(8192)
        val revision = input.readLong(); val hash = input.part(64).toString(Charsets.US_ASCII)
        val total = input.readLong(); val failures = input.readLong()
        val pendingSize = input.readInt(); reject(pendingSize == 0 || pendingSize == 64)
        val pending = ByteArray(pendingSize).also { input.readFully(it) }.toString(Charsets.US_ASCII)
        val state = PinAttemptState(revision, hash, total, failures, pending, input.readInt())
        reject(input.available() == 0); scope.validate(); state.validate(record)
        PinProtectedSnapshot(scope, record, state, latch == 1)
    } catch (e: PinLocalException) { throw e } catch (_: Exception) { throw PinLocalException(PinLocalFault.STATE) }
}

/** 锁不要求回调位于同一个 JVM thread，兼容 Go 调度后的 JNI 回调。 */
internal class PinSlotFileLock(private val file: File) {
    companion object { private val inProcess = ConcurrentHashMap<String, AtomicBoolean>() }
    private val busy = inProcess.computeIfAbsent(file.absolutePath) { AtomicBoolean() }
    private var handle: RandomAccessFile? = null
    private var held: FileLock? = null
    @Synchronized fun acquire() {
        if (!busy.compareAndSet(false, true)) throw PinLocalException(PinLocalFault.BUSY)
        var opened: RandomAccessFile? = null
        try {
            reject(!Files.isSymbolicLink(file.toPath()), PinLocalFault.PERSISTENCE)
            opened = RandomAccessFile(file, "rw")
            val lock = try { opened.channel.tryLock() } catch (_: OverlappingFileLockException) { null }
            if (lock == null) throw PinLocalException(PinLocalFault.BUSY)
            handle = opened; held = lock
        } catch (failure: Exception) {
            try { opened?.close() } finally { busy.set(false) }
            if (failure is PinLocalException) throw failure
            throw PinLocalException(PinLocalFault.PERSISTENCE)
        }
    }
    @Synchronized fun valid() = held?.isValid == true
    @Synchronized fun release() {
        reject(held != null && handle != null, PinLocalFault.PERSISTENCE)
        var failed = false
        try { held?.release() } catch (_: Exception) { failed = true }
        try { handle?.close() } catch (_: Exception) { failed = true }
        held = null; handle = null; busy.set(false)
        reject(!failed, PinLocalFault.PERSISTENCE)
    }
}

/** 单一 MAC 原子包包含 encryptedRecord+limiter；缺任一材料不初始化预算。 */
internal class PinKeystoreStore(
    private val context: Context,
    private val slot: PinSlot,
    private val retireOwner: () -> Unit,
    private val beforeWrite: () -> Unit = {},
    private val beforeAliasRetirement: () -> Unit = {},
) : PinDurableStore {
    private val directory = File(context.noBackupFilesDir, "harmonia/app-pin")
    private val slotID: String
    private val alias: String
    private val atomic: AtomicFile
    private val lock: PinSlotFileLock
    @Volatile private var fixedScope: PinScope? = null
    @Volatile private var closed = false
    @Volatile private var upgradeLatched = false
    init {
        slot.validate(); reject(Process.myUid() >= 0 && context.applicationInfo.uid == Process.myUid(), PinLocalFault.CONFIGURATION)
        slotID = hex(digest((context.packageName + "\u0000" + slot.namespace + "\u0000" + slot.slot).toByteArray(Charsets.UTF_8)))
        alias = "harmonia/app-pin/integrity/v1/${Process.myUid()}/$slotID"
        atomic = AtomicFile(File(directory, "$slotID.pin"))
        lock = PinSlotFileLock(File(directory, "$slotID.lock"))
    }
    private fun requireHeld() { reject(!closed && lock.valid(), PinLocalFault.PERSISTENCE) }
    private fun safePaths() {
        reject(!Files.isSymbolicLink(File(context.noBackupFilesDir, "harmonia").toPath()) && !Files.isSymbolicLink(directory.toPath()), PinLocalFault.PERSISTENCE)
        for (suffix in listOf("", ".bak", ".new")) reject(!Files.isSymbolicLink(File(atomic.baseFile.path + suffix).toPath()), PinLocalFault.PERSISTENCE)
    }
    private inline fun <T> guard(block: () -> T): T = try { block() } catch (failure: Exception) {
        if (failure !is PinLocalException || failure.fault !in listOf(PinLocalFault.BUSY, PinLocalFault.AUTHENTICATION)) closed = true
        retireOwner()
        if (failure is PinLocalException) throw failure
        throw PinLocalException(PinLocalFault.PERSISTENCE)
    }
    private fun key(create: Boolean): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        var key = ks.getKey(alias, null) as? SecretKey
        if (create) {
            reject(key == null && !ks.containsAlias(alias), PinLocalFault.STATE)
            key = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_HMAC_SHA256, "AndroidKeyStore").run {
                init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                    .setKeySize(256).setDigests(KeyProperties.DIGEST_SHA256).setUserAuthenticationRequired(false).build())
                generateKey()
            }
        }
        reject(key != null, PinLocalFault.PERSISTENCE)
        val info = SecretKeyFactory.getInstance(key!!.algorithm, "AndroidKeyStore").getKeySpec(key, KeyInfo::class.java) as KeyInfo
        reject(!info.isUserAuthenticationRequired && info.keySize == 256 && info.purposes == (KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY) && info.digests.toSet() == setOf(KeyProperties.DIGEST_SHA256) && info.origin == KeyProperties.ORIGIN_GENERATED && key.encoded == null, PinLocalFault.PERSISTENCE)
        return key
    }
    private fun mac(body: ByteArray, create: Boolean = false): ByteArray = Mac.getInstance("HmacSHA256").run { init(key(create)); doFinal(body) }
    private fun directorySync() {
        val fd = Os.open(directory.path, OsConstants.O_RDONLY, 0)
        try { Os.fsync(fd) } finally { Os.close(fd) }
    }
    override fun acquire() = guard {
        reject(!closed, PinLocalFault.CLOSED)
        reject(directory.exists() || directory.mkdirs(), PinLocalFault.PERSISTENCE)
        reject(directory.isDirectory, PinLocalFault.PERSISTENCE)
        safePaths(); Os.chmod(directory.path, 0b111000000)
        lock.acquire()
        try { Os.chmod(File(directory, "$slotID.lock").path, 0b110000000) } catch (failure: Exception) { lock.release(); throw failure }
    }
    override fun release() = guard { lock.release() }
    private fun readPacket(): ByteArray {
        requireHeld(); safePaths()
        return atomic.openRead().use { input ->
            val output = ByteArrayOutputStream(); val buffer = ByteArray(4096)
            while (output.size() <= PinPacketCodec.MAX_PACKET) {
                val count = input.read(buffer, 0, minOf(buffer.size, PinPacketCodec.MAX_PACKET + 1 - output.size()))
                if (count < 0) break
                output.write(buffer, 0, count)
            }
            output.toByteArray().also { reject(it.size in 40..PinPacketCodec.MAX_PACKET) }
        }
    }
    fun readProtected(): PinProtectedSnapshot = guard {
        val snapshot = PinPacketCodec.open(readPacket()) { body -> mac(body) }
        reject(snapshot.scope.packageName == context.packageName && slot.matches(snapshot.scope))
        reject(fixedScope == null || fixedScope == snapshot.scope)
        reject(!upgradeLatched || snapshot.upgradeRequired)
        fixedScope = snapshot.scope
        upgradeLatched = upgradeLatched || snapshot.upgradeRequired
        snapshot
    }
    override fun load(): PinAttemptState {
        val snapshot = readProtected()
        if (snapshot.upgradeRequired) { retireOwner(); throw PinLocalException(PinLocalFault.UPGRADE_REQUIRED) }
        return snapshot.attempts
    }
    private fun write(snapshot: PinProtectedSnapshot, createKey: Boolean = false) {
        requireHeld(); safePaths(); beforeWrite()
        val packet = PinPacketCodec.seal(snapshot) { body -> mac(body, createKey) }
        val output = atomic.startWrite()
        try {
            output.write(packet); Os.fchmod(output.fd, 0b110000000); output.fd.sync()
            atomic.finishWrite(output); directorySync()
            reject(readPacket().contentEquals(packet), PinLocalFault.PERSISTENCE)
            val readback = readProtected()
            reject(readback.scope == snapshot.scope && readback.record.contentEquals(snapshot.record) && readback.attempts == snapshot.attempts && readback.upgradeRequired == snapshot.upgradeRequired, PinLocalFault.PERSISTENCE)
        } catch (failure: Exception) { atomic.failWrite(output); throw failure }
    }
    fun provision(snapshot: PinProtectedSnapshot) = guard {
        requireHeld()
        reject(!atomic.baseFile.exists() && !File(atomic.baseFile.path + ".bak").exists() && !File(atomic.baseFile.path + ".new").exists())
        reject(snapshot.scope.packageName == context.packageName && slot.matches(snapshot.scope))
        reject(!snapshot.upgradeRequired)
        reject(snapshot.attempts.revision == 1L && snapshot.attempts.total == 0L && snapshot.attempts.failures == 0L && snapshot.attempts.pendingAttempt.isEmpty())
        fixedScope = snapshot.scope
        write(snapshot, createKey = true)
    }
    override fun commit(expectedRevision: Long, next: PinAttemptState) = guard {
        val current = readProtected(); val old = current.attempts
        reject(!current.upgradeRequired)
        reject(expectedRevision == old.revision && old.revision < Long.MAX_VALUE && next.revision == old.revision + 1)
        next.validate(current.record)
        val charge = old.total < Long.MAX_VALUE && old.failures < Long.MAX_VALUE && next.total == old.total + 1 && next.failures == old.failures + 1 && next.pendingAttempt.isNotEmpty() && next.pendingAttempt != old.pendingAttempt
        val settle = old.pendingAttempt.isNotEmpty() && next.total == old.total && next.failures == 0L && next.pendingAttempt.isEmpty() && next.delaySeconds == 0
        reject(charge || settle)
        write(current.copy(attempts = next))
    }
    private fun retireIntegrityAlias() {
        beforeAliasRetirement()
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (ks.containsAlias(alias)) ks.deleteEntry(alias)
        reject(!ks.containsAlias(alias), PinLocalFault.PERSISTENCE)
    }
    fun markUpgradeRequired(expected: PinScope) {
        var publishing = false
        try { guard {
            val snapshot = readProtected()
            reject(snapshot.scope == expected)
            if (!snapshot.upgradeRequired) {
                publishing = true
                write(snapshot.copy(upgradeRequired = true))
            }
            upgradeLatched = true
        } } catch (failure: Exception) {
            if (publishing) {
                // 同一原slot锁内退役该完整性alias。旧false包不能在重启后
                // 又被正常App验证；若Keystore也失败，仅报持久化失败。
                closed = true; retireOwner()
                try { retireIntegrityAlias() } catch (_: Exception) { throw PinLocalException(PinLocalFault.PERSISTENCE) }
                throw PinLocalException(PinLocalFault.PERSISTENCE)
            }
            throw failure
        }
    }
    /** 先令正常App无法验证旧包，再删除本slot；不是对离线副本的可撤回保证。 */
    fun deleteLocalPacket() = guard {
        requireHeld(); retireOwner()
        retireIntegrityAlias()
        atomic.delete(); directorySync()
        reject(listOf("", ".bak", ".new").none { File(atomic.baseFile.path + it).exists() }, PinLocalFault.PERSISTENCE)
        fixedScope = null; closed = true
    }
}
