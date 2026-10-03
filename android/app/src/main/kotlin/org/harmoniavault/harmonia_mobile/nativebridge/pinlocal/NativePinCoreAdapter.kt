package org.harmoniavault.harmonia_mobile.nativebridge.pinlocal

import android.content.Context
import org.harmoniavault.go.mobilebridge.LocalPINCore
import org.harmoniavault.go.mobilebridge.LocalPINLifecycle
import org.harmoniavault.go.mobilebridge.LocalPINStore
import org.harmoniavault.go.mobilebridge.Mobilebridge
import org.json.JSONObject
import java.util.Base64
import java.util.concurrent.atomic.AtomicBoolean

/** 本类仅接实际 gobind 的 private native ABI，不给 Dart core/材料/lease。 */
internal class NativePinCoreAdapter private constructor(
    private val native: LocalPINCore,
    override val scope: PinScope,
    private val slot: PinNativeSlot,
    private val mode: PinNativeMode,
    private val shortCode: ByteArray,
    private val nativeCA: ByteArray,
) : PinNativeCore {
    private val closed = AtomicBoolean()
    private val used = AtomicBoolean()

    override fun create(pin: ByteArray, reentry: ByteArray): PinProvisioned {
        if (closed.get() || mode != PinNativeMode.SETUP || !used.compareAndSet(false, true)) throw PinLocalException(PinLocalFault.CLOSED)
        val response = native.create(pin, reentry)
        return try { PinNativeJSONCodec.provision(response, scope) } finally { response.fill(0) }
    }

    override fun execute(pin: ByteArray, completeCanonicalIntent: ByteArray, snapshot: PinProtectedSnapshot, store: PinDurableStore): String {
        if (closed.get() || mode == PinNativeMode.SETUP || !used.compareAndSet(false, true)) throw PinLocalException(PinLocalFault.CLOSED)
        if (store !is PinKeystoreStore || snapshot.scope != scope || snapshot.upgradeRequired) throw PinLocalException(PinLocalFault.STATE)
        val state = slot.loadWorkflow()
        val callback = object : LocalPINStore {
            override fun acquire() = store.acquire()
            override fun release() = store.release()
            override fun loadAttempts(): String {
                val current = store.readProtected()
                if (current.scope != scope || current.upgradeRequired || !current.record.contentEquals(snapshot.record)) throw PinLocalException(PinLocalFault.STATE)
                return PinNativeJSONCodec.attemptJSON(current.attempts)
            }
            override fun commitAttempts(expectedRevision: Long, nextJSON: String) {
                val next = PinNativeJSONCodec.attempt(nextJSON, snapshot.record)
                store.commit(expectedRevision, next)
            }
            override fun saveWorkflowSealed(packet: ByteArray) = slot.saveWorkflow(packet)
        }
        return try {
            when (mode) {
                PinNativeMode.BUSINESS -> native.execute(pin, completeCanonicalIntent, snapshot.record, state, nativeCA, callback)
                PinNativeMode.APPROVAL -> native.executeApproval(pin, completeCanonicalIntent, shortCode, snapshot.record, state, nativeCA, callback)
                PinNativeMode.ENROLLMENT -> native.executeEnrollment(pin, completeCanonicalIntent, shortCode, snapshot.record, state, nativeCA, callback)
                PinNativeMode.SETUP -> throw PinLocalException(PinLocalFault.CLOSED)
            }
        } finally { state.fill(0); shortCode.fill(0) }
    }

    fun cancel() {
        try { native.cancel() } finally { slot.cancel() }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        shortCode.fill(0); nativeCA.fill(0)
        native.close()
    }

    companion object {
        /** 不接受 caller bool；factory 必须持固定 slot 全业务锁，读取真实服务及 MAC。 */
        fun prepare(
            context: Context, configuration: PinSlot, mode: PinNativeMode,
            retireOwners: () -> Unit, nativeCA: ByteArray = ByteArray(0), shortCode: ByteArray = ByteArray(0),
        ): NativePinOperation {
            val slot = PinNativeSlot(context, configuration, retireOwners)
            slot.acquireOperation()
            var armedSetupCleanup = false
            var native: LocalPINCore? = null
            try {
                slot.requireNoSystemArtifacts()
                if (nativeCA.size > 2 shl 20 || ((mode == PinNativeMode.APPROVAL || mode == PinNativeMode.ENROLLMENT) != shortCode.isNotEmpty())) throw PinLocalException(PinLocalFault.CONFIGURATION)
                if (shortCode.isNotEmpty() && (shortCode.size != 8 || shortCode.any { it.toInt() !in 48..57 })) throw PinLocalException(PinLocalFault.CONFIGURATION)
                val capability = PinCapabilityClassifier(context)
                val store = PinKeystoreStore(context, configuration, slot::retireOwners, slotOwner = slot.owner)
                val binding: PinScope
                val lifecycle = object : LocalPINLifecycle { override fun retireOwners() = slot.retireOwners() }
                if (mode == PinNativeMode.SETUP) {
                    when (capability.current()) {
                        PinSystemVerdict.NO_SYSTEM_AUTH -> Unit
                        PinSystemVerdict.SYSTEM_READY -> throw PinLocalException(PinLocalFault.UPGRADE_REQUIRED)
                        PinSystemVerdict.BLOCKED -> throw PinLocalException(PinLocalFault.BLOCKED)
                    }
                    slot.requireFresh()
                    armedSetupCleanup = true
                    native = Mobilebridge.newLocalPINSetup(context.packageName, configuration.namespace, configuration.slot, configuration.endpoint, lifecycle)
                    binding = PinNativeJSONCodec.scope(native.scopeJSON(), context.packageName, configuration)
                } else {
                    val snapshot: PinProtectedSnapshot
                    store.acquire()
                    try { snapshot = store.readProtected() } finally { store.release() }
                    if (snapshot.upgradeRequired) throw PinLocalException(PinLocalFault.UPGRADE_REQUIRED)
                    when (capability.current()) {
                        PinSystemVerdict.NO_SYSTEM_AUTH -> Unit
                        PinSystemVerdict.BLOCKED -> throw PinLocalException(PinLocalFault.BLOCKED)
                        PinSystemVerdict.SYSTEM_READY -> {
                            store.acquire()
                            try { store.markUpgradeRequired(snapshot.scope) } finally { store.release() }
                            throw PinLocalException(PinLocalFault.UPGRADE_REQUIRED)
                        }
                    }
                    binding = snapshot.scope
                    native = Mobilebridge.openLocalPINCore(context.packageName, configuration.namespace, configuration.slot, configuration.endpoint, PinNativeJSONCodec.scopeJSON(binding), lifecycle)
                    if (PinNativeJSONCodec.scope(native.scopeJSON(), context.packageName, configuration) != binding) throw PinLocalException(PinLocalFault.STATE)
                }
                val adapter = NativePinCoreAdapter(native, binding, slot, mode, shortCode.copyOf(), nativeCA.copyOf())
                return NativePinOperation(context, adapter, slot, mode)
            } catch (failure: Exception) {
                var cleanupFailed = false
                try { native?.close() } catch (_: Exception) { cleanupFailed = true }
                try { slot.retireOwners() } catch (_: Exception) { cleanupFailed = true }
                if (armedSetupCleanup) try { slot.clearAll() } catch (_: Exception) { cleanupFailed = true }
                try { slot.releaseOperation() } catch (_: Exception) { cleanupFailed = true }
                if (cleanupFailed) throw PinLocalException(PinLocalFault.PERSISTENCE)
                throw if (failure is PinLocalException) failure else PinLocalException(PinLocalFault.BLOCKED)
            } finally { shortCode.fill(0) }
        }

        /** 忘记 PIN 只清 native 固定 slot，不能调用云删除/解包旧材料/复用旧身份。 */
        fun forgetLocal(context: Context, configuration: PinSlot, retireOwners: () -> Unit) {
            val slot = PinNativeSlot(context, configuration, retireOwners)
            slot.acquireOperation()
            try { slot.clearAll() } finally { slot.releaseOperation() }
        }
    }
}

