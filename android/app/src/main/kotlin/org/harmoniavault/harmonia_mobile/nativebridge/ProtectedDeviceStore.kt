package org.harmoniavault.harmonia_mobile.nativebridge

import android.app.KeyguardManager
import android.content.Context
import android.hardware.biometrics.BiometricManager
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.system.Os
import android.util.AtomicFile
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec

/** 仅保存 AES-GCM 密文。Ed25519/X25519 是软件钥匙，不宣称始终硬件内。 */
internal class ProtectedDeviceStore(
    private val context: Context,
    private val alias: String = "harmonia/device-key-wrap/v1",
    private val filename: String = "device-keys-v1.gcm",
    private val workflowSlot: String = "workflow-state-v1.gcm",
) {
    companion object {
        const val AUTHENTICATORS = BiometricManager.Authenticators.BIOMETRIC_STRONG or
            BiometricManager.Authenticators.DEVICE_CREDENTIAL
        private val HEADER = "HARMAES1".toByteArray(Charsets.US_ASCII)
        private const val MATERIAL_BYTES = 72
        private const val IV_BYTES = 12
        private const val SEALED_BYTES = MATERIAL_BYTES + 16
        private const val FILE_BYTES = 8 + IV_BYTES + SEALED_BYTES
    }

    private val setup = NativeDeviceSetupIntent(context, workflowSlot, filename, alias)
    private val directory = File(context.noBackupFilesDir, "harmonia")
    private val atomicFile = AtomicFile(File(directory, filename))
    private val aad = (context.packageName + "\u0000harmonia/device-material/v1\u0000" + filename)
        .toByteArray(Charsets.UTF_8)

    fun supported(): Boolean {
        if (Build.VERSION.SDK_INT < 30) return false
        val keyguard = context.getSystemService(KeyguardManager::class.java)
        val biometric = context.getSystemService(BiometricManager::class.java)
        return keyguard.isDeviceSecure &&
            biometric.canAuthenticate(AUTHENTICATORS) == BiometricManager.BIOMETRIC_SUCCESS
    }

    fun exists(): Boolean = atomicFile.baseFile.exists() || File(atomicFile.baseFile.path + ".bak").exists()

    /** 残留alias/.new也属于既有系统mode，不能为PIN setup当作不存在。 */
    fun hasArtifacts(): Boolean {
        val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        return exists() || File(atomicFile.baseFile.path + ".new").exists() || keys.containsAlias(alias) || setup.hasArtifacts()
    }

    private fun requireSupported() {
        check(supported()) { "system strong authentication unavailable" }
    }

    private fun loadKey(create: Boolean, selectedAlias: String): SecretKey {
        requireSupported()
        val keystore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        var key = keystore.getKey(selectedAlias, null) as? SecretKey
        if (create) {
            check(key == null && !keystore.containsAlias(selectedAlias)) { "unknown wrapping alias exists" }
            val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            generator.init(
                KeyGenParameterSpec.Builder(selectedAlias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setKeySize(256)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setRandomizedEncryptionRequired(true)
                    .setUserAuthenticationRequired(true)
                    .setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL)
                    .build(),
            )
            key = generator.generateKey()
        }
        check(key != null) { "protected device wrapping key unavailable" }
        val info = SecretKeyFactory.getInstance(key.algorithm, "AndroidKeyStore")
            .getKeySpec(key, KeyInfo::class.java) as KeyInfo
        // 不接受同名无认证 key，也不降级到弱生物、明文或普通软件 AES。
        // KeyInfo 旧约定每次认证返回-1；本机Android14/API34返回0。两者均无时间授权窗口。
        check(info.isUserAuthenticationRequired && info.userAuthenticationValidityDurationSeconds in -1..0 &&
            info.userAuthenticationType == (KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL) &&
            info.keySize == 256) { "protected key policy mismatch" }
        return key
    }

    internal fun withWorkflowSlot(slot: String) = ProtectedDeviceStore(context, alias, filename, slot)
    internal val nativeFilename get() = filename
    internal val nativeAlias get() = alias
    private fun requireOwner(owner: NativeSlotOwner?) = owner ?: error("captured slot owner required")

    fun prepareCreate(owner: NativeSlotOwner? = null): Cipher = requireOwner(owner).mutate {
        requireSupported()
        val selectedAlias = setup.prepareNew(requireOwner(owner))
        Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.ENCRYPT_MODE, loadKey(create = true, selectedAlias = selectedAlias))
        }
    }

    data class Opening(val cipher: Cipher, val ciphertext: ByteArray)

    fun prepareOpen(owner: NativeSlotOwner? = null): Opening = requireOwner(owner).read {
        requireSupported()
        val bytes = NativeSlotOwner.readAtomicBytes(atomicFile.baseFile, FILE_BYTES) ?: error("device material absent")
        check(bytes.size == FILE_BYTES)
        check(bytes.copyOfRange(0, HEADER.size).contentEquals(HEADER)) { "invalid protected device file version" }
        val iv = bytes.copyOfRange(HEADER.size, HEADER.size + IV_BYTES)
        val ciphertext = bytes.copyOfRange(HEADER.size + IV_BYTES, bytes.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.DECRYPT_MODE, loadKey(create = false, selectedAlias = setup.aliasForOpening(bytes)), GCMParameterSpec(128, iv))
        }
        Opening(cipher, ciphertext)
    }

    fun openAuthenticated(cipher: Cipher, ciphertext: ByteArray, owner: NativeSlotOwner? = null): ByteArray = requireOwner(owner).read {
        cipher.updateAAD(aad)
        val material = cipher.doFinal(ciphertext)
        check(material.size == MATERIAL_BYTES) { "invalid device material size" }
        material
    }

    /** cipher 必须来自成功认证的同一个 CryptoObject；调用方不得提供明文持久化接口。 */
    fun saveAuthenticated(cipher: Cipher, material: ByteArray, owner: NativeSlotOwner? = null) = requireOwner(owner).mutate {
        check(material.size == MATERIAL_BYTES && !exists()) { "invalid device creation state" }
        // 每次认证 key 的 AAD 也属于受保护 operation，必须在认证成功后送入。
        cipher.updateAAD(aad)
        val ciphertext = cipher.doFinal(material) // 未认证时 Keystore 必须拒绝。
        check(cipher.iv.size == IV_BYTES && ciphertext.size == SEALED_BYTES) { "invalid wrapping output" }
        check(directory.exists() || directory.mkdirs()) { "protected directory unavailable" }
        Os.chmod(directory.path, 0b111000000)
        val output = atomicFile.startWrite()
        var publishing = false
        try {
            output.write(HEADER)
            output.write(cipher.iv)
            output.write(ciphertext)
            Os.fchmod(output.fd, 0b110000000)
            output.fd.sync()
            publishing = true
            atomicFile.finishWrite(output)
            NativeSlotOwner.syncDirectory(directory)
            val readback = NativeSlotOwner.readAtomicBytes(atomicFile.baseFile, FILE_BYTES) ?: error("device readback absent")
            try { check(readback.contentEquals(HEADER + cipher.iv + ciphertext)) }
            finally { readback.fill(0) }
            setup.bindMaterial(requireOwner(owner), HEADER + cipher.iv + ciphertext)
        } catch (failure: Exception) {
            if (!publishing) atomicFile.failWrite(output)
            throw failure
        }
    }
    fun delete(owner: NativeSlotOwner? = null) = requireOwner(owner).mutate {
        // 先发布精确删除意图，再销毁本locator所指包封key；中断不能认领新identity。
        setup.beginDeletion(requireOwner(owner))
        atomicFile.delete()
        NativeSlotOwner.syncDirectory(directory)
        check(!exists() &&
            !File(atomicFile.baseFile.path + ".new").exists())
    }

    fun confirmImportedMaterial(owner: NativeSlotOwner) {
        val packet = owner.read { NativeSlotOwner.readAtomicBytes(atomicFile.baseFile, FILE_BYTES) ?: error("device packet absent") }
        try { setup.bindMaterial(owner, packet) } finally { packet.fill(0) }
    }
    fun cancelPreparedCreate(owner: NativeSlotOwner) = setup.cancelPrepared(owner)
    fun finishDeletion(owner: NativeSlotOwner) = setup.finishDeletion(owner)

}
