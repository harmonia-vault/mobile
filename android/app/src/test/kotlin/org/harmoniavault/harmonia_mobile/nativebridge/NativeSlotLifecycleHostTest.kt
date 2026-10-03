package org.harmoniavault.harmonia_mobile.nativebridge

/** 纯状态/计时测试，不冒称真实 SDK prompt、device credential 或 JNI 验收。 */
internal object NativeSlotLifecycleHostTest {
    private class Fixture(initialEpoch: Long = 41) {
        var now = 1000L
        private var syntheticOperationEpoch = 0L
        val scheduled = mutableListOf<Alarm>()
        val retired = mutableListOf<Long>()
        class Alarm(val at: Long, val action: () -> Unit) { var cancelled = false }
        val lifecycle = NativeSlotLifecycle({ now }, { delay, action ->
            val alarm = Alarm(now + delay, action); scheduled += alarm
            NativeSlotTimer { alarm.cancelled = true }
        }, initialEpoch, { retired += it })
        fun advance(millis: Long) {
            now += millis
            scheduled.toList().filter { !it.cancelled && it.at <= now }.forEach { it.cancelled = true; it.action() }
        }
        fun start(crypto: Any = Any()): Pair<NativeSlotLifecycle.Ticket, Any> {
            val ticket = lifecycle.prepareAuthentication(crypto, ++syntheticOperationEpoch); lifecycle.authenticationStarted(ticket)
            return ticket to crypto
        }
    }
    private fun rejected(action: () -> Unit) {
        var rejected = false
        try { action() } catch (_: IllegalStateException) { rejected = true }
        check(rejected)
    }
    @JvmStatic fun main(args: Array<String>) {
        var cases = 0
        run { // 正常两次独立认证：相同 platform epoch，不同 operation ticket；旧permit不可重用。
            val f = Fixture(); f.lifecycle.onResumed(true)
            val (first, crypto) = f.start(); f.lifecycle.onPaused()
            f.lifecycle.authenticationSucceeded(first, crypto)
            rejected { f.lifecycle.consume(first) }
            f.lifecycle.onResumed(true)
            val permit = f.lifecycle.consume(first)
            check(f.lifecycle.isOperationActive(permit)); rejected { f.lifecycle.consume(first) }
            f.advance(5_001); check(f.lifecycle.isOperationActive(permit))
            f.lifecycle.complete(permit); check(!f.lifecycle.isOperationActive(permit))
            val (second, newCrypto) = f.start()
            check(first.platformEpoch == second.platformEpoch && first.operationEpoch != second.operationEpoch)
            f.lifecycle.authenticationSucceeded(second, newCrypto)
            f.lifecycle.complete(f.lifecycle.consume(second)); check(f.retired.isEmpty()); cases++
        }
        run { // controlled stopped：success先、resume后。parked期间无permit。
            val f = Fixture(); f.lifecycle.onResumed(true); val (t, crypto) = f.start()
            f.lifecycle.onPaused(); f.lifecycle.onStopped(); check(t.phase == NativeSlotLifecycle.Phase.AUTH_WAIT_STOPPED)
            rejected { f.lifecycle.consume(t) }; f.lifecycle.authenticationSucceeded(t, crypto)
            rejected { f.lifecycle.consume(t) }; f.lifecycle.onResumed(true)
            val p = f.lifecycle.consume(t); f.lifecycle.complete(p); check(f.retired.isEmpty()); cases++
        }
        run { // resume先、success后。resume不延原parking deadline，也不是认证。
            val f = Fixture(); f.lifecycle.onResumed(true); val (t, crypto) = f.start()
            f.lifecycle.onStopped(); val parkedDeadline = t.deadline
            f.lifecycle.onResumed(true); rejected { f.lifecycle.consume(t) }; check(t.deadline == parkedDeadline)
            f.lifecycle.authenticationSucceeded(t, crypto); f.lifecycle.complete(f.lifecycle.consume(t)); cases++
        }
        run { // HOME/ScreenOff/unavailable(cancel等)/dispose退役。真实SDK证据仍未执行。
            for (exit in listOf<(Fixture, NativeSlotLifecycle.Ticket) -> Unit>(
                { f, _ -> f.lifecycle.onUserLeaveHint() }, { f, _ -> f.lifecycle.onScreenOff() },
                { f, t -> f.lifecycle.authenticationRejected(t) }, { f, _ -> f.lifecycle.dispose() },
            )) {
                val f = Fixture(); f.lifecycle.onResumed(true); val (t, crypto) = f.start(); f.lifecycle.onStopped()
                exit(f, t); f.lifecycle.onResumed(true)
                rejected { f.lifecycle.authenticationSucceeded(t, crypto) }; rejected { f.lifecycle.consume(t) }
                check(f.retired.contains(t.platformEpoch))
            }
            cases++
        }
        run { // stopped30秒和callback后前台5秒均不复活。
            val f = Fixture(); f.lifecycle.onResumed(true); val (t, crypto) = f.start(); f.lifecycle.onStopped()
            f.advance(29_999); rejected { f.lifecycle.consume(t) }; f.advance(1)
            rejected { f.lifecycle.authenticationSucceeded(t, crypto) }; check(f.retired.size == 1)
            val g = Fixture(); g.lifecycle.onResumed(true); val (u, other) = g.start(); g.lifecycle.onPaused()
            g.lifecycle.authenticationSucceeded(u, other); g.advance(5_000); g.lifecycle.onResumed(true)
            rejected { g.lifecycle.consume(u) }; check(g.retired.size == 1); cases++
        }
        run { // prepared未真正调用SDK不能停后台后续办；ACTIVE在后台也不可继续。
            val f = Fixture(); f.lifecycle.onResumed(true); val t = f.lifecycle.prepareAuthentication(Any(), 1)
            f.lifecycle.onStopped(); rejected { f.lifecycle.authenticationStarted(t) }
            val g = Fixture(); g.lifecycle.onResumed(true); val (u, crypto) = g.start()
            g.lifecycle.authenticationSucceeded(u, crypto); val p = g.lifecycle.consume(u)
            g.lifecycle.onPaused(); check(!g.lifecycle.isOperationActive(p)); rejected { g.lifecycle.complete(p) }; cases++
        }
        run { // 精确CryptoObject身份、一次callback；错对象不能授permit。
            val f = Fixture(); f.lifecycle.onResumed(true); val (t, _) = f.start()
            rejected { f.lifecycle.authenticationSucceeded(t, Any()) }; check(f.retired.size == 1)
            f.lifecycle.onResumed(true); val (u, crypto) = f.start(); f.lifecycle.authenticationSucceeded(u, crypto)
            rejected { f.lifecycle.authenticationSucceeded(u, crypto) }; rejected { f.lifecycle.consume(u) }; cases++
        }
        run { // 旧迟到callback不杀新的已开始ticket，旧generation永不复活。
            val f = Fixture(); f.lifecycle.onResumed(true); val (old, oldCrypto) = f.start(); f.lifecycle.invalidate()
            f.lifecycle.onResumed(true); val (next, crypto) = f.start()
            f.lifecycle.authenticationRejected(old); rejected { f.lifecycle.authenticationSucceeded(old, oldCrypto) }
            f.lifecycle.authenticationSucceeded(next, crypto); f.lifecycle.complete(f.lifecycle.consume(next)); cases++
        }
        run { // retirement callback在native gate外，可由另一线程读取状态。
            lateinit var lifecycle: NativeSlotLifecycle
            var readReturned = false
            lifecycle = NativeSlotLifecycle({ 1000 }, { _, _ -> NativeSlotTimer { } }, 41, {
                val reader = Thread { lifecycle.platformEpoch(); readReturned = true }
                reader.start(); reader.join(1000); check(!reader.isAlive)
            })
            lifecycle.onResumed(true); lifecycle.onUserLeaveHint(); check(readReturned); cases++
        }
        run { // epoch溢出永久closed；设备锁定和退出销毁都没有auth fallback。
            val f = Fixture(Long.MAX_VALUE); f.lifecycle.onResumed(true); f.lifecycle.invalidate()
            rejected { f.lifecycle.platformEpoch() }; rejected { f.lifecycle.prepareAuthentication(Any(), 1) }
            val g = Fixture(); g.lifecycle.onResumed(false); rejected { g.lifecycle.prepareAuthentication(Any(), 1) }
            g.lifecycle.onResumed(true); g.lifecycle.dispose(); rejected { g.lifecycle.platformEpoch() }; cases++
        }
        run { // 未发生SDK pause的取消/本地owner清理后，新票仍需新的实际CryptoObject。
            val f = Fixture(); f.lifecycle.onResumed(true); val (old, oldCrypto) = f.start()
            f.lifecycle.authenticationRejected(old)
            val (next, crypto) = f.start()
            check(next.platformEpoch != old.platformEpoch && !f.lifecycle.isAuthenticationReady(next))
            rejected { f.lifecycle.authenticationSucceeded(old, oldCrypto) }
            f.lifecycle.authenticationSucceeded(next, crypto)
            val permit = f.lifecycle.consume(next); f.lifecycle.complete(permit)
            check(f.lifecycle.canDeliverCompleted(permit)); f.lifecycle.onScreenOff()
            check(!f.lifecycle.canDeliverCompleted(permit)); cases++
        }
        println("PASS native lifecycle host cases=" + cases)
    }
}
