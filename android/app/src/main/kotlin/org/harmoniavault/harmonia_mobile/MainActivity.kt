package org.harmoniavault.harmonia_mobile

import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import org.harmoniavault.harmonia_mobile.nativebridge.NativeBridgePlugin
import org.harmoniavault.harmonia_mobile.nativebridge.NativeSlotLifecycle
import org.harmoniavault.harmonia_mobile.nativebridge.NativeSlotTimer
import org.harmoniavault.harmonia_mobile.nativebridge.ProductFixtureConfiguration

class MainActivity : FlutterActivity() {
    private var nativeBridge: NativeBridgePlugin? = null
    // A 分片仅采纳 SDK 生命周期；尚未连接生产认证或任何 DAG 业务入口。
    private val dagHandler = Handler(Looper.getMainLooper())
    private val dagLifecycle = NativeSlotLifecycle(
        clockMillis = { SystemClock.elapsedRealtime() },
        schedule = { delay, action ->
            val runnable = Runnable { action() }
            check(dagHandler.postDelayed(runnable, delay))
            NativeSlotTimer { dagHandler.removeCallbacks(runnable) }
        },
    )
    private var screenReceiverRegistered = false
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == Intent.ACTION_SCREEN_OFF) dagLifecycle.onScreenOff()
        }
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(screenReceiver, IntentFilter(Intent.ACTION_SCREEN_OFF), Context.RECEIVER_NOT_EXPORTED)
        else registerReceiver(screenReceiver, IntentFilter(Intent.ACTION_SCREEN_OFF))
        screenReceiverRegistered = true
    }

    override fun onResume() {
        super.onResume()
        val keyguard = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        dagLifecycle.onResumed(!keyguard.isDeviceLocked)
    }

    override fun onPause() { dagLifecycle.onPaused(); super.onPause() }
    override fun onStop() { dagLifecycle.onStopped(); super.onStop() }
    override fun onUserLeaveHint() { dagLifecycle.onUserLeaveHint(); super.onUserLeaveHint() }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val fixture = ProductFixtureConfiguration.fromBuild(
            BuildConfig.DEBUG, BuildConfig.HARMONIA_PRODUCT_FIXTURE, packageName,
            BuildConfig.HARMONIA_FIXTURE_ENDPOINT, BuildConfig.HARMONIA_FIXTURE_CA_BASE64,
        )
        nativeBridge = NativeBridgePlugin(this, flutterEngine.dartExecutor.binaryMessenger,
            additionalCA = fixture?.publicCA() ?: ByteArray(0), productFixture = fixture)
    }

    override fun onDestroy() {
        dagLifecycle.dispose()
        if (screenReceiverRegistered) { unregisterReceiver(screenReceiver); screenReceiverRegistered = false }
        nativeBridge?.dispose()
        nativeBridge = null
        super.onDestroy()
    }
}
