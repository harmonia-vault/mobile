package org.harmoniavault.harmonia_mobile.nativebridge

import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Test
import org.junit.Assert.*
import android.system.Os
import java.io.File

/** 只验证密文传输层AtomicFile故障恢复，不将这些合成packet当作可解密Go状态。 */
class NativeWorkflowStorageTest {
    @Test fun testInterruptedAtomicCiphertextSavePreservesPreviousFile() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val filename="synthetic-workflow-atomic.gcm"
        val store=ProtectedWorkflowStore(context,filename)
        store.delete()
        val first="HARMST01".toByteArray()+ByteArray(64){1}
        val second="HARMST01".toByteArray()+ByteArray(64){2}
        try {
            store.saveSealed(first)
            val file=File(File(context.noBackupFilesDir,"harmonia"),filename)
            assertEquals(0b110000000,Os.stat(file.path).st_mode and 0b111111111)
            var checks=0
            val interrupted=ProtectedWorkflowStore(context,filename) {++checks<2}
            try {interrupted.saveSealed(second);fail("interrupted save returned success")}
            catch (_: IllegalStateException) {}
            assertTrue(first.contentEquals(store.load()))
            try {store.saveSealed(ByteArray((8 shl 20)+8193));fail("oversized state accepted")}
            catch (_: IllegalStateException) {}
            assertTrue(first.contentEquals(store.load()))
        } finally {store.delete()}
    }
}
