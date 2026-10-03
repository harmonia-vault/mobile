package org.harmoniavault.harmonia_mobile.nativebridge.pinlocal

import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.Base64
import java.util.concurrent.atomic.AtomicReference
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** 不用Android stub冒称Keystore/AtomicFile成功；只测纯分类/同一codec/实际OS文件锁。 */
internal object PinLocalAdapterHostTest {
    @JvmStatic fun main(args: Array<String>) {
        if (args.size == 3 && args[0] == "lock-child") {
            val lock = PinSlotFileLock(File(args[1])); lock.acquire()
            File(args[2]).writeText("held")
            Thread.sleep(30_000); lock.release(); return
        }
        var passed = 0
        fun test(name: String, body: () -> Unit) { body(); passed++; println("PASS $name") }
        test("only-objective-no-system-auth") {
            for (a in listOf(11, 12)) for (b in listOf(11, 12)) check(PinCapabilityPolicy.classify(34, false, a, b) == PinSystemVerdict.NO_SYSTEM_AUTH)
            check(PinCapabilityPolicy.classify(34, true, 0, 1) == PinSystemVerdict.SYSTEM_READY)
            check(PinCapabilityPolicy.classify(34, false, 0, 0) == PinSystemVerdict.SYSTEM_READY)
            for (bad in listOf(1, 7, 9, 15, 20, 21, -1, -2, 987)) {
                check(PinCapabilityPolicy.classify(34, false, bad, 11) == PinSystemVerdict.BLOCKED)
                check(PinCapabilityPolicy.classify(34, false, 11, bad) == PinSystemVerdict.BLOCKED)
            }
            check(PinCapabilityPolicy.classify(34, false, 0, 11) == PinSystemVerdict.BLOCKED)
            check(PinCapabilityPolicy.classify(34, false, 11, 0) == PinSystemVerdict.BLOCKED)
            check(PinCapabilityPolicy.classify(34, true, 11, 11) == PinSystemVerdict.BLOCKED)
            check(PinCapabilityPolicy.classify(29, false, 11, 11) == PinSystemVerdict.BLOCKED)
            check(PinCapabilityPolicy.classify(34, null, 11, 11) == PinSystemVerdict.BLOCKED)
        }
        // Codec fixture is public synthetic bytes, explicitly not decryptable Go key material.
        val record = "synthetic encrypted-record codec fixture".toByteArray()
        val hash = MessageDigest.getInstance("SHA-256").digest(record).joinToString("") { "%02x".format(it.toInt() and 255) }
        val pub = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32) { 41 })
        val scope = PinScope("org.harmonia.fixture", "fixture\u0000pin/v1", "fixture-pin", "https://example.invalid", "pin", "1".repeat(32), "2".repeat(32), pub, pub)
        val state = PinAttemptState(1, hash, 0, 0, "", 0)
        val snapshot = PinProtectedSnapshot(scope, record, state)
        // Mature JCA HMAC uses public test key only, not an AndroidKeyStore substitute.
        val computeMac = { body: ByteArray -> Mac.getInstance("HmacSHA256").run { init(SecretKeySpec(ByteArray(32) { 51 }, "HmacSHA256")); doFinal(body) } }
        val packet = PinPacketCodec.seal(snapshot, computeMac)
        test("mac-complete-record-and-attempt-roundtrip") {
            val opened = PinPacketCodec.open(packet, computeMac)
            check(opened.scope == scope && opened.record.contentEquals(record) && opened.attempts == state)
        }
        fun rejects(body: () -> Unit) { try { body(); error("accepted invalid packet") } catch (_: PinLocalException) {} }
        test("mac-tamper-trailing-truncated-bounds") {
            rejects { PinPacketCodec.open(packet.copyOf().also { it[20] = (it[20].toInt() xor 1).toByte() }, computeMac) }
            rejects { PinPacketCodec.open(packet + byteArrayOf(0), computeMac) }
            rejects { PinPacketCodec.open(packet.copyOf(20), computeMac) }
            rejects { PinPacketCodec.open(ByteArray(PinPacketCodec.MAX_PACKET + 1), computeMac) }
            rejects { PinPacketCodec.decode(PinPacketCodec.encode(snapshot) + byteArrayOf(0)) }
        }
        test("durable-upgrade-latch-survives-codec-restart-and-capability-loss") {
            val latched = PinPacketCodec.seal(snapshot.copy(upgradeRequired = true), computeMac)
            val restarted = PinPacketCodec.open(latched, computeMac)
            check(restarted.upgradeRequired)
            check(PinCapabilityPolicy.classify(34, false, 11, 12) == PinSystemVerdict.NO_SYSTEM_AUTH)
            // The classifier becoming absent again does not clear the stored latch.
            check(restarted.upgradeRequired)
            check(restarted.attempts == state && restarted.scope == scope)
            var failed = false
            try { PinPacketCodec.seal(snapshot.copy(upgradeRequired = true)) { error("synthetic save/MAC failure") } }
            catch (_: IllegalStateException) { failed = true }
            check(failed)
        }
        test("fixed-mode-generation-and-counter-shape") {
            rejects { PinPacketCodec.encode(snapshot.copy(scope = scope.copy(mode = "system"))) }
            rejects { PinPacketCodec.encode(snapshot.copy(scope = scope.copy(authGeneration = scope.keyEpoch))) }
            rejects { PinPacketCodec.encode(snapshot.copy(attempts = state.copy(revision = -1))) }
            rejects { PinPacketCodec.encode(snapshot.copy(attempts = state.copy(failures = 1))) }
            rejects { PinPacketCodec.encode(snapshot.copy(attempts = state.copy(recordHash = "0".repeat(64)))) }
            rejects { PinPacketCodec.encode(snapshot.copy(scope = scope.copy(endpoint = "https://example.invalid?new"))) }
        }
        val directory = Files.createTempDirectory("harmonia-pin-lock-host-").toFile()
        try {
            val file = File(directory, "synthetic.lock")
            test("whole-attempt-lock-cross-instance-and-callback-thread") {
                val first = PinSlotFileLock(file); val second = PinSlotFileLock(file)
                first.acquire()
                try { second.acquire(); error("parallel slot acquired") } catch (e: PinLocalException) { check(e.fault == PinLocalFault.BUSY) }
                val error = AtomicReference<Throwable>()
                val release = Thread { try { first.release() } catch (e: Throwable) { error.set(e) } }
                release.start(); release.join(); check(error.get() == null)
                second.acquire(); second.release()
            }
            test("actual-cross-process-lock-and-kill-release") {
                val ready = File(directory, "child.marker")
                val java = File(System.getProperty("java.home"), "bin/java").absolutePath
                val builder = ProcessBuilder(java, "-cp", System.getProperty("java.class.path"), PinLocalAdapterHostTest::class.java.name, "lock-child", file.path, ready.path)
                builder.environment().clear(); builder.environment()["PATH"] = "/usr/bin:/bin"
                val child = builder.start()
                try {
                    val until = System.nanoTime() + 5_000_000_000L
                    while (!ready.exists() && System.nanoTime() < until) Thread.sleep(10)
                    check(ready.exists())
                    val parent = PinSlotFileLock(file)
                    try { parent.acquire(); error("parent bypassed child lock") } catch (e: PinLocalException) { check(e.fault == PinLocalFault.BUSY) }
                    child.destroyForcibly(); child.waitFor()
                    parent.acquire(); parent.release()
                } finally { child.destroyForcibly(); child.waitFor() }
            }
        } finally { directory.deleteRecursively() }
        println("PASS $passed host cases; Android Keystore/AtomicFile/provider still UNRUN")
    }
}
