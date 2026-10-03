package org.harmoniavault.harmonia_mobile.nativebridge

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.system.Os
import android.util.AtomicFile
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory

/** MAC只认证本机setup意图，不替代CryptoObject，不含软件设备材料/凭据/云信任。 */
internal class NativeDeviceSetupIntent(
    private val context: Context, private val workflowSlot: String,
    private val deviceFilename: String, private val baseAlias: String,
) {
    internal data class Record(val generation: String, val kind: String, val phase: String, val packetSHA256: String, val workflowSHA256: String)
    private val root = File(context.noBackupFilesDir, "harmonia")
    private val file = AtomicFile(File(root, deviceFilename + ".setup-v1.mac"))
    val metadataAlias = baseAlias + "/setup-integrity/v1"
    fun hasArtifacts(): Boolean = listOf("", ".bak", ".new").any { File(file.baseFile.path + it).exists() } || keys().containsAlias(metadataAlias)
    private fun keys() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private fun key(create: Boolean): SecretKey {
        var key = keys().getKey(metadataAlias, null) as? SecretKey
        if (key == null && create) {
            check(!keys().containsAlias(metadataAlias))
            key = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_HMAC_SHA256, "AndroidKeyStore").run {
                init(KeyGenParameterSpec.Builder(metadataAlias, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                    .setKeySize(256).setDigests(KeyProperties.DIGEST_SHA256).setUserAuthenticationRequired(false).build())
                generateKey()
            }
        }
        check(key != null)
        val info = SecretKeyFactory.getInstance(key.algorithm, "AndroidKeyStore").getKeySpec(key, KeyInfo::class.java) as KeyInfo
        check(info.origin == KeyProperties.ORIGIN_GENERATED && !info.isUserAuthenticationRequired && info.keySize == 256 &&
            info.purposes == (KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY) && info.digests.toSet() == setOf(KeyProperties.DIGEST_SHA256) && key.encoded == null)
        return key
    }
    private fun mac(body: ByteArray, create: Boolean = false) = Mac.getInstance("HmacSHA256").run { init(key(create)); doFinal(body) }
    private fun encode(r: Record): ByteArray {
        val o = ByteArrayOutputStream()
        DataOutputStream(o).use { d ->
            d.write("HARMDC01".toByteArray(Charsets.US_ASCII))
            for (field in listOf(context.packageName, workflowSlot, deviceFilename, baseAlias, r.generation, r.kind, r.phase, r.packetSHA256, r.workflowSHA256)) {
                val b = field.toByteArray(Charsets.UTF_8); check(b.size <= 512); d.writeInt(b.size); d.write(b)
            }
        }
        return o.toByteArray()
    }
    private fun decode(body: ByteArray): Record {
        val d = DataInputStream(ByteArrayInputStream(body))
        check(ByteArray(8).also { d.readFully(it) }.contentEquals("HARMDC01".toByteArray(Charsets.US_ASCII)))
        val parts = (0..8).map { val n = d.readInt(); check(n in 0..512 && n <= d.available()); val b = ByteArray(n).also { d.readFully(it) }; b.toString(Charsets.UTF_8).also { check(it.toByteArray().contentEquals(b)) } }
        check(d.available() == 0 && parts.take(4) == listOf(context.packageName, workflowSlot, deviceFilename, baseAlias))
        val r = Record(parts[4], parts[5], parts[6], parts[7], parts[8])
        check(r.generation.matches(Regex("[a-f0-9]{32}")) && r.kind in setOf("generation", "legacy") && r.phase in setOf("prepared", "ready", "retiring"))
        for (hash in listOf(r.packetSHA256, r.workflowSHA256)) check(hash.isEmpty() || hash.matches(Regex("[a-f0-9]{64}")))
        check(r.kind != "legacy" || r.phase == "retiring")
        check(r.phase != "prepared" || (r.packetSHA256.isEmpty() && r.workflowSHA256.isEmpty()))
        check(r.phase != "ready" || (r.packetSHA256.isNotEmpty() && r.workflowSHA256.isEmpty()))
        return r
    }
    fun read(): Record? {
        val packet = NativeSlotOwner.readAtomicBytes(file.baseFile, 4096) ?: return null
        check(packet.size in 80..4096)
        val body = packet.copyOfRange(0, packet.size - 32)
        check(MessageDigest.isEqual(mac(body), packet.copyOfRange(packet.size - 32, packet.size)))
        return decode(body)
    }
    fun referenceAlias(): String? = read()?.let { wrappingAlias(it) }
    private fun wrappingAlias(r: Record) = if (r.kind == "legacy") baseAlias else baseAlias + "/setup/" + r.generation
    private fun write(r: Record) {
        val body = encode(r); val packet = body + mac(body, create = true)
        val output = file.startWrite()
        var publishing = false
        try {
            output.write(packet); Os.fchmod(output.fd, 384); output.fd.sync(); publishing = true
            file.finishWrite(output)
            NativeSlotOwner.syncDirectory(root)
            check(read() == r) { "setup intent readback unconfirmed" }
        } catch (failure: Exception) { if (!publishing) file.failWrite(output); throw failure }
    }
    private fun digest(packet: ByteArray) = MessageDigest.getInstance("SHA-256").digest(packet).joinToString("") { "%02x".format(it.toInt() and 255) }
    private fun stateDigest(name: String) = NativeSlotOwner.readAtomicBytes(File(root, name), (8 shl 20) + 8192)?.let { digest(it) } ?: ""
    private fun matchesRemaining(name: String, expected: String) {
        // 部分删除只能减少原精确对象；.new或不同包不能作为同意图接管。
        check(!File(root, name + ".new").exists())
        for (suffix in listOf("", ".bak")) {
            val path = File(root, name + suffix)
            if (path.exists()) {
                val p = NativeSlotOwner.readFixedBytes(path, (8 shl 20) + 8192)
                check(expected.isNotEmpty() && digest(p) == expected) { "cleanup identity conflict" }
            }
        }
    }
    private fun removeAlias(alias: String) { val ks = keys(); if (ks.containsAlias(alias)) ks.deleteEntry(alias); check(!ks.containsAlias(alias)) }
    private fun removeLocator() { file.delete(); NativeSlotOwner.syncDirectory(root); check(listOf("", ".bak", ".new").none { File(file.baseFile.path + it).exists() }); removeAlias(metadataAlias) }
    private fun resumeCleanupRaw(r: Record) {
        check(r.phase == "retiring")
        matchesRemaining(deviceFilename, r.packetSHA256); matchesRemaining(workflowSlot, r.workflowSHA256)
        removeAlias(wrappingAlias(r))
        for (name in listOf(deviceFilename, workflowSlot)) AtomicFile(File(root, name)).delete()
        NativeSlotOwner.syncDirectory(root)
        matchesRemaining(deviceFilename, ""); matchesRemaining(workflowSlot, "")
        removeLocator()
    }
    fun prepareNew(owner: NativeSlotOwner): String = owner.mutate {
        val pinID = MessageDigest.getInstance("SHA-256").digest((context.packageName + "\u0000harmonia/mobile/app-pin/v1\u0000" + workflowSlot).toByteArray()).joinToString("") { "%02x".format(it.toInt() and 255) }
        val pinRoot = File(root, "app-pin")
        check(!keys().containsAlias("harmonia/app-pin/integrity/v1/${context.applicationInfo.uid}/$pinID"))
        check(listOf("$pinID.pin", "$pinID.workflow-pin-v1.gcm").none { stem -> listOf("", ".bak", ".new").any { File(pinRoot, stem + it).exists() } })
        var current = read()
        if (current?.phase == "retiring") { resumeCleanupRaw(current); current = null }
        if (current != null) {
            check(current.phase == "prepared" && stateDigest(deviceFilename).isEmpty() && stateDigest(workflowSlot).isEmpty())
            matchesRemaining(deviceFilename, ""); matchesRemaining(workflowSlot, "")
            write(current.copy(phase = "retiring")); resumeCleanupRaw(current.copy(phase = "retiring")); current = null
        }
        check(stateDigest(deviceFilename).isEmpty() && stateDigest(workflowSlot).isEmpty() && !keys().containsAlias(baseAlias))
        matchesRemaining(deviceFilename, ""); matchesRemaining(workflowSlot, "")
        // metadata orphan可严格验证后复用；从不扫描/认领未知wrapping aliases。
        if (keys().containsAlias(metadataAlias)) key(false)
        val generation = ByteArray(16).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it.toInt() and 255) }
        val record = Record(generation, "generation", "prepared", "", "")
        check(!keys().containsAlias(wrappingAlias(record)))
        write(record); wrappingAlias(record)
    }
    fun aliasForOpening(packet: ByteArray): String {
        val r = read() ?: return baseAlias // 只读兼容旧格式；旧alias不能用于新create。
        check(r.phase != "retiring")
        if (r.phase == "ready") check(r.packetSHA256 == digest(packet))
        return wrappingAlias(r)
    }
    fun bindMaterial(owner: NativeSlotOwner, packet: ByteArray) = owner.mutate {
        val r = read() ?: return@mutate // 已认证旧格式不自动迁移/授新authority。
        check(r.phase != "retiring" && r.kind == "generation")
        val hash = digest(packet)
        check(r.packetSHA256.isEmpty() || r.packetSHA256 == hash)
        if (r.phase != "ready") write(r.copy(phase = "ready", packetSHA256 = hash))
    }
    fun cancelPrepared(owner: NativeSlotOwner) = owner.clear {
        val r = read() ?: error("setup intent absent")
        check(r.kind == "generation" && r.phase == "prepared" && stateDigest(deviceFilename).isEmpty() && stateDigest(workflowSlot).isEmpty())
        matchesRemaining(deviceFilename, ""); matchesRemaining(workflowSlot, "")
        write(r.copy(phase = "retiring")); resumeCleanupRaw(r.copy(phase = "retiring"))
    }
    fun beginDeletion(owner: NativeSlotOwner) = owner.mutate {
        val device = stateDigest(deviceFilename); val state = stateDigest(workflowSlot)
        check(device.isNotEmpty())
        val current = read()
        val r = (current ?: Record(ByteArray(16).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it.toInt() and 255) }, "legacy", "retiring", "", ""))
            .copy(phase = "retiring", packetSHA256 = device, workflowSHA256 = state)
        write(r); removeAlias(wrappingAlias(r))
    }
    fun finishDeletion(owner: NativeSlotOwner) = owner.mutate {
        val r = read() ?: error("cleanup intent absent")
        resumeCleanupRaw(r)
    }
}
