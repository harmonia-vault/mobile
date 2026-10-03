package org.harmoniavault.harmonia_mobile.nativebridge

import android.content.Context
import android.os.Process
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.channels.FileLock
import java.nio.channels.OverlappingFileLockException
import java.security.KeyStore
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.ConcurrentHashMap

internal class NativeSlotBusyException : IllegalStateException("slot owner busy")

/** system/PIN 同一固定逻辑槽位。FileLock 从捕获到认证、Go、关闭排空一直持有。 */
internal class NativeSlotOwner private constructor(
    private val lockFile: File,
    private val handle: FileOutputStream,
    private val lock: FileLock,
    private val snapshot: () -> List<ByteArray>,
    private val processBusy: AtomicBoolean,
) : AutoCloseable {
    private val released = AtomicBoolean()
    private val lease = SlotSnapshotLease { requireLock(); snapshot() }
    private fun requireLock() {
        check(!released.get() && processBusy.get() && lock.isValid)
        val path = Os.lstat(lockFile.path); val opened = Os.fstat(handle.fd)
        validateRegular(path, 0, 0)
        check(path.st_dev == opened.st_dev && path.st_ino == opened.st_ino && opened.st_nlink == 1L)
    }
    fun <T> read(block: () -> T): T = lease.read { requireLock(); block() }
    fun <T> mutate(onUnchangedFailure: (() -> Unit)? = null, block: () -> T): T = lease.mutate(onUnchangedFailure) { requireLock(); block() }
    fun clear(block: () -> Unit) = lease.clear { requireLock(); block() }
    fun operationEpoch(): Long = read { lease.operationEpoch().also { check(it > 0) } }
    fun retire() = lease.retire()
    fun alive() = lease.isAlive() && !released.get()
    override fun close() {
        lease.retire()
        if (!released.compareAndSet(false, true)) return
        check(SlotReleaseGate.release(processBusy, { lock.release() }, { handle.close() })) { "slot owner release unconfirmed" }
    }
    override fun toString() = "<native slot owner>"
    companion object {
        private val inProcess = ConcurrentHashMap<String, AtomicBoolean>()
        private const val MAX_STATE = (8 shl 20) + 8192
        private fun basename(value: String) {
            check(value.matches(Regex("[A-Za-z0-9][A-Za-z0-9._-]{0,127}")) && value != "." && value != "..")
        }
        private fun digest(value: String) = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it.toInt() and 255) }
        private fun validateRegular(s: android.system.StructStat, min: Int, max: Int) {
            check(OsConstants.S_ISREG(s.st_mode) && s.st_uid == Process.myUid() && s.st_nlink == 1L &&
                (s.st_mode and 511) == 384 && s.st_size in min.toLong()..max.toLong()) { "unsafe slot file" }
        }
        private fun directory(file: File) {
            if (!file.exists()) {
                check(file.mkdir()) { "slot directory unavailable" }
                Os.chmod(file.path, 448)
            }
            val s = Os.lstat(file.path)
            check(OsConstants.S_ISDIR(s.st_mode) && s.st_uid == Process.myUid() && (s.st_mode and 511) == 448) { "unsafe slot directory" }
        }
        private fun optionalDirectory(file: File) {
            try {
                val s = Os.lstat(file.path)
                check(OsConstants.S_ISDIR(s.st_mode) && s.st_uid == Process.myUid() && (s.st_mode and 511) == 448)
            } catch (e: ErrnoException) { if (e.errno != OsConstants.ENOENT) throw e }
        }
        private fun packet(file: File, max: Int, sync: Boolean = false): ByteArray {
            val before = try { Os.lstat(file.path) } catch (e: ErrnoException) {
                if (e.errno == OsConstants.ENOENT) return byteArrayOf(0)
                throw e
            }
            validateRegular(before, 0, max)
            val fd = Os.open(file.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC or OsConstants.O_NONBLOCK, 0)
            return FileInputStream(fd).use { input ->
                val opened = Os.fstat(input.fd)
                validateRegular(opened, 0, max)
                check(before.st_dev == opened.st_dev && before.st_ino == opened.st_ino)
                val bytes = input.readNBytes(max + 1)
                check(bytes.size <= max && bytes.size.toLong() == opened.st_size)
                if (sync) Os.fsync(input.fd)
                val after = Os.lstat(file.path)
                validateRegular(after, 0, max)
                check(after.st_dev == opened.st_dev && after.st_ino == opened.st_ino && after.st_size == opened.st_size)
                byteArrayOf(1) + bytes
            }
        }
        fun acquire(context: Context, workflowSlot: String,
            deviceFilename: String = "device-keys-v1.gcm", deviceAlias: String = "harmonia/device-key-wrap/v1", pinNamespace: String = "harmonia/mobile/app-pin/v1", afterBaselineSync: () -> Unit = {}): NativeSlotOwner {
            basename(workflowSlot); basename(deviceFilename)
            check(context.applicationInfo.uid == Process.myUid() && deviceAlias.isNotEmpty())
            val root = File(context.noBackupFilesDir, "harmonia")
            directory(root)
            val lockDirectory = File(root, "slot-owners-v1"); directory(lockDirectory)
            val slotKey = digest(context.packageName + "\u0000harmonia/native-slot/v1\u0000" + workflowSlot)
            val path = File(lockDirectory, "$slotKey.lock")
            // POSIX同进程关闭同inode的另一fd可能解除已有fcntl锁，必须在open之前拒并发。
            val processBusy = inProcess.computeIfAbsent(path.absolutePath) { AtomicBoolean() }
            if (!processBusy.compareAndSet(false, true)) throw NativeSlotBusyException()
            val fd = try {
                try { Os.open(path.path, OsConstants.O_RDWR or OsConstants.O_CREAT or OsConstants.O_EXCL or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC or OsConstants.O_NONBLOCK, 384) }
                catch (e: ErrnoException) {
                    if (e.errno != OsConstants.EEXIST) throw e
                    Os.open(path.path, OsConstants.O_RDWR or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC or OsConstants.O_NONBLOCK, 0)
                }
            } catch (failure: Exception) { processBusy.set(false); throw failure }
            val handle = FileOutputStream(fd)
            var held: FileLock? = null
            try {
                validateRegular(Os.fstat(fd), 0, 0)
                val p = Os.lstat(path.path); val f = Os.fstat(fd)
                check(p.st_dev == f.st_dev && p.st_ino == f.st_ino)
                held = try { handle.channel.tryLock() } catch (_: OverlappingFileLockException) { null }
                if (held == null) throw NativeSlotBusyException()
                val pinDirectory = File(root, "app-pin")
                val pinID = digest(context.packageName + "\u0000" + pinNamespace + "\u0000" + workflowSlot)
                val files = listOf(File(root, deviceFilename) to 108, File(root, workflowSlot) to MAX_STATE, File(root, deviceFilename + ".setup-v1.mac") to 4096,
                    File(pinDirectory, "$pinID.pin") to 24576, File(pinDirectory, "$pinID.workflow-pin-v1.gcm") to MAX_STATE)
                val setup = NativeDeviceSetupIntent(context, workflowSlot, deviceFilename, deviceAlias)
                val aliases = listOf(deviceAlias, setup.metadataAlias, "harmonia/app-pin/integrity/v1/${Process.myUid()}/$pinID")
                // fresh owner 可接纳此前 rename 已可见但目录 sync 未确认的包；
                // 先同步已验证文件/原目录并关闭各fd，不能把旧owner的未知结果当回滚。
                val durablePackets = files.flatMap { (file, max) -> listOf("", ".bak", ".new").map { packet(File(file.path + it), max, sync = true) } }
                var firstCapture = true
                try {
                    Os.fsync(handle.fd)
                    if (pinDirectory.exists()) syncDirectory(pinDirectory)
                    syncDirectory(root); syncDirectory(lockDirectory); syncFrameworkParent(context)
                    afterBaselineSync()
                } catch (failure: Exception) { durablePackets.forEach { it.fill(0) }; throw failure }
                val snapshot = {
                    optionalDirectory(root); optionalDirectory(pinDirectory)
                    val packets = files.flatMap { (file, max) -> listOf("", ".bak", ".new").map { packet(File(file.path + it), max) } }
                    if (firstCapture) {
                        try { check(packets.size == durablePackets.size && packets.indices.all { packets[it].contentEquals(durablePackets[it]) }) { "baseline changed during sync" } }
                        finally { durablePackets.forEach { it.fill(0) }; firstCapture = false }
                    }
                    val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
                    val reference = setup.referenceAlias()
                    packets + (aliases + listOfNotNull(reference)).map { byteArrayOf(if (keys.containsAlias(it)) 1 else 0) }
                }
                return NativeSlotOwner(path, handle, held, snapshot, processBusy)
            } catch (failure: Exception) {
                val confirmed = SlotReleaseGate.release(processBusy, { held?.release() }, { handle.close() })
                if (!confirmed) throw IllegalStateException("slot owner acquire cleanup unconfirmed")
                throw failure
            }
        }
        /** AtomicFile.openRead 会恢复/删除备份，不能用于只读 snapshot。 */
        fun readableAtomic(base: File): File? {
            val backup = File(base.path + ".bak")
            if (backup.exists()) return backup
            if (base.exists()) return base
            check(!File(base.path + ".new").exists()) { "incomplete slot publication" }
            return null
        }
        fun readAtomicBytes(base: File, max: Int): ByteArray? {
            val selected = readableAtomic(base) ?: return null
            return readFixedBytes(selected, max)
        }
        fun readFixedBytes(selected: File, max: Int): ByteArray {
            val framed = packet(selected, max)
            try { check(framed.isNotEmpty() && framed[0] == 1.toByte()); return framed.copyOfRange(1, framed.size) }
            finally { framed.fill(0) }
        }
        /** SDK创建parent允许实证0771；仅此固定Context路径，不chmod或放宽自建目录。 */
        private fun syncFrameworkParent(context: Context) {
            val ownerUID = Process.myUid()
            check(context.applicationInfo.uid == ownerUID)
            val directory = context.noBackupFilesDir
            fun metadata(s: android.system.StructStat) = FrameworkParentDirectoryMetadata(
                s.st_uid, s.st_gid, s.st_mode and 4095, OsConstants.S_ISDIR(s.st_mode), s.st_dev, s.st_ino)
            val before = metadata(Os.lstat(directory.path))
            FrameworkParentDirectoryPolicy.check(ownerUID, before, before, before)
            val fd = Os.open(directory.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC or OsConstants.O_NONBLOCK, 0)
            try {
                val opened = metadata(Os.fstat(fd))
                FrameworkParentDirectoryPolicy.check(ownerUID, before, opened, opened)
                Os.fsync(fd)
                FrameworkParentDirectoryPolicy.check(ownerUID, before, opened, metadata(Os.lstat(directory.path)))
            } finally { Os.close(fd) }
        }
        fun syncDirectory(directory: File) {
            val before = Os.lstat(directory.path)
            check(OsConstants.S_ISDIR(before.st_mode) && before.st_uid == Process.myUid() && (before.st_mode and 511) == 448)
            val fd = Os.open(directory.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC or OsConstants.O_NONBLOCK, 0)
            try {
                val opened = Os.fstat(fd)
                check(OsConstants.S_ISDIR(opened.st_mode) && opened.st_uid == Process.myUid() && (opened.st_mode and 511) == 448 && before.st_dev == opened.st_dev && before.st_ino == opened.st_ino)
                Os.fsync(fd)
                val after = Os.lstat(directory.path)
                check(after.st_dev == opened.st_dev && after.st_ino == opened.st_ino)
            } finally { Os.close(fd) }
        }
    }
}
