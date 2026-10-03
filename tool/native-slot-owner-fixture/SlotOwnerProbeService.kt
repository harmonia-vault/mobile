package org.harmoniavault.harmonia_mobile.nativebridge

import android.app.Service
import android.content.Intent
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger

/** 仅独立测试APK的同UID另一进程；不导出，不读取任何设备材料。 */
class SlotOwnerProbeService : Service() {
    private var pendingCreateOwner: NativeSlotOwner? = null
    private val messenger = Messenger(Handler(Looper.getMainLooper()) { command ->
        val name = command.data.getString("slot")
        var code = 2
        if (command.what == 1 && name != null && name.matches(Regex("slot-owner-test-[A-Za-z0-9.-]{1,80}"))) {
            code = try { NativeSlotOwner.acquire(this, name).use { it.read { } }; 0 }
                catch (_: NativeSlotBusyException) { 1 } catch (_: Exception) { 2 }
        }
        if (command.what == 2 && name != null && name.matches(Regex("slot-owner-test-[A-Za-z0-9.-]{1,80}"))) {
            val filename = name + ".device"
            val alias = "harmonia/slotownerfixture/" + name
            val owner = NativeSlotOwner.acquire(this, name, filename, alias)
            ProtectedDeviceStore(this, alias, filename, name).prepareCreate(owner)
            // 保留完整FileLock直到本测试进程真正死亡，证明重开不靠RAM票。
            pendingCreateOwner = owner
            command.replyTo?.send(Message.obtain(null, 3))
            Handler(Looper.getMainLooper()).postDelayed({ android.os.Process.killProcess(android.os.Process.myPid()) }, 200)
            return@Handler true
        }
        command.replyTo?.send(Message.obtain(null, code)); true
    })
    override fun onBind(intent: Intent): IBinder = messenger.binder
}
