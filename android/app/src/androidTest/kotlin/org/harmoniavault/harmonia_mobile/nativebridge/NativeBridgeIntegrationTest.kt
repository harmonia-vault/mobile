package org.harmoniavault.harmonia_mobile.nativebridge

import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Test
import org.junit.Assert.*
import org.harmoniavault.go.mobilebridge.Mobilebridge
import org.json.JSONObject
import java.io.File
import java.security.KeyStore

/** Android 原生业务/密码学/系统权限测试；不创建或测试 Flutter UI。全为新合成资料。 */
class NativeBridgeIntegrationTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    @Test
    fun testActualGoSHA256AndNativeCryptography() {
        val hash = Mobilebridge.hash256("abc".toByteArray(Charsets.UTF_8))
        assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", hash.joinToString("") { "%02x".format(it) })
        val checked = JSONObject(Mobilebridge.nativeSelfTest())
        for (name in listOf("sha256", "ed25519", "hpke", "aead", "spake2", "tamperingRejected", "confirmationGate", "synthetic")) {
            assertTrue("native $name", checked.getBoolean(name))
        }
        assertFalse(checked.getBoolean("realVaultReady"))
    }

    @Test
    fun testGoKeysAreIndependentAndUntrustedAndClosed() {
        val device = Mobilebridge.newDevice()
        var material: ByteArray? = null
        var restored: org.harmoniavault.go.mobilebridge.Device? = null
        try {
            val public = device.execute("{\"version\":1,\"operation\":\"publicInfo\"}")
            val info = JSONObject(public)
            assertFalse(info.getBoolean("trusted"))
            assertFalse(info.getString("signingPublicKey") == info.getString("receivingPublicKey"))
            material = device.exportProtectedMaterial()
            restored = Mobilebridge.importProtectedMaterial(material)
            material.fill(0)
            assertEquals(public, restored.execute("{\"version\":1,\"operation\":\"publicInfo\"}"))
            assertTrue(JSONObject(restored.execute("{\"version\":1,\"operation\":\"cryptoCheck\"}")).getBoolean("hpke"))
            try { restored.execute("{\"version\":1,\"operation\":\"pull\"}"); fail("unenrolled device pulled") }
            catch (_: Exception) { /* 必须失败，不能凭本机钥匙进入保险库。 */ }
            restored.close()
            try { restored.exportProtectedMaterial(); fail("closed secret exported") }
            catch (_: Exception) { /* 必须失败。 */ }
        } finally { material?.fill(0); restored?.close(); device.close() }
    }

    @Test
    fun testProtocolRejectsExtraAuthorityAndUnsafeEndpoint() {
        for (command in listOf(
            "{\"version\":1,\"version\":1,\"operation\":\"capabilities\"}",
            "{\"version\":1,\"operation\":\"capabilities\",\"role\":\"admin\"}",
            "{\"version\":1,\"operation\":\"validateEndpoint\",\"endpoint\":\"http://example.invalid\"}",
            "{\"version\":1,\"operation\":\"validateEndpoint\",\"endpoint\":\"https://example.invalid/a/../b\"}",
        )) {
            try { Mobilebridge.executePublic(command); fail("unsafe command accepted") }
            catch (_: Exception) { /* 必须失败。 */ }
        }
    }

    @Test
    fun testDeviceAuthenticationCannotBeSkipped() {
        val context = instrumentation.targetContext
        val alias = "harmonia/synthetic-native-test/v1"
        val filename = "synthetic-native-test.gcm"
        val keystore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        // 只清理本测试自己的新合成 slot，绝不遍历/读取宿主或其它账号钥匙。
        if (keystore.containsAlias(alias)) keystore.deleteEntry(alias)
        val file = File(File(context.noBackupFilesDir, "harmonia"), filename)
        file.delete()
        try {
            val store = ProtectedDeviceStore(context, alias, filename)
            if (!store.supported()) {
                try { store.prepareCreate(); fail("missing system auth accepted") }
                catch (_: Exception) { /* 未设置系统锁屏时必须拒绝。 */ }
                assertFalse(keystore.containsAlias(alias))
                assertFalse(store.exists())
            } else {
                val cipher = store.prepareCreate()
                try { store.saveAuthenticated(cipher, ByteArray(72)); fail("unauthenticated AES accepted") }
                catch (_: Exception) { /* 没有 BiometricPrompt 的一次认证，Keystore 不得执行。 */ }
                assertFalse(store.exists())
            }
        } finally {
            if (keystore.containsAlias(alias)) keystore.deleteEntry(alias)
            file.delete()
            File(file.path + ".bak").delete()
            File(file.path + ".new").delete()
        }
    }
}
