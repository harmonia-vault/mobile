package org.harmoniavault.harmonia_mobile.nativebridge

import android.system.Os
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.app.KeyguardManager
import android.util.Log
import android.os.Bundle
import java.nio.ByteBuffer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import android.content.ServiceConnection
import android.os.Handler
import android.os.Looper
import android.os.IBinder
import android.os.Messenger
import android.os.Message
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import androidx.test.platform.app.InstrumentationRegistry
import org.harmoniavault.go.mobilebridge.AtomicSealedStateStore
import org.harmoniavault.go.nativeatomicfixture.Nativeatomicfixture
import org.harmoniavault.harmonia_mobile.nativebridge.pinlocal.*
import org.junit.Test
import org.junit.Assert.*
import java.io.File
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID

/** 独立API34 store/JNI有限验收；不调用Flutter/云/DAG/PIN认证；第6项仅用合成系统凭证真实CryptoObject。 */
class NativeSlotOwnerAndroidTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun packet(n: Int) = "HARMST01".toByteArray() + ByteArray(32) { n.toByte() }
    private fun slot() = "slot-owner-test-" + UUID.randomUUID().toString() + ".gcm"
    private fun rejected(block: () -> Unit) { var rejected = false; try { block() } catch (_: Exception) { rejected = true }; assertTrue(rejected) }
    private fun remoteLockVerdict(name: String, prepareAndKill: Boolean = false): Int {
        val done = CountDownLatch(1); val died = CountDownLatch(1); var code = -1
        val reply = Messenger(Handler(Looper.getMainLooper()) { message -> code = message.what; done.countDown(); true })
        val connection = object : ServiceConnection {
            override fun onServiceConnected(component: ComponentName, binder: IBinder) {
                val message = Message.obtain(null, if (prepareAndKill) 2 else 1); message.data.putString("slot", name); message.replyTo = reply
                Messenger(binder).send(message)
            }
            override fun onServiceDisconnected(component: ComponentName) { died.countDown() }
        }
        check(context.bindService(Intent(context, SlotOwnerProbeService::class.java), connection, Context.BIND_AUTO_CREATE))
        try { check(done.await(5, TimeUnit.SECONDS)); if (prepareAndKill) check(died.await(5, TimeUnit.SECONDS)); return code } finally { context.unbindService(connection) }
    }
    private fun clean(name: String) {
        NativeSlotOwner.acquire(context, name).use { owner -> owner.clear {
            val root = File(context.noBackupFilesDir, "harmonia")
            listOf("", ".bak", ".new").forEach { File(root, name + it).delete() }
        } }
    }
    @Test fun realGoProxyCheckAndCASThenOrdinarySave() {
        val name = slot()
        try { NativeSlotOwner.acquire(context, name).use { owner ->
            val store = ProtectedWorkflowStore(context, name, owner = owner)
            val initial = store.load(); assertEquals(0, initial.size)
            Nativeatomicfixture.checkAndCAS(store, initial, packet(1))
            store.saveSealed(packet(2))
            store.checkSealed(packet(2))
            rejected { Nativeatomicfixture.checkAndCAS(store, ByteArray(0), packet(3)) }
            rejected { store.saveSealed(packet(4)) }
            assertArrayEquals(packet(2), NativeSlotOwner.readAtomicBytes(File(File(context.noBackupFilesDir, "harmonia"), name), 8192))
            store.closeCaptured()
        } } finally { clean(name) }
    }
    @Test fun typedOpenerRetainsRealJNIAtomicInterface() {
        val name = slot()
        try { NativeSlotOwner.acquire(context, name).use { owner ->
            val store = ProtectedWorkflowStore(context, name, owner = owner); store.load()
            var checks = 0; var saves = 0
            val callback = object : AtomicSealedStateStore {
                override fun checkSealed(expected: ByteArray?) { checks++; store.checkSealed(expected) }
                override fun saveSealed(next: ByteArray?) { saves++; store.saveSealed(next) }
                override fun compareAndSwapSealed(expected: ByteArray?, next: ByteArray?) { store.compareAndSwapSealed(expected, next) }
            }
            Nativeatomicfixture.openTypedAndLogout(store.namespace, callback)
            assertTrue(checks >= 2); assertTrue(saves >= 1)
            owner.clear { store.delete() }; rejected { store.saveSealed(packet(1)) }
            store.closeCaptured()
        } } finally { clean(name) }
    }
    @Test fun cancellationDrainsBeforeNewOwnerAndPermanentLockSurvives() {
        val name = slot(); val directory = File(context.noBackupFilesDir, "harmonia/slot-owners-v1")
        val first = NativeSlotOwner.acquire(context, name)
        val paths = directory.listFiles()!!.map { it.name }.toSet()
        try {
            rejected { NativeSlotOwner.acquire(context, name) }
            assertEquals(1, remoteLockVerdict(name))
            first.retire(); rejected { first.read { } }
            rejected { NativeSlotOwner.acquire(context, name) }
        } finally { first.close() }
        assertEquals(0, remoteLockVerdict(name))
        NativeSlotOwner.acquire(context, name).use { next -> next.read { } }
        assertTrue(directory.listFiles()!!.map { it.name }.toSet().containsAll(paths))
        unfinishedPublicationAndUnsafeLockFailClosed()
    }
    @Test fun changedCapturedBundleRejectsStaleDeleteAndSave() {
        val name = slot(); val raw = File(File(context.noBackupFilesDir, "harmonia"), name)
        val first = NativeSlotOwner.acquire(context, name)
        try {
            val store = ProtectedWorkflowStore(context, name, owner = first); store.load(); store.saveSealed(packet(1))
            // 仅本测试包/合成密文模拟另一个writer；不解密或授信。
            raw.writeBytes(packet(2)); Os.chmod(raw.path, 384)
            rejected { store.delete() }; rejected { store.saveSealed(packet(3)) }
            assertArrayEquals(packet(2), raw.readBytes()); store.closeCaptured()
        } finally { first.close(); clean(name) }
        val unknown = slot(); val committed = File(File(context.noBackupFilesDir, "harmonia"), unknown)
        NativeSlotOwner.acquire(context, unknown).use { owner ->
            val store = ProtectedWorkflowStore(context, unknown, owner = owner,
                beforeDirectorySync = { error("synthetic post-finish sync failure") })
            store.load(); rejected { store.saveSealed(packet(7)) }
            assertArrayEquals(packet(7), committed.readBytes())
            assertFalse(owner.alive()); rejected { store.saveSealed(packet(8)) }; store.closeCaptured()
        }
        var synced = false
        try { NativeSlotOwner.acquire(context, unknown, afterBaselineSync = { synced = true }).use { owner ->
            assertTrue(synced)
            val store = ProtectedWorkflowStore(context, unknown, owner = owner)
            assertArrayEquals(packet(7), store.load()); store.saveSealed(packet(8))
            assertArrayEquals(packet(8), committed.readBytes()); store.closeCaptured()
        } } finally { clean(unknown) }
    }
    private fun unfinishedPublicationAndUnsafeLockFailClosed() {
        val name = slot(); val first = NativeSlotOwner.acquire(context, name); first.close()
        val root = File(context.noBackupFilesDir, "harmonia")
        val temporary = File(root, name + ".new"); temporary.writeBytes(packet(1)); Os.chmod(temporary.path, 384)
        try { NativeSlotOwner.acquire(context, name).use { owner ->
            val store = ProtectedWorkflowStore(context, name, owner = owner)
            rejected { store.load() }; rejected { store.saveSealed(packet(2)) }
        } } finally { clean(name) }
        val hash = MessageDigest.getInstance("SHA-256").digest((context.packageName + "\u0000harmonia/native-slot/v1\u0000" + name).toByteArray()).joinToString("") { "%02x".format(it.toInt() and 255) }
        val lock = File(root, "slot-owners-v1/$hash.lock")
        Os.chmod(lock.path, 416)
        try { rejected { NativeSlotOwner.acquire(context, name) } } finally { Os.chmod(lock.path, 384) }
    }
    private class Outcome : MethodChannel.Result {
        val ready = CountDownLatch(1); var value: Any? = null; var code: String? = null
        override fun success(result: Any?) { value = result; ready.countDown() }
        override fun error(errorCode: String, message: String?, details: Any?) { code = errorCode; ready.countDown() }
        override fun notImplemented() { code = "NOT_IMPLEMENTED"; ready.countDown() }
    }
    @Test fun ownedCreateCancelAndProcessDeathCanResume() {
        val i = InstrumentationRegistry.getInstrumentation(); val name = slot()
        val filename = name + ".device"; val alias = "harmonia/slotownerfixture/" + name
        val store = ProtectedDeviceStore(context, alias, filename, name)
        assertTrue("explicit synthetic strong credential required", store.supported())
        val activity = i.startActivitySync(Intent(context, SlotOwnerFixtureActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        val messenger = object : BinaryMessenger {
            override fun send(channel: String, message: ByteBuffer?) { }
            override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) { }
            override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) { }
        }
        lateinit var plugin: NativeBridgePlugin
        i.runOnMainSync { plugin = NativeBridgePlugin(activity, messenger, store, name) }
        fun create(stage: String): Outcome {
            val outcome = Outcome()
            i.runOnMainSync { plugin.onMethodCall(MethodCall("createDevice", null), outcome) }
            Log.i("HarmoniaSlotTest", "AWAIT_SLOT_AUTH:" + stage)
            assertTrue("system authentication callback timeout", outcome.ready.await(45, TimeUnit.SECONDS))
            return outcome
        }
        try {
            val cancelled = create("cancel-create")
            assertEquals("AUTH_CANCELLED", cancelled.code); assertTrue(cancelled.value == null)
            assertFalse(store.hasArtifacts())
            assertEquals(3, remoteLockVerdict(name, prepareAndKill = true))
            val intent = NativeDeviceSetupIntent(context, name, filename, alias)
            val original = intent.read() ?: error("durable setup intent absent")
            assertEquals("prepared", original.phase); assertFalse(store.exists())
            val oldAlias = intent.referenceAlias() ?: error("setup locator absent")
            val completed = create("retry-create")
            assertTrue("create after interrupted setup rejected", completed.code == null)
            assertFalse(JSONObject(completed.value as String).getBoolean("trusted"))
            val current = intent.read() ?: error("successful locator absent")
            assertEquals("ready", current.phase); assertNotEquals(original.generation, current.generation)
            val keys = java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            assertFalse(keys.containsAlias(oldAlias)); assertTrue(store.exists())
        } finally {
            i.runOnMainSync { plugin.dispose(); activity.finish() }
            NativeSlotOwner.acquire(context, name, filename, alias).use { owner -> owner.clear {
                if (store.exists()) { store.delete(owner); store.finishDeletion(owner) }
                else if (store.hasArtifacts()) store.cancelPreparedCreate(owner)
            } }
            assertFalse(store.hasArtifacts())
        }
    }

    @Test fun pinLimiterAndWorkflowShareOwnerThroughForget() {
        val name = slot(); val config = PinSlot("harmonia/mobile/app-pin/v1", name, "https://synthetic.example.invalid")
        val slot = PinNativeSlot(context, config, {})
        slot.acquireOperation()
        try {
            val pub = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32) { 1 })
            val record = byteArrayOf(1, 2, 3)
            val hash = MessageDigest.getInstance("SHA-256").digest(record).joinToString("") { "%02x".format(it.toInt() and 255) }
            val scope = PinScope(context.packageName, config.namespace, name, config.endpoint, "pin", "1".repeat(32), "2".repeat(32), pub, pub)
            val store = PinKeystoreStore(context, config, {}, slotOwner = slot.owner)
            store.acquire()
            try {
                store.provision(PinProtectedSnapshot(scope, record, PinAttemptState(1, hash, 0, 0, "", 0)))
                store.commit(1, PinAttemptState(2, hash, 1, 1, "3".repeat(64), 0))
            } finally { store.release() }
            slot.loadWorkflow(); slot.saveWorkflow(packet(1))
            store.acquire()
            try { store.commit(2, PinAttemptState(3, hash, 1, 0, "", 0)) } finally { store.release() }
            slot.clearAll(); rejected { slot.saveWorkflow(packet(2)) }; assertFalse(slot.owner.alive())
        } finally { slot.releaseOperation() }
    }
}

/** 仅SDK可观察前置/清理；不输出系统PIN值、不读取PIN字段树。 */
class NativeSlotSecurityProbeTest {
    @Test fun deviceCredentialState() {
        val i = InstrumentationRegistry.getInstrumentation()
        val secure = i.targetContext.getSystemService(KeyguardManager::class.java).isDeviceSecure
        i.sendStatus(1, Bundle().apply { putString("SDK_DEVICE_SECURE", if (secure) "true" else "false") })
    }
}
