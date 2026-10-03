package org.harmoniavault.harmonia_mobile.nativebridge.pinlocal

import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

/** 独立存储实际验收，尚未运行。Codec bytes不是Go设备材料，不能作为PIN业务成功证据。 */
class PinLocalStoreAndroidTest {
    private fun digest(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it.toInt() and 255) }
    private fun fixture(body: (PinKeystoreStore, PinProtectedSnapshot, File, AtomicInteger) -> Unit) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val slot = PinSlot("native-pin-store-fixture/v1", "fixture-" + UUID.randomUUID(), "https://example.invalid")
        val pub = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32) { 41 })
        val scope = PinScope(context.packageName, slot.namespace, slot.slot, slot.endpoint, "pin", "1".repeat(32), "2".repeat(32), pub, pub)
        val record = "synthetic encrypted-record storage fixture; not decryptable Go material".toByteArray()
        val snapshot = PinProtectedSnapshot(scope, record, PinAttemptState(1, digest(record), 0, 0, "", 0))
        val retired = AtomicInteger()
        val store = PinKeystoreStore(context, slot, { retired.incrementAndGet() })
        val id = digest((context.packageName + "\u0000" + slot.namespace + "\u0000" + slot.slot).toByteArray())
        val packet = File(File(context.noBackupFilesDir, "harmonia/app-pin"), "$id.pin")
        try { body(store, snapshot, packet, retired) } finally {
            val cleanup = PinKeystoreStore(context, slot, { retired.incrementAndGet() })
            cleanup.acquire()
            try { cleanup.deleteLocalPacket() } finally { cleanup.release() }
            File(packet.parentFile, "$id.lock").delete()
        }
    }
    private fun rejects(body: () -> Unit) {
        var failed = false
        try { body() } catch (_: PinLocalException) { failed = true }
        assertTrue("invalid storage returned success", failed)
    }
    @Test fun freshRecordAndLimiterAreOneAuthenticatedPacketAndCAS() = fixture { store, snapshot, packet, _ ->
        store.acquire()
        try {
            store.provision(snapshot)
            assertTrue(packet.exists())
            assertEquals(snapshot.attempts, store.load())
            val charged = snapshot.attempts.copy(revision = 2, total = 1, failures = 1, pendingAttempt = "a".repeat(64))
            store.commit(1, charged)
            assertEquals(charged, store.load())
            rejects { store.commit(1, charged) }
        } finally { store.release() }
    }
    @Test fun tamperedMacClosesAndMissingPacketDoesNotBootstrap() = fixture { store, snapshot, packet, retired ->
        store.acquire()
        try { store.provision(snapshot) } finally { store.release() }
        val bytes = packet.readBytes(); bytes[20] = (bytes[20].toInt() xor 1).toByte(); packet.writeBytes(bytes)
        store.acquire()
        try { rejects { store.load() }; assertTrue(retired.get() > 0) } finally { store.release() }
        packet.delete()
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val reopened = PinKeystoreStore(context, PinSlot(snapshot.scope.namespace, snapshot.scope.slot, snapshot.scope.endpoint), { retired.incrementAndGet() })
        reopened.acquire()
        try { rejects { reopened.load() }; assertFalse(packet.exists()) } finally { reopened.release() }
    }
    @Test fun upgradeLatchPersistsAcrossRestartAndDisablesDurableGoLoad() = fixture { store, snapshot, _, _ ->
        store.acquire()
        try { store.provision(snapshot); store.markUpgradeRequired(snapshot.scope); assertTrue(store.readProtected().upgradeRequired) } finally { store.release() }
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val reopened = PinKeystoreStore(context, PinSlot(snapshot.scope.namespace, snapshot.scope.slot, snapshot.scope.endpoint), {})
        reopened.acquire()
        try { assertTrue(reopened.readProtected().upgradeRequired); rejects { reopened.load() } } finally { reopened.release() }
    }
    @Test fun failedLatchWriteNeverReportsSuccessOrRevivesOldMacOnRestart() = fixture { store, snapshot, _, retired ->
        store.acquire()
        try { store.provision(snapshot) } finally { store.release() }
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val slot = PinSlot(snapshot.scope.namespace, snapshot.scope.slot, snapshot.scope.endpoint)
        val failing = PinKeystoreStore(context, slot, { retired.incrementAndGet() }, { throw IllegalStateException("synthetic write failure") })
        failing.acquire()
        try { rejects { failing.markUpgradeRequired(snapshot.scope) }; assertTrue(retired.get() > 0) } finally { failing.release() }
        val reopened = PinKeystoreStore(context, slot, {})
        reopened.acquire()
        try { rejects { reopened.load() } } finally { reopened.release() }
    }
    @Test fun aliasRetirementFailureStaysClosedWithoutClaimingDurableUpgrade() = fixture { store, snapshot, _, retired ->
        store.acquire()
        try { store.provision(snapshot) } finally { store.release() }
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val slot = PinSlot(snapshot.scope.namespace, snapshot.scope.slot, snapshot.scope.endpoint)
        val failing = PinKeystoreStore(context, slot, { retired.incrementAndGet() },
            { throw IllegalStateException("synthetic write failure") },
            { throw IllegalStateException("synthetic alias failure") })
        failing.acquire()
        try {
            var fault: PinLocalFault? = null
            try { failing.markUpgradeRequired(snapshot.scope) } catch (e: PinLocalException) { fault = e.fault }
            assertEquals(PinLocalFault.PERSISTENCE, fault)
            assertTrue(retired.get() > 0)
            rejects { failing.readProtected() }
        } finally { failing.release() }
        // 双持久失败没有durable成功保证。明确验证仍有旧包，不伪称latch已保存。
        val reopened = PinKeystoreStore(context, slot, {})
        reopened.acquire()
        try { assertFalse(reopened.readProtected().upgradeRequired) } finally { reopened.release() }
    }

}
