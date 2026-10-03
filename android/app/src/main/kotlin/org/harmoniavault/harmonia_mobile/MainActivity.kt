package org.harmoniavault.harmonia_mobile

import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import org.harmoniavault.harmonia_mobile.nativebridge.NativeBridgePlugin
import org.harmoniavault.harmonia_mobile.nativebridge.ProductFixtureConfiguration

class MainActivity : FlutterActivity() {
    private var nativeBridge: NativeBridgePlugin? = null
    private var screenReceiverRegistered = false
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == Intent.ACTION_SCREEN_OFF) nativeBridge?.onHostScreenOff()
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
        nativeBridge?.onHostResumed(!keyguard.isDeviceLocked)
    }

    override fun onPause() { nativeBridge?.onHostPaused(); super.onPause() }
    override fun onStop() { nativeBridge?.onHostStopped(); super.onStop() }
    override fun onUserLeaveHint() { nativeBridge?.onHostUserLeaveHint(); super.onUserLeaveHint() }

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
        if (screenReceiverRegistered) { unregisterReceiver(screenReceiver); screenReceiverRegistered = false }
        nativeBridge?.dispose()
        nativeBridge = null
        super.onDestroy()
    }
}
