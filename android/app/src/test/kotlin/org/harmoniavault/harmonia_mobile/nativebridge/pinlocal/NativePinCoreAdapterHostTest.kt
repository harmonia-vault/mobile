package org.harmoniavault.harmonia_mobile.nativebridge.pinlocal

import java.nio.file.Files
import java.security.MessageDigest
import java.util.Base64

/** 只运行纯元数据、Java 文件锁及 CAS；不会执行 Android stub/Go JNI/假认证。 */
internal object NativePinCoreAdapterHostTest {
    private var passed = 0
    private fun test(name: String, body: () -> Unit) { body(); passed++; println("PASS " + name) }
    private fun rejected(fault: PinLocalFault, body: () -> Unit) {
        try { body(); error("expected rejection") } catch (e: PinLocalException) { check(e.fault == fault) }
    }
    private val pub = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32) { 17 })
    private val slot = PinSlot("harmonia/native/pin/v1", "main", "https://synthetic.example")
    private val scope = PinScope("org.harmonia.fixture.pin", slot.namespace, slot.slot, slot.endpoint, "pin", "01".repeat(16), "02".repeat(16), pub, pub)
    private fun recordHash(record: ByteArray) = MessageDigest.getInstance("SHA-256").digest(record).joinToString("") { "%02x".format(it.toInt() and 255) }
    @JvmStatic fun main(args: Array<String>) {
        test("exact public scope JSON, duplicate/unknown/cross-slot rejection") {
            val raw = PinNativeJSONCodec.scopeJSON(scope)
            check(PinNativeJSONCodec.scope(raw, scope.packageName, slot) == scope)
            rejected(PinLocalFault.STATE) { PinNativeJSONCodec.scope(raw.dropLast(1) + ",\"mode\":\"pin\"}", scope.packageName, slot) }
            rejected(PinLocalFault.STATE) { PinNativeJSONCodec.scope(raw.dropLast(1) + ",\"authenticated\":1}", scope.packageName, slot) }
            rejected(PinLocalFault.STATE) { PinNativeJSONCodec.scope(raw, "org.harmonia.other", slot) }
            rejected(PinLocalFault.STATE) { PinNativeJSONCodec.scope(raw, scope.packageName, slot.copy(endpoint = "https://other.example")) }
            rejected(PinLocalFault.STATE) { PinNativeJSONCodec.scope(raw.replace("harmonia/native/pin/v1", "\\ud800"), scope.packageName, slot) }
        }
        test("attempt JSON uses exact signed-native integers and required lowercase fields") {
            val record = "synthetic cipher".toByteArray()
            val state = PinAttemptState(3, recordHash(record), 1, 0, "", 0)
            val raw = PinNativeJSONCodec.attemptJSON(state)
            check(PinNativeJSONCodec.attempt(raw, record) == state)
            for (bad in listOf(raw.replace("\"revision\":3", "\"revision\":9223372036854775808"), raw.replace("\"total\":1", "\"total\":1.0"), raw.replace("\"total\":1", "\"total\":1e0"), raw.replace("\"total\":1,", ""), raw.replace("\"total\":1", "\"Total\":1"), raw.dropLast(1) + ",\"total\":1}")) {
                rejected(PinLocalFault.STATE) { PinNativeJSONCodec.attempt(bad, record) }
            }
            val max = PinAttemptState(Long.MAX_VALUE, recordHash(record), Long.MAX_VALUE, 0, "", 0)
            check(PinNativeJSONCodec.attempt(PinNativeJSONCodec.attemptJSON(max), record) == max)
        }
        test("native provision keeps original cipher bytes and exact scope/hash") {
            // 这是公开元数据转换向量，绝不是可解包 Go Record/真实设备材料。
            val record = ("{\"binding\":" + PinNativeJSONCodec.scopeJSON(scope) + "}").toByteArray()
            val attempts = PinAttemptState(1, recordHash(record), 0, 0, "", 0)
            val blob = Base64.getUrlEncoder().withoutPadding().encodeToString(record)
            val raw = "{\"profile\":\"harmonia/native-pin-provision/v1\",\"recordBase64\":\"$blob\",\"attempts\":" + PinNativeJSONCodec.attemptJSON(attempts) + "}"
            val parsed = PinNativeJSONCodec.provision(raw.toByteArray(), scope)
            check(parsed.encryptedRecord.contentEquals(record) && parsed.attempts == attempts)
            rejected(PinLocalFault.STATE) { PinNativeJSONCodec.provision(raw.replace(blob, blob + "=").toByteArray(), scope) }
            rejected(PinLocalFault.STATE) { PinNativeJSONCodec.provision(raw.replace(recordHash(record), "00".repeat(32)).toByteArray(), scope) }
            rejected(PinLocalFault.STATE) { PinNativeJSONCodec.provision(raw.toByteArray(), scope.copy(authGeneration = "03".repeat(16))) }
        }
        test("cross-instance whole-business file lock rejects second owner without reset") {
            val dir = Files.createTempDirectory("harmonia-pin-business-lock-")
            val file = dir.resolve("synthetic.operation.lock").toFile()
            val first = PinSlotFileLock(file)
            val second = PinSlotFileLock(file)
            try {
                first.acquire()
                rejected(PinLocalFault.BUSY) { second.acquire() }
                check(first.valid() && !second.valid())
                first.release()
                second.acquire(); check(second.valid()); second.release()
            } finally {
                if (first.valid()) first.release()
                if (second.valid()) second.release()
                Files.deleteIfExists(file.toPath()); Files.deleteIfExists(dir)
            }
        }
        test("state CAS rejects lost original/moved namespace and bounded malformed packets") {
            val packet = ByteArray(40).also { "HARMST01".toByteArray().copyInto(it) }
            PinNativeStateCAS.validate(packet)
            PinNativeStateCAS.match(PinNativeStateCAS.hash(ByteArray(0)), ByteArray(0))
            PinNativeStateCAS.match(PinNativeStateCAS.hash(packet), packet)
            rejected(PinLocalFault.PERSISTENCE) { PinNativeStateCAS.match(PinNativeStateCAS.hash(packet), packet.copyOf().also { it[39] = 1 }) }
            rejected(PinLocalFault.PERSISTENCE) { PinNativeStateCAS.match(PinNativeStateCAS.hash(packet), ByteArray(0)) }
            rejected(PinLocalFault.STATE) { PinNativeStateCAS.validate(ByteArray(40)) }
            rejected(PinLocalFault.STATE) { PinNativeStateCAS.validate(ByteArray(PinNativeStateCAS.MAX_STATE + 1)) }
            check(PinNativeStateCAS.slotID(scope.packageName, slot.namespace, slot.slot) != PinNativeStateCAS.slotID("org.harmonia.other", slot.namespace, slot.slot))
            check(PinNativeStateCAS.slotID(scope.packageName, slot.namespace, slot.slot) != PinNativeStateCAS.slotID(scope.packageName, slot.namespace + "other", slot.slot))
        }
        println("PASS native adapter host contract tests=" + passed)
        println("UNRUN Android actual classifier/Keystore/AtomicFile/JNI/PIN product")
    }
}