/** mode 只选择成熟 command API，不是本地认证或云信任；Recovery 没有入口。 */
internal enum class PinNativeMode { SETUP, BUSINESS, APPROVAL, ENROLLMENT }

/** 每操作固定 slot 独占对象只留 native；调用方须 use/finally close。 */
internal class NativePinOperation internal constructor(
    context: Context,
    private val adapter: NativePinCoreAdapter,
    private val slot: PinNativeSlot,
    private val mode: PinNativeMode,
) : AutoCloseable {
    private val provider = LocalPinProvider(context, adapter, slot::retireOwners, slot, slotOwner = slot.owner)
    private val closed = AtomicBoolean()
    private val invoked = AtomicBoolean()
    private val durable = PinKeystoreStore(context, slot.configuration, slot::retireOwners, slotOwner = slot.owner)
    val scope get() = adapter.scope

    fun provision(pin: ByteArray, fullReentry: ByteArray) {
        if (closed.get() || mode != PinNativeMode.SETUP || !invoked.compareAndSet(false, true)) {
            pin.fill(0); fullReentry.fill(0)
            slot.retireOwners()
            throw PinLocalException(PinLocalFault.CLOSED)
        }
        try {
            provider.provision(pin, fullReentry)
            durable.acquire()
            try {
                val readback = durable.readProtected()
                if (readback.scope != scope || readback.upgradeRequired || readback.attempts.revision != 1L) throw PinLocalException(PinLocalFault.PERSISTENCE)
            } finally { durable.release() }
        } catch (failure: Exception) {
            try { slot.clearAll() } catch (_: Exception) { throw PinLocalException(PinLocalFault.PERSISTENCE) }
            throw failure
        } finally { pin.fill(0); fullReentry.fill(0); close() }
    }

    fun execute(pin: ByteArray, completeCanonicalIntent: ByteArray): String {
        try {
            if (closed.get() || mode == PinNativeMode.SETUP || !invoked.compareAndSet(false, true)) throw PinLocalException(PinLocalFault.CLOSED)
            val result = provider.execute(pin, completeCanonicalIntent)
            // 来源是 Go 的成熟业务 JSON；这个 public flag 从不作为签名/认证许可。
            val fields = JSONObject(result)
            if (fields.opt("requiresDeviceDeletion") == true) {
                slot.clearAll()
                closed.set(true)
            }
            return result
        } catch (failure: Exception) {
            slot.retireOwners()
            throw if (failure is PinLocalException) failure else PinLocalException(PinLocalFault.BLOCKED)
        } finally { pin.fill(0); completeCanonicalIntent.fill(0); close() }
    }

    fun cancel() { adapter.cancel() }

    override fun close() {
        // 业务使 closed=true 后仍需恰好一次关闭/释放，另用 release flag。
        if (!released.compareAndSet(false, true)) return
        closed.set(true)
        var failed = false
        try { provider.close() } catch (_: Exception) { failed = true }
        try { slot.releaseOperation() } catch (_: Exception) { failed = true }
        if (failed) throw PinLocalException(PinLocalFault.PERSISTENCE)
    }
    private val released = AtomicBoolean()
}

