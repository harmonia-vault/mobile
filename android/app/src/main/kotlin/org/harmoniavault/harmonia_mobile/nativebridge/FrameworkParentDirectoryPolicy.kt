package org.harmoniavault.harmonia_mobile.nativebridge

/** 仅由native Os.lstat/fstat投影；不接收Dart/path/auth grant。 */
internal data class FrameworkParentDirectoryMetadata(
    val uid: Int, val gid: Int, val permissions: Int, val directory: Boolean,
    val device: Long, val inode: Long,
)

/** 仅适用SDK context.noBackupFilesDir；自建vault/lock/PIN目录不使用此policy。 */
internal object FrameworkParentDirectoryPolicy {
    private val modes = setOf(0b111000000, 0b111111001) // 0700 / API34实际0771
    fun check(ownerUID: Int, before: FrameworkParentDirectoryMetadata,
        opened: FrameworkParentDirectoryMetadata, after: FrameworkParentDirectoryMetadata) {
        check(ownerUID >= 0)
        for (s in listOf(before, opened, after)) {
            check(s.directory && s.uid == ownerUID && s.gid == ownerUID && s.permissions in modes) { "unsafe framework parent" }
            check(s.device == before.device && s.inode == before.inode && s.permissions == before.permissions) { "framework parent changed" }
        }
    }
}
