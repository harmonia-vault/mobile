package org.harmoniavault.harmonia_mobile.nativebridge

import android.content.Context
import android.system.Os
import android.util.AtomicFile
import org.harmoniavault.go.mobilebridge.SealedStateStore
import java.io.File
import java.io.ByteArrayOutputStream

/** 仅接收Go已经AES-GCM密封的可变长状态。明文/钥匙/token没有Kotlin或Dart导出路径。 */
internal class ProtectedWorkflowStore(
    context: Context,
    filename: String = "workflow-state-v1.gcm",
    private val beforeSave: () -> Unit = {},
    private val operationActive: () -> Boolean = { true },
) : SealedStateStore {
    private val directory = File(context.noBackupFilesDir, "harmonia")
    private val file = AtomicFile(File(directory, filename))
    val namespace = context.packageName + "\u0000harmonia/workflow-state/v1\u0000" + filename
    private val maxBytes = (8 shl 20) + 8192

    /** 只读存在性，不解密或因坏旧状态而允许换保护模式。 */
    fun hasArtifacts(): Boolean = listOf("", ".bak", ".new").any { File(file.baseFile.path + it).exists() }

    fun load(): ByteArray {
        check(operationActive())
        if (!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) return ByteArray(0)
        return file.openRead().use { input ->
            val buffer = ByteArray(8192)
            val output = ByteArrayOutputStream()
            while (output.size() <= maxBytes) {
                val count = input.read(buffer, 0, minOf(buffer.size, maxBytes + 1 - output.size()))
                if (count < 0) break
                output.write(buffer, 0, count)
            }
            val bytes = output.toByteArray()
            check(bytes.size in 40..maxBytes && String(bytes, 0, 8, Charsets.US_ASCII) == "HARMST01")
            bytes
        }
    }

    override fun saveSealed(packet: ByteArray) {
        beforeSave()
        check(operationActive() && packet.size in 40..maxBytes)
        check(String(packet, 0, 8, Charsets.US_ASCII) == "HARMST01")
        check(directory.exists() || directory.mkdirs())
        Os.chmod(directory.path, 0b111000000)
        val output = file.startWrite()
        try {
            output.write(packet)
            check(operationActive())
            Os.fchmod(output.fd, 0b110000000)
            output.fd.sync()
            file.finishWrite(output)
            check(load().contentEquals(packet))
        } catch (failure: Exception) {
            file.failWrite(output)
            throw failure
        }
    }

    fun delete() {
        file.delete()
        check(!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists() &&
            !File(file.baseFile.path + ".new").exists())
    }
}
