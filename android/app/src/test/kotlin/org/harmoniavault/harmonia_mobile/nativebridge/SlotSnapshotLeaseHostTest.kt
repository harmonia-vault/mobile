package org.harmoniavault.harmonia_mobile.nativebridge

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** 纯状态机测试；不冒称 Android 文件/Keystore/JNI 实测。 */
internal object SlotSnapshotLeaseHostTest {
    @JvmStatic fun main(args: Array<String>) {
        var cases = 0
        fun rejected(block: () -> Unit) { var failed = false; try { block() } catch (_: IllegalStateException) { failed = true }; check(failed) }
        run { // 普通save也不能覆盖别的writer/CAS状态。
            var disk = byteArrayOf(1); val owner = SlotSnapshotLease { listOf(disk.copyOf()) }
            owner.mutate { disk = byteArrayOf(2) }; owner.read { }
            disk = byteArrayOf(3)
            rejected { owner.mutate { disk = byteArrayOf(9) } }; check(disk.contentEquals(byteArrayOf(3)))
            rejected { owner.read { } }; cases++
        }
        run { // cancelled token不能重捕获磁盘后复活。
            var disk = byteArrayOf(1); val owner = SlotSnapshotLease { listOf(disk.copyOf()) }
            val priorEpoch = owner.operationEpoch(); owner.retire(); rejected { owner.mutate { disk = byteArrayOf(2) } }
            check(owner.operationEpoch() > priorEpoch && disk[0] == 1.toByte()); cases++
        }
        run { // cleanup票消耗一次；旧save/check/create均closed。
            var disk = byteArrayOf(1); val owner = SlotSnapshotLease { listOf(disk.copyOf()) }
            owner.clear { owner.mutate { disk = byteArrayOf() } }
            rejected { owner.mutate { disk = byteArrayOf(4) } }; rejected { owner.clear { } }; check(disk.isEmpty()); cases++
        }
        run { // readback异常可能已经提交，必须closed，不能承诺旧cipher恢复。
            var disk = byteArrayOf(1); val owner = SlotSnapshotLease { listOf(disk.copyOf()) }
            rejected { owner.mutate { disk = byteArrayOf(2); error("synthetic readback failure") } }
            check(disk[0] == 2.toByte()); rejected { owner.read { } }; cases++
        }
        run { // retirement等待当前短commit完成，再永远拒绝迟到writer。
            var disk = byteArrayOf(1); val owner = SlotSnapshotLease { listOf(disk.copyOf()) }
            val entered = CountDownLatch(1); val finish = CountDownLatch(1); val retired = CountDownLatch(1)
            val workerFailure = java.util.concurrent.atomic.AtomicReference<Throwable>()
            val writer = Thread { try { rejected { owner.mutate { entered.countDown(); check(finish.await(2, TimeUnit.SECONDS)); disk = byteArrayOf(2) } } } catch (failure: Throwable) { workerFailure.set(failure) } }
            writer.start(); check(entered.await(2, TimeUnit.SECONDS))
            val cancel = Thread { owner.retire(); retired.countDown() }; cancel.start()
            check(!retired.await(20, TimeUnit.MILLISECONDS))
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(1)
            while (owner.isAlive() && System.nanoTime() < deadline) Thread.yield()
            check(!owner.isAlive()); finish.countDown(); writer.join(2000); cancel.join(2000)
            check(workerFailure.get() == null && retired.count == 0L && !owner.isAlive()); rejected { owner.mutate { } }; cases++
        }
        run { // 升级latch失败仅原完整snapshot未变时允许预设native销毁动作。
            var disk = byteArrayOf(1); var retiredAlias = false
            val owner = SlotSnapshotLease { listOf(disk.copyOf()) }
            rejected { owner.mutate(onUnchangedFailure = { retiredAlias = true }) { error("synthetic precommit failure") } }
            check(retiredAlias && !owner.isAlive()); cases++
            retiredAlias = false
            val unknown = SlotSnapshotLease { listOf(disk.copyOf()) }
            rejected { unknown.mutate(onUnchangedFailure = { retiredAlias = true }) { disk = byteArrayOf(2); error("synthetic commit unknown") } }
            check(!retiredAlias && !unknown.isAlive()); cases++
        }
        run {
            val busy = java.util.concurrent.atomic.AtomicBoolean(true)
            check(!SlotReleaseGate.release(busy, { error("synthetic lock release failure") }, { }))
            check(busy.get() && !busy.compareAndSet(false, true))
            val other = java.util.concurrent.atomic.AtomicBoolean(true)
            check(!SlotReleaseGate.release(other, { }, { error("synthetic fd close failure") }))
            check(other.get())
            val healthy = java.util.concurrent.atomic.AtomicBoolean(true)
            check(SlotReleaseGate.release(healthy, { }, { }) && !healthy.get()); cases++
        }
        run { // 固定framework parent只接受本UID/GID+0700/0771+相同path/FD；不能替代自建目录校验。
            val uid = 10001
            val good = FrameworkParentDirectoryMetadata(uid, uid, 0b111111001, true, 7, 9)
            fun verify(a: FrameworkParentDirectoryMetadata, b: FrameworkParentDirectoryMetadata = a, c: FrameworkParentDirectoryMetadata = b) = FrameworkParentDirectoryPolicy.check(uid, a, b, c)
            verify(good); verify(good.copy(permissions = 0b111000000))
            rejected { verify(good.copy(uid = uid + 1)) }
            rejected { verify(good.copy(gid = uid + 1)) }
            rejected { verify(good.copy(permissions = 0b111111111)) }
            rejected { verify(good.copy(permissions = 0b111000001)) }
            rejected { verify(good.copy(permissions = 4095)) }
            rejected { verify(good.copy(directory = false)) }
            rejected { verify(good, good.copy(inode = 10)) }
            rejected { verify(good, good.copy(device = 8)) }
            rejected { verify(good, good.copy(permissions = 0b111000000)) }
            rejected { verify(good, good, good.copy(inode = 10)) }
            rejected { verify(good, good, good.copy(uid = uid + 1)) }
            cases++
        }
        run { // JNI null expected只代表空bytes，不允许wildcard；next null拒绝。
            SealedCallbackContract.checkExpected(null, ByteArray(0))
            SealedCallbackContract.checkExpected(ByteArray(0), ByteArray(0))
            SealedCallbackContract.checkExpected(byteArrayOf(1), byteArrayOf(1))
            rejected { SealedCallbackContract.checkExpected(null, byteArrayOf(1)) }
            rejected { SealedCallbackContract.checkExpected(ByteArray(0), byteArrayOf(1)) }
            rejected { SealedCallbackContract.checkExpected(byteArrayOf(1), ByteArray(0)) }
            rejected { SealedCallbackContract.checkExpected(byteArrayOf(2), byteArrayOf(1)) }
            rejected { SealedCallbackContract.requirePacket(null) }
            check(SealedCallbackContract.requirePacket(byteArrayOf(1)).contentEquals(byteArrayOf(1)))
            cases++
        }
        println("PASS slot owner host cases=" + cases)
    }
}
