package org.harmoniavault.harmonia_mobile.nativebridge

import android.content.Context
import android.system.Os
import android.util.AtomicFile
import org.harmoniavault.go.mobilebridge.AtomicSealedStateStore
import java.io.File
import java.io.FileInputStream
import java.io.ByteArrayOutputStream

/** 同一认证 owner 的普通保存和 DAG CAS 均比较完整已捕获密文；未持有 owner 只可查存在。 */
internal class ProtectedWorkflowStore(
    context: Context,
    filename: String = "workflow-state-v1.gcm",
    private val beforeSave: () -> Unit = {},
    private val operationActive: () -> Boolean = { true },
    private val owner: NativeSlotOwner? = null,
    private val beforeDirectorySync: () -> Unit = {},
) : AtomicSealedStateStore {
    private val directory = File(context.noBackupFilesDir, "harmonia")
    private val file = AtomicFile(File(directory, filename))
    val namespace = context.packageName + "\u0000harmonia/workflow-state/v1\u0000" + filename
    private val maxBytes = (8 shl 20) + 8192
    private var expected: ByteArray? = null
    fun hasArtifacts(): Boolean = listOf("", ".bak", ".new").any { File(file.baseFile.path + it).exists() }
    private fun active(): NativeSlotOwner {
        check(operationActive())
        return owner ?: error("captured slot owner required")
    }
    private fun loadRaw(): ByteArray {
        return NativeSlotOwner.readAtomicBytes(file.baseFile, maxBytes)?.also { validate(it) } ?: ByteArray(0)
    }
    fun load(): ByteArray = active().read {
        check(expected == null) { "authenticated state already captured" }
        loadRaw().also { expected = it.copyOf() }
    }
    private fun validate(packet: ByteArray) {
        check(packet.size in 40..maxBytes && String(packet, 0, 8, Charsets.US_ASCII) == "HARMST02")
    }
    private fun checkExpected(caller: ByteArray? = null, compareCaller: Boolean = false) {
        val captured = expected ?: error("state not captured")
        if (compareCaller) SealedCallbackContract.checkExpected(caller, captured)
        val current = loadRaw()
        try { check(current.contentEquals(captured)) { "stored state conflict" } }
        finally { current.fill(0) }
    }
    override fun checkSealed(caller: ByteArray?) = active().read { checkExpected(caller, compareCaller = true) }
    override fun compareAndSwapSealed(caller: ByteArray?, packet: ByteArray?) = save(packet, caller, compareCaller = true)
    override fun saveSealed(packet: ByteArray?) = save(packet, null)
    private fun save(input: ByteArray?, caller: ByteArray?, compareCaller: Boolean = false) = active().mutate {
        val packet = SealedCallbackContract.requirePacket(input)
        beforeSave(); check(operationActive()); validate(packet); checkExpected(caller, compareCaller)
        val output = file.startWrite()
        var publishing = false
        try {
            output.write(packet); check(operationActive())
            Os.fchmod(output.fd, 384); output.fd.sync(); publishing = true
            file.finishWrite(output)
            beforeDirectorySync(); NativeSlotOwner.syncDirectory(directory)
            val readback = loadRaw()
            try { check(readback.contentEquals(packet)) { "state readback unconfirmed" } }
            finally { readback.fill(0) }
            check(operationActive())
            expected?.fill(0); expected = packet.copyOf()
        } catch (failure: Exception) {
            // 发布开始后的异常可能已提交；保留可见记录并退役，不调用failWrite猜回滚。
            if (!publishing) file.failWrite(output); throw failure
        }
    }
    fun delete() = active().mutate {
        checkExpected(null); file.delete(); NativeSlotOwner.syncDirectory(directory)
        check(!hasArtifacts()); expected?.fill(0); expected = ByteArray(0)
    }
    fun closeCaptured() { expected?.fill(0); expected = null }
}