/** 严格小型 public/native metadata 编码器；无 KDF、材料解包或认证能力。 */
internal object PinNativeJSONCodec {
    private val scopeFields = setOf("package", "namespace", "slot", "endpoint", "mode", "authGeneration", "keyEpoch", "signingPublicKey", "receivingPublicKey")
    private val attemptFields = setOf("revision", "recordHash", "total", "failures", "delaySeconds")
    private fun objectMap(value: Any?): Map<String, Any?> {
        val map = value as? Map<*, *> ?: throw PinLocalException(PinLocalFault.STATE)
        return map.entries.associate { (it.key as? String ?: throw PinLocalException(PinLocalFault.STATE)) to it.value }
    }
    private fun objectValue(raw: String, max: Int): Map<String, Any?> = objectMap(Reader(raw, max).parse())
    private fun text(map: Map<String, Any?>, key: String): String = map[key] as? String ?: throw PinLocalException(PinLocalFault.STATE)
    private fun number(map: Map<String, Any?>, key: String): Long = map[key] as? Long ?: throw PinLocalException(PinLocalFault.STATE)
    private fun attempts(map: Map<String, Any?>, record: ByteArray): PinAttemptState {
        if (!map.keys.containsAll(attemptFields) || (map.keys - attemptFields - "pendingAttempt").isNotEmpty()) throw PinLocalException(PinLocalFault.STATE)
        val delay = number(map, "delaySeconds")
        if (delay !in 0..600) throw PinLocalException(PinLocalFault.STATE)
        return PinAttemptState(number(map, "revision"), text(map, "recordHash"), number(map, "total"), number(map, "failures"), if (map.containsKey("pendingAttempt")) text(map, "pendingAttempt") else "", delay.toInt()).also { it.validate(record) }
    }
    fun attempt(raw: String, record: ByteArray): PinAttemptState = attempts(objectValue(raw, 1024), record)
    fun scope(raw: String, pkg: String, slot: PinSlot): PinScope {
        val o = objectValue(raw, 4096)
        if (o.keys != scopeFields) throw PinLocalException(PinLocalFault.STATE)
        val s = PinScope(text(o, "package"), text(o, "namespace"), text(o, "slot"), text(o, "endpoint"), text(o, "mode"), text(o, "authGeneration"), text(o, "keyEpoch"), text(o, "signingPublicKey"), text(o, "receivingPublicKey"))
        s.validate()
        if (s.packageName != pkg || !slot.matches(s)) throw PinLocalException(PinLocalFault.STATE)
        return s
    }
    fun provision(raw: ByteArray, expected: PinScope): PinProvisioned {
        if (!raw.toString(Charsets.UTF_8).toByteArray(Charsets.UTF_8).contentEquals(raw)) throw PinLocalException(PinLocalFault.STATE)
        val o = objectValue(raw.toString(Charsets.UTF_8), 16_384)
        if (o.keys != setOf("profile", "recordBase64", "attempts") || o["profile"] != "harmonia/native-pin-provision/v1") throw PinLocalException(PinLocalFault.STATE)
        val encoded = text(o, "recordBase64")
        val record = try { Base64.getUrlDecoder().decode(encoded) } catch (_: Exception) { throw PinLocalException(PinLocalFault.STATE) }
        if (record.size !in 1..8192 || Base64.getUrlEncoder().withoutPadding().encodeToString(record) != encoded) throw PinLocalException(PinLocalFault.STATE)
        val recordObject = objectValue(record.toString(Charsets.UTF_8), 8192)
        val recordBinding = objectMap(recordObject["binding"])
        if (scope(encode(recordBinding), expected.packageName, PinSlot(expected.namespace, expected.slot, expected.endpoint)) != expected) throw PinLocalException(PinLocalFault.STATE)
        val a = objectMap(o["attempts"])
        return PinProvisioned(record, attempts(a, record)).also {
            if (it.attempts.revision != 1L || it.attempts.total != 0L || it.attempts.failures != 0L || it.attempts.pendingAttempt.isNotEmpty()) throw PinLocalException(PinLocalFault.STATE)
        }
    }
    fun scopeJSON(s: PinScope): String = encode(linkedMapOf("package" to s.packageName, "namespace" to s.namespace, "slot" to s.slot, "endpoint" to s.endpoint, "mode" to s.mode, "authGeneration" to s.authGeneration, "keyEpoch" to s.keyEpoch, "signingPublicKey" to s.signingPublicKey, "receivingPublicKey" to s.receivingPublicKey))
    fun attemptJSON(a: PinAttemptState): String = encode(linkedMapOf<String, Any>("revision" to a.revision, "recordHash" to a.recordHash, "total" to a.total, "failures" to a.failures, "delaySeconds" to a.delaySeconds.toLong()).also { if (a.pendingAttempt.isNotEmpty()) it["pendingAttempt"] = a.pendingAttempt })
    private fun encode(value: Any?): String = when (value) {
        null -> "null"
        is String -> "\"" + value.map { c -> when (c) { '"' -> "\\\""; '\\' -> "\\\\"; else -> if (c.code < 32) "\\u%04x".format(c.code) else c.toString() } }.joinToString("") + "\""
        is Long -> value.toString()
        is Map<*, *> -> value.entries.joinToString(",", "{", "}") { encode(it.key as String) + ":" + encode(it.value) }
        else -> throw PinLocalException(PinLocalFault.STATE)
    }
    private class Reader(private val raw: String, max: Int) {
        private var at = 0
        init { if (raw.isEmpty() || raw.toByteArray(Charsets.UTF_8).size > max) throw PinLocalException(PinLocalFault.STATE) }
        private fun fail(): Nothing = throw PinLocalException(PinLocalFault.STATE)
        private fun ws() { while (at < raw.length && raw[at] in " \t\n\r") at++ }
        fun parse(): Any? { val result = value(0); ws(); if (at != raw.length) fail(); return result }
        private fun value(depth: Int): Any? {
            ws(); if (depth > 8 || at >= raw.length) fail()
            return when (raw[at]) {
                '{' -> {
                    at++; ws(); val fields = linkedMapOf<String, Any?>()
                    if (at < raw.length && raw[at] == '}') { at++; fields } else {
                        while (true) {
                            ws(); val key = string(); if (fields.containsKey(key) || fields.size >= 32) fail()
                            ws(); if (at >= raw.length || raw[at++] != ':') fail(); fields[key] = value(depth + 1); ws()
                            if (at >= raw.length) fail(); val end = raw[at++]; if (end == '}') break; if (end != ',') fail()
                        }; fields
                    }
                }
                '"' -> string()
                '-', in '0'..'9' -> {
                    val start = at
                    if (raw[at] == '-') at++
                    if (at >= raw.length || raw[at] !in '0'..'9') fail()
                    if (raw[at++] != '0') while (at < raw.length && raw[at] in '0'..'9') at++
                    raw.substring(start, at).toLongOrNull() ?: fail()
                }
                else -> fail()
            }
        }
        private fun string(): String {
            if (at >= raw.length || raw[at++] != '"') fail()
            val out = StringBuilder()
            while (at < raw.length) {
                val c = raw[at++]
                if (c == '"') return out.toString().also { if (it.toByteArray(Charsets.UTF_8).toString(Charsets.UTF_8) != it) fail() }
                if (c.code < 32) fail()
                if (c != '\\') { out.append(c); continue }
                if (at >= raw.length) fail()
                when (val e = raw[at++]) {
                    '"', '\\', '/' -> out.append(e)
                    'b' -> out.append('\b'); 'f' -> out.append('\u000c'); 'n' -> out.append('\n'); 'r' -> out.append('\r'); 't' -> out.append('\t')
                    'u' -> { if (at + 4 > raw.length) fail(); val n = raw.substring(at, at + 4).toIntOrNull(16) ?: fail(); out.append(n.toChar()); at += 4 }
                    else -> fail()
                }
            }
            fail()
        }
    }
}
